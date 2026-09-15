# frozen_string_literal: true

module Megrez
  class Session
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
