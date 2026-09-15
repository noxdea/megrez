# frozen_string_literal: true

module Megrez
  module Testing
    class FakeAdapter
      DEFAULT_CAPABILITIES = {
        "supportsConfigurationDoneRequest" => true,
        "supportsConditionalBreakpoints" => true,
        "supportsLogPoints" => true,
        "supportsSetVariable" => true,
        "supportsSetExpression" => true,
        "supportsCompletionsRequest" => true,
        "supportsCancelRequest" => true
      }.freeze

      attr_reader :messages

      def self.command
        root = File.expand_path("../..", __dir__)
        [RbConfig.ruby, "-I#{root}", "-rmegrez/testing", "-e", "Megrez::Testing::FakeAdapter.run_stdio"]
      end

      def self.run_stdio = new.serve(STDIN, STDOUT)

      def initialize(responses: {}, capabilities: DEFAULT_CAPABILITIES, variable_count: 3)
        raise ArgumentError, "responses must be a Hash" unless responses.is_a?(Hash)
        raise ArgumentError, "capabilities must be a Hash" unless capabilities.is_a?(Hash)
        raise ArgumentError, "variable_count must be nonnegative" unless variable_count.is_a?(Integer) && variable_count >= 0

        @responses = responses.transform_keys(&:to_s)
        @capabilities = capabilities
        @variable_count = variable_count
        @messages = []
        @sequence = 0
        @lock = Mutex.new
        @sinks = []
      end

      def transport(&receive) = FakeTransport.new(self, &receive)

      def attach(&sink)
        @lock.synchronize { @sinks << sink }
        sink
      end

      def detach(sink) = @lock.synchronize { @sinks.delete(sink) }

      def emit(event, body = {})
        message = event_message(event, body)
        @lock.synchronize { @sinks.dup }.each { |sink| sink.call([message]) }
        message
      end

      def request_client(command, arguments = {})
        message = {
          "seq" => sequence,
          "type" => "request",
          "command" => command.to_s,
          "arguments" => arguments
        }
        @lock.synchronize { @sinks.dup }.each { |sink| sink.call([message]) }
        message
      end

      def dispatch(message)
        Protocol.validate_message(message)
        @lock.synchronize { @messages << Protocol.deep_freeze(message.dup) }
        return [] unless message["type"] == "request"
        return [] if message["command"] == "never"

        override = @responses[message["command"]]
        return Array(override.call(message["arguments"] || {}, message)) if override.respond_to?(:call)
        return [response(message, override)] if @responses.key?(message["command"])

        result, events = response_for(message)
        [response(message, result), *events]
      rescue AdapterError => error
        [response(message, {}, success: false, message: error.message)]
      end

      def serve(input, output = input)
        input.binmode
        output.binmode
        output.sync = true
        while (message = Transport.read_message(input))
          dispatch(message).each { |item| output.write(Transport.frame(item)) }
        end
      rescue IOError, Errno::EPIPE
        nil
      end

      private

      def response_for(message)
        arguments = message["arguments"] || {}
        case message["command"]
        when "initialize"
          [@capabilities, []]
        when "launch", "attach"
          [{}, [event_message("initialized")]]
        when "configurationDone"
          [{}, [stopped_event]]
        when "setBreakpoints"
          values = arguments.fetch("breakpoints", []).each_with_index.map do |breakpoint, index|
            {
              "id" => index + 1,
              "verified" => true,
              "source" => arguments["source"],
              "line" => breakpoint["line"],
              "column" => breakpoint["column"]
            }.compact
          end
          [{"breakpoints" => values}, []]
        when "setFunctionBreakpoints", "setDataBreakpoints"
          values = arguments.fetch("breakpoints", []).each_index.map { |index| {"id" => index + 1, "verified" => true} }
          [{"breakpoints" => values}, []]
        when "setExceptionBreakpoints"
          values = arguments.fetch("filters", []).each_index.map { |index| {"id" => index + 1, "verified" => true} }
          [{"breakpoints" => values}, []]
        when "threads"
          [{"threads" => [{"id" => 1, "name" => "main"}]}, []]
        when "stackTrace"
          [{"stackFrames" => [{"id" => 10, "name" => "main", "source" => {"path" => "app.rb"}, "line" => 1, "column" => 1}], "totalFrames" => 1}, []]
        when "scopes"
          [{"scopes" => [{"name" => "Locals", "variablesReference" => 1, "expensive" => false}]}, []]
        when "variables"
          values = Array.new(@variable_count) do |index|
            {"name" => "value#{index}", "value" => index.to_s, "type" => "Integer", "variablesReference" => 0}
          end
          [{"variables" => values}, []]
        when "evaluate"
          [{"result" => "42", "type" => "Integer", "variablesReference" => 0}, []]
        when "setVariable", "setExpression"
          [{"value" => arguments.fetch("value"), "type" => "String", "variablesReference" => 0}, []]
        when "completions"
          [{"targets" => [{"label" => "value", "text" => "value", "start" => 0, "length" => arguments.fetch("column", 0)}]}, []]
        when "source"
          [{"content" => "puts :ok\n", "mimeType" => "text/x-ruby"}, []]
        when "continue"
          [{"allThreadsContinued" => !arguments["singleThread"]}, [event_message("continued", "threadId" => arguments["threadId"], "allThreadsContinued" => !arguments["singleThread"])] ]
        when "next", "stepIn", "stepOut", "restartFrame"
          [{}, [event_message("continued", "threadId" => arguments["threadId"] || 1), stopped_event]]
        when "restart"
          [{}, [event_message("continued", "threadId" => 1), stopped_event]]
        when "pause"
          [{}, [stopped_event]]
        when "terminate"
          [{}, [event_message("terminated")]]
        when "disconnect"
          [{}, [event_message("terminated")]]
        else
          [@responses.fetch(message["command"], {}), []]
        end
      end

      def response(request, body, success: true, message: nil)
        value = {
          "seq" => sequence,
          "type" => "response",
          "request_seq" => request["seq"],
          "success" => success,
          "command" => request["command"],
          "body" => body
        }
        value["message"] = message if message
        value
      end

      def stopped_event = event_message("stopped", "reason" => "breakpoint", "threadId" => 1, "allThreadsStopped" => true)

      def event_message(event, body = {})
        {"seq" => sequence, "type" => "event", "event" => event, "body" => body}
      end

      def sequence = @lock.synchronize { @sequence += 1 }
    end
  end
end
