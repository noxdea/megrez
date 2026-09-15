# frozen_string_literal: true

module Megrez
  module Results
    module_function

    def capabilities(body)
      Protocol.deep_freeze(Protocol.object(body, "initialize response").dup)
    end

    def breakpoints(body)
      array(body, "breakpoints").map do |value|
        value = Protocol.object(value, "breakpoint")
        Breakpoint.new(
          id: optional_integer(value["id"], "breakpoint id"),
          verified: Protocol.boolean(value["verified"], "breakpoint verified"),
          source: source(value["source"]),
          line: optional_uint(value["line"], "breakpoint line"),
          column: optional_uint(value["column"], "breakpoint column"),
          message: Protocol.optional_string(value["message"], "breakpoint message")
        )
      end.freeze
    end

    def threads(body)
      array(body, "threads").map do |value|
        value = Protocol.object(value, "thread")
        ThreadInfo.new(
          id: Protocol.integer(value["id"], "thread id"),
          name: Protocol.string(value["name"], "thread name")
        )
      end.freeze
    end

    def stack_frames(body)
      array(body, "stackFrames").map do |value|
        value = Protocol.object(value, "stack frame")
        StackFrame.new(
          id: Protocol.integer(value["id"], "stack frame id"),
          name: Protocol.string(value["name"], "stack frame name"),
          source: source(value["source"]),
          line: Protocol.uint(value["line"], "stack frame line"),
          column: Protocol.uint(value["column"], "stack frame column"),
          presentation_hint: Protocol.optional_string(value["presentationHint"], "stack frame presentationHint")
        )
      end.freeze
    end

    def scopes(body, generation)
      array(body, "scopes").map do |value|
        value = Protocol.object(value, "scope")
        Scope.new(
          name: Protocol.string(value["name"], "scope name"),
          variables_reference: encode_reference(value["variablesReference"], generation),
          expensive: Protocol.boolean(value["expensive"], "scope expensive"),
          presentation_hint: Protocol.optional_string(value["presentationHint"], "scope presentationHint")
        )
      end.freeze
    end

    def variables(body, generation)
      array(body, "variables").map { |value| variable(value, generation) }.freeze
    end

    def set_variable(body, generation, name)
      value = Protocol.object(body, "setVariable response").merge("name" => name)
      variable(value, generation)
    end

    def evaluate(body, generation, expression)
      value = Protocol.object(body, "evaluate response").merge(
        "name" => expression,
        "value" => body["result"]
      )
      variable(value, generation)
    end

    def completions(body)
      array(body, "targets").map do |value|
        value = Protocol.object(value, "completion target")
        Protocol.string(value["label"], "completion label")
        %w[text sortText type].each do |key|
          Protocol.optional_string(value[key], "completion #{key}") if value.key?(key)
        end
        %w[start length selectionStart selectionLength].each do |key|
          Protocol.optional_uint(value[key], "completion #{key}") if value.key?(key)
        end
        Protocol.deep_freeze(value.dup)
      end.freeze
    end

    def source_content(body)
      body = Protocol.object(body, "source response")
      Protocol.string(body["content"], "source content")
      Protocol.optional_string(body["mimeType"], "source mimeType") if body.key?("mimeType")
      Protocol.deep_freeze(body.dup)
    end

    def body(body)
      Protocol.deep_freeze(Protocol.object(body, "DAP response body").dup)
    end

    def encode_reference(value, generation)
      value = Protocol.uint(value, "variablesReference")
      return 0 if value.zero?
      raise Error, "variablesReference is too large" if value > 0x7fff_ffff

      (generation << 32) | value
    end

    def decode_reference(value, generation)
      value = Protocol.uint(value, "variables reference")
      raise Error, "variables reference is not expandable" if value.zero?

      encoded_generation = value >> 32
      raise Error, "stale variables reference" unless encoded_generation == generation

      value & 0xffff_ffff
    end

    def variable(value, generation)
      value = Protocol.object(value, "variable")
      Variable.new(
        name: Protocol.string(value["name"], "variable name"),
        value: Protocol.string(value["value"], "variable value"),
        type: Protocol.optional_string(value["type"], "variable type"),
        variables_reference: encode_reference(value.fetch("variablesReference", 0), generation),
        named_count: optional_uint(value["namedVariables"], "variable namedVariables"),
        indexed_count: optional_uint(value["indexedVariables"], "variable indexedVariables"),
        memory_reference: Protocol.optional_string(value["memoryReference"], "variable memoryReference")
      )
    end

    def source(value)
      return nil if value.nil?

      value = Protocol.object(value, "source").dup
      Protocol.optional_string(value["name"], "source name") if value.key?("name")
      Protocol.optional_string(value["path"], "source path") if value.key?("path")
      Protocol.optional_uint(value["sourceReference"], "source reference") if value.key?("sourceReference")
      Protocol.deep_freeze(value)
    end

    def array(body, key)
      body = Protocol.object(body, "DAP response body")
      Protocol.collection(body[key], key)
    end

    def optional_uint(value, name) = value.nil? ? nil : Protocol.uint(value, name)
    def optional_integer(value, name) = value.nil? ? nil : Protocol.integer(value, name)
  end
end
