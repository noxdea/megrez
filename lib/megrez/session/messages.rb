# frozen_string_literal: true

module Megrez
  class Session
    private

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

      Protocol.validate_message(message)
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
      return pending.future.fulfill(error: Error.new("mismatched DAP response command")) if message["command"] != pending.command

      unless message["success"]
        text = message["message"] || "debug adapter rejected #{pending.command}"
        body = message["body"]&.then { |value| Protocol.deep_freeze(value.dup) }
        return pending.future.fulfill(error: AdapterError.new(pending.command, text, body))
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

      result = handler.call(Protocol.deep_freeze(message.fetch("arguments", {}).dup)) || {}
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

        value = {seq: next_sequence, type: "response", request_seq: request["seq"],
                 success: success, command: request["command"]}
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
      prefix = error.is_a?(Error) ? "" : "#{error.class}: "
      message = "#{prefix}#{error.message}".scrub.byteslice(0, 4096).scrub("")
      bounded = error.is_a?(Error) && error.message.bytesize <= 4096 ? error : Error.new(message)
      @lock.synchronize do
        @errors << bounded
        @errors.shift if @errors.length > MAX_ERRORS
      end
      bounded
    end

    def event_key(event)
      event.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase.to_sym
    end
  end
end
