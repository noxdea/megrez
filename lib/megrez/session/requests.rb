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

    def threads
      send_request("threads", {}, states: %i[configuring running stopped]) { |body| Results.threads(body) }
    end

    def stack_trace(thread_id, start: 0, levels: 20)
      thread_id = Protocol.integer(thread_id, "thread id")
      start = Protocol.uint(start, "stack start")
      levels = Protocol.uint(levels, "stack levels")
      send_request(
        "stackTrace",
        {threadId: thread_id, startFrame: start, levels: levels},
        states: [:stopped]
      ) { |body| Results.stack_frames(body) }
    end

    def scopes(frame_id)
      frame_id = Protocol.integer(frame_id, "frame id")
      stopped_generation = generation
      send_request("scopes", {frameId: frame_id}, states: [:stopped]) do |body|
        ensure_generation(stopped_generation)
        Results.scopes(body, stopped_generation)
      end
    end

    def variables(reference, start: nil, count: nil, filter: nil)
      stopped_generation = generation
      arguments = {variablesReference: Results.decode_reference(reference, stopped_generation)}
      arguments[:start] = Protocol.uint(start, "variable start") unless start.nil?
      arguments[:count] = Protocol.uint(count, "variable count") unless count.nil?
      arguments[:filter] = variable_filter(filter) unless filter.nil?
      send_request("variables", arguments, states: [:stopped]) do |body|
        ensure_generation(stopped_generation)
        Results.variables(body, stopped_generation)
      end
    end

    def set_variable(reference, name, value)
      stopped_generation = generation
      reference = Results.decode_reference(reference, stopped_generation)
      name = Protocol.string(name, "variable name")
      value = Protocol.string(value, "variable value")
      send_request(
        "setVariable",
        {variablesReference: reference, name: name, value: value},
        states: [:stopped]
      ) do |body|
        ensure_generation(stopped_generation)
        Results.set_variable(body, stopped_generation, name)
      end
    end

    def set_expression(expression, value, frame_id: nil)
      stopped_generation = generation
      expression = Protocol.string(expression, "expression", empty: false)
      value = Protocol.string(value, "expression value")
      arguments = {expression: expression, value: value}
      arguments[:frameId] = Protocol.integer(frame_id, "frame id") unless frame_id.nil?
      send_request("setExpression", arguments, states: [:stopped]) do |body|
        ensure_generation(stopped_generation)
        Results.set_variable(body, stopped_generation, expression)
      end
    end

    def evaluate(expression, frame_id: nil, context: "repl")
      stopped_generation = generation
      expression = Protocol.string(expression, "expression")
      context = Protocol.string(context, "evaluation context", empty: false)
      arguments = {expression: expression, context: context}
      arguments[:frameId] = Protocol.integer(frame_id, "frame id") unless frame_id.nil?
      send_request("evaluate", arguments, states: [:stopped]) do |body|
        ensure_generation(stopped_generation)
        Results.evaluate(body, stopped_generation, expression)
      end
    end

    def completions(text, column, frame_id: nil)
      text = Protocol.string(text, "completion text")
      column = Protocol.uint(column, "completion column")
      arguments = {text: text, column: column}
      arguments[:frameId] = Protocol.integer(frame_id, "frame id") unless frame_id.nil?
      send_request("completions", arguments, states: [:stopped]) { |body| Results.completions(body) }
    end

    def source(reference)
      reference = Protocol.uint(reference, "source reference")
      send_request("source", {sourceReference: reference}, states: %i[configuring running stopped]) do |body|
        Results.source_content(body)
      end
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

    def variable_filter(value)
      value = value.to_s
      raise ArgumentError, "filter must be indexed or named" unless %w[indexed named].include?(value)

      value
    end

    def ensure_generation(expected)
      raise Error, "debuggee resumed while request was pending" unless generation == expected && state == :stopped
    end
  end
end
