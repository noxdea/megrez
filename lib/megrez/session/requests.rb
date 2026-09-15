# frozen_string_literal: true

module Megrez
  class Session
    def launch(configuration)
      transition_request("launch", configuration, from: :initialized, to: :configuring) { |body| Results.body(body) }
    end

    def attach(configuration)
      transition_request("attach", configuration, from: :initialized, to: :configuring) { |body| Results.body(body) }
    end

    def configuration_done
      transition_request("configurationDone", {}, from: :configuring, to: :running) { |body| Results.body(body) }
    end

    def disconnect(terminate: false, restart: false)
      Protocol.boolean(terminate, "terminate")
      Protocol.boolean(restart, "restart")
      future = transition_request(
        "disconnect",
        {terminateDebuggee: terminate, restart: restart},
        from: %i[initialized configuring running stopped],
        to: :terminated
      ) { |body| Results.body(body) }
      future.then { |_value, _error| close }
    end

    def set_breakpoints(source_path, breakpoints)
      source_path = Protocol.string(source_path, "source path", empty: false)
      breakpoints = Protocol.collection(breakpoints, "source breakpoints").map do |breakpoint|
        source_breakpoint(breakpoint)
      end
      send_request(
        "setBreakpoints",
        {source: {path: source_path}, breakpoints: breakpoints},
        states: %i[configuring stopped running]
      ) { |body| Results.breakpoints(body) }
    end

    def set_function_breakpoints(names)
      values = Protocol.collection(names, "function breakpoint names").map do |name|
        {name: Protocol.string(name, "function breakpoint name", empty: false)}
      end
      breakpoint_request("setFunctionBreakpoints", breakpoints: values)
    end

    def set_exception_breakpoints(filters, options: [])
      filters = Protocol.collection(filters, "exception filters").map do |filter|
        Protocol.string(filter, "exception filter", empty: false)
      end
      options = object_array(options, "exception options")
      breakpoint_request("setExceptionBreakpoints", filters: filters, filterOptions: options)
    end

    def set_data_breakpoints(descriptors)
      values = object_array(descriptors, "data breakpoints")
      values.each do |descriptor|
        Protocol.string(descriptor["dataId"] || descriptor[:dataId], "data breakpoint dataId", empty: false)
      end
      breakpoint_request("setDataBreakpoints", breakpoints: values)
    end

    def continue(thread_id, all: false)
      Protocol.boolean(all, "all")
      execution_request("continue", thread_id, singleThread: !all)
    end

    def step_over(thread_id, granularity: :statement)
      execution_request("next", thread_id, granularity: granularity_value(granularity))
    end

    def step_in(thread_id, target_id: nil)
      arguments = {}
      arguments[:targetId] = Protocol.integer(target_id, "step target id") unless target_id.nil?
      execution_request("stepIn", thread_id, **arguments)
    end

    def step_out(thread_id) = execution_request("stepOut", thread_id)

    def pause(thread_id)
      thread_id = Protocol.integer(thread_id, "thread id")
      send_request("pause", {threadId: thread_id}, states: [:running]) { |body| Results.body(body) }
    end

    def restart_frame(frame_id)
      frame_id = Protocol.integer(frame_id, "frame id")
      transition_request("restartFrame", {frameId: frame_id}, from: :stopped, to: :running) do |body|
        Results.body(body)
      end
    end

    def restart(arguments = {})
      transition_request("restart", arguments, from: %i[running stopped], to: :running) { |body| Results.body(body) }
    end

    def terminate
      send_request("terminate", {}, states: %i[configuring running stopped]) { |body| Results.body(body) }
    end

    private

    def breakpoint_request(command, arguments)
      send_request(command, arguments, states: %i[configuring stopped running]) { |body| Results.breakpoints(body) }
    end

    def execution_request(command, thread_id, **arguments)
      thread_id = Protocol.integer(thread_id, "thread id")
      transition_request(command, {threadId: thread_id, **arguments}, from: :stopped, to: :running) do |body|
        Results.body(body)
      end
    end

    def source_breakpoint(value)
      raise Error, "source breakpoint must be a SourceBreakpoint" unless value.is_a?(SourceBreakpoint)

      result = {line: Protocol.uint(value.line, "breakpoint line")}
      result[:column] = Protocol.uint(value.column, "breakpoint column") unless value.column.nil?
      {
        condition: value.condition,
        hitCondition: value.hit_condition,
        logMessage: value.log_message
      }.each do |key, text|
        result[key] = Protocol.string(text, "breakpoint #{key}") unless text.nil?
      end
      result
    end

    def object_array(values, name)
      Protocol.collection(values, name).map do |value|
        Protocol.validate_outbound(Protocol.object(value, name))
      end
    end

    def granularity_value(value)
      value = value.to_s
      raise ArgumentError, "granularity must be statement, line, or instruction" unless %w[statement line instruction].include?(value)

      value
    end

  end
end
