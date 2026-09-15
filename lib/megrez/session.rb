# frozen_string_literal: true

module Megrez
  class Session
    MAX_PENDING = 1024
    MAX_ERRORS = 100
    STOP = Object.new.freeze
    Pending = Struct.new(:future, :command, :validate, keyword_init: true)
    private_constant :MAX_PENDING, :MAX_ERRORS, :STOP, :Pending

    def self.stdio(command:, env: {}, cwd: nil, dispatch: ->(&block) { block.call })
      new(Transport.stdio(command: command, env: env, cwd: cwd), dispatch: dispatch)
    end

    def self.tcp(host:, port:, dispatch: ->(&block) { block.call }, connect_timeout: 10)
      new(Transport.tcp(host: host, port: port, connect_timeout: connect_timeout), dispatch: dispatch)
    end

    attr_reader :transport

    def initialize(transport, dispatch: ->(&block) { block.call })
      valid = transport.respond_to?(:listen) && transport.respond_to?(:write) && transport.respond_to?(:close)
      raise ArgumentError, "transport must support listen, write, and close" unless valid
      raise ArgumentError, "dispatch must respond to call" unless dispatch.respond_to?(:call)

      @transport = transport
      @dispatch = dispatch
      @lock = Mutex.new
      @pending = {}
      @ignored_responses = {}
      @handlers = Hash.new { |hash, key| hash[key] = [] }
      @request_handlers = {}
      @errors = []
      @sequence = 0
      @generation = 0
      @state = :initialized
      @started = false
      @closing = false
      @capabilities = {}.freeze
      @inbound = Queue.new
      @dispatcher = Thread.new { dispatch_messages }
      @dispatcher.report_on_exception = false
      @transport.listen { |message, error| enqueue(message, error) }
    rescue StandardError
      close
      raise
    end

    def start(adapter_id:, lines_start_at_1: true, columns_start_at_1: true, path_format: "path", timeout: 10)
      started_now = false
      adapter_id = Protocol.string(adapter_id, "adapter_id", empty: false, max: 256)
      Protocol.boolean(lines_start_at_1, "lines_start_at_1")
      Protocol.boolean(columns_start_at_1, "columns_start_at_1")
      raise ArgumentError, "path_format must be path or uri" unless %w[path uri].include?(path_format)

      @lock.synchronize do
        raise Error, "debug session already started" if @started
        raise Error, "debug session is closed" if @closing

        @started = true
        started_now = true
      end
      arguments = {
        clientID: "megrez",
        clientName: "Megrez",
        adapterID: adapter_id,
        linesStartAt1: lines_start_at_1,
        columnsStartAt1: columns_start_at_1,
        pathFormat: path_format,
        supportsVariableType: true,
        supportsVariablePaging: true,
        supportsProgressReporting: true,
        supportsRunInTerminalRequest: true,
        supportsStartDebuggingRequest: true
      }
      future = send_request("initialize", arguments, states: [:initialized], allow_unstarted: true) do |body|
        Results.capabilities(body)
      end
      value = future.await(timeout: timeout)
      @lock.synchronize { @capabilities = value }
      value
    rescue StandardError
      close if started_now
      raise
    end

    def request(command, arguments = {})
      send_request(command, arguments, states: %i[initialized configuring running stopped]) { |body| Results.body(body) }
    end

    def on(event, &handler)
      raise ArgumentError, "handler required" unless handler

      key = event_key(event)
      @lock.synchronize { @handlers[key] << handler }
      handler
    end

    def on_request(command, &handler)
      raise ArgumentError, "handler required" unless handler

      command = Protocol.string(command.to_s, "request command", empty: false, max: 256)
      @lock.synchronize { @request_handlers[command] = handler }
      handler
    end

    def capabilities = @lock.synchronize { @capabilities }
    def state = @lock.synchronize { @state }
    def generation = @lock.synchronize { @generation }
    def errors = @lock.synchronize { @errors.dup.freeze }

    def close
      pending = @lock&.synchronize do
        next if @closing

        @closing = true
        @state = :terminated
        values = @pending.values.map(&:future)
        @pending.clear
        values
      end
      return nil unless pending

      @transport&.close
      error = Error.new("debug session closed")
      pending.each { |future| future.fulfill(error: error) }
      @inbound&.push(STOP)
      if @dispatcher && @dispatcher != Thread.current
        @dispatcher.kill unless @dispatcher.join(1)
        @dispatcher.join
      end
      nil
    end

    private

    def send_request(command, arguments, states:, allow_unstarted: false, &validate)
      command = Protocol.string(command.to_s, "DAP command", empty: false, max: 256)
      arguments = Protocol.object(arguments, "DAP request arguments")
      Protocol.validate_outbound(arguments)

      pending = @lock.synchronize do
        raise Error, "debug session is closed" if @closing
        raise Error, "debug session has not started" unless @started || allow_unstarted
        raise Error, "#{command} is invalid while #{@state}" unless states.include?(@state)
        raise Error, "too many pending DAP requests" if @pending.length >= MAX_PENDING

        sequence = next_sequence
        future = Future.new(sequence, on_error: method(:record_error)) { |id| cancel_request(id) }
        value = Pending.new(future: future, command: command, validate: validate)
        @pending[sequence] = value
        [sequence, value]
      end
      sequence, value = pending
      @transport.write(seq: sequence, type: "request", command: command, arguments: arguments)
      value.future
    rescue StandardError => error
      if pending
        @lock.synchronize { @pending.delete(pending.first) }
        pending.last.future.fulfill(error: error)
      else
        raise
      end
    end

    def transition_request(command, arguments, from:, to:, &validate)
      previous = @lock.synchronize do
        raise Error, "debug session is closed" if @closing
        raise Error, "debug session has not started" unless @started
        raise Error, "#{command} is invalid while #{@state}" unless Array(from).include?(@state)

        old = @state
        @state = to
        old
      end
      send_request(command, arguments, states: [to], &validate)
    rescue StandardError
      @lock.synchronize { @state = previous if previous && @state == to }
      raise
    end

    def cancel_request(request_id)
      message = @lock.synchronize do
        next unless @pending.delete(request_id)
        next if @closing

        sequence = next_sequence
        @ignored_responses[sequence] = true
        @ignored_responses.shift if @ignored_responses.length > MAX_PENDING
        {seq: sequence, type: "request", command: "cancel", arguments: {requestId: request_id}}
      end
      @transport.write(message) if message
    rescue Error => error
      record_error(error)
    end

    def next_sequence
      @sequence += 1
      @sequence = 1 if @sequence > 0x7fff_ffff
      @sequence
    end

    def enqueue(message, error)
      return if @lock.synchronize { @closing }

      @inbound << [message, error]
    end

    def dispatch_messages
      loop do
        item = @inbound.pop
        break if item.equal?(STOP)

        done = Queue.new
        begin
          @dispatch.call do
            begin
              process_message(*item)
            rescue StandardError => error
              record_error(error)
            ensure
              done << true
            end
          end
          done.pop
        rescue StandardError => error
          record_error(error)
        end
      end
    end

    def process_message(message, error)
      return fail_connection(error) if error

      case message["type"]
      when "response" then process_response(message)
      when "event" then process_event(message)
      when "request" then process_reverse_request(message)
      end
    end

    def process_response(message)
      ignored = false
      pending = @lock.synchronize do
        request_sequence = message["request_seq"]
        if @ignored_responses.delete(request_sequence)
          ignored = true
          next
        end

        @pending.delete(request_sequence)
      end
      return if ignored
      return record_error(Error.new("unsolicited DAP response")) unless pending

      if message["command"] != pending.command
        return pending.future.fulfill(error: Error.new("mismatched DAP response command"))
      end
      unless message["success"]
        text = message["message"] || "debug adapter rejected #{pending.command}"
        return pending.future.fulfill(error: AdapterError.new(pending.command, text, message["body"]))
      end

      body = message.fetch("body", {})
      value = pending.validate ? pending.validate.call(body) : body
      pending.future.fulfill(value)
    rescue StandardError => error
      pending&.future&.fulfill(error: error)
    end

    def process_event(message)
      key = event_key(message["event"])
      body = Protocol.deep_freeze(message.fetch("body", {}).dup)
      handlers = @lock.synchronize do
        case key
        when :stopped
          @generation += 1
          @state = :stopped
        when :continued
          @state = :running
        when :terminated, :exited
          @generation += 1
          @state = :terminated
        end
        @handlers[key].dup
      end
      handlers.each do |handler|
        handler.call(body)
      rescue StandardError => error
        record_error(error)
      end
    end

    def process_reverse_request(message)
      command = message["command"]
      handler = @lock.synchronize { @request_handlers[command] }
      raise AdapterError.new(command, "unsupported adapter request: #{command}") unless handler

      result = handler.call(Protocol.deep_freeze(message.fetch("arguments", {}).dup))
      result = {} if result.nil?
      Protocol.object(result, "adapter request result")
      Protocol.validate_outbound(result)
      send_response(message, success: true, body: result)
    rescue StandardError => error
      record_error(error)
      send_response(message, success: false, message: error.message.scrub.byteslice(0, 4096).scrub(""))
    end

    def send_response(request, success:, body: nil, message: nil)
      response = @lock.synchronize do
        next if @closing

        value = {
          seq: next_sequence,
          type: "response",
          request_seq: request["seq"],
          success: success,
          command: request["command"]
        }
        value[:body] = body if body
        value[:message] = message if message
        value
      end
      @transport.write(response) if response
    rescue Error => error
      record_error(error)
    end

    def fail_connection(error)
      pending = @lock.synchronize do
        next [] if @closing

        @state = :terminated
        @generation += 1
        values = @pending.values.map(&:future)
        @pending.clear
        values
      end
      record_error(error)
      pending.each { |future| future.fulfill(error: error) }
    end

    def record_error(error)
      bounded = error.is_a?(Error) ? error : Error.new("#{error.class}: #{error.message}".scrub.byteslice(0, 4096).scrub(""))
      @lock.synchronize do
        @errors << bounded
        @errors.shift if @errors.length > MAX_ERRORS
      end
      bounded
    end

    def event_key(event)
      value = event.to_s
      value = value.gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
      value.downcase.to_sym
    end
  end
end

require_relative "session/requests"
