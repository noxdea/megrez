# frozen_string_literal: true

require_relative "megrez/version"

module Megrez
  class Error < StandardError; end
  class Timeout < Error; end
  class Cancelled < Error; end

  class AdapterError < Error
    attr_reader :command, :body

    def initialize(command, message, body = nil)
      @command = command
      @body = body
      super(message)
    end
  end

  module Value
    module_function

    def define(*members)
      return Data.define(*members) if defined?(Data)

      Struct.new(*members) do
        members.each { |member| undef_method("#{member}=") }

        define_method(:initialize) do |*values, **keywords|
          if keywords.empty?
            raise ArgumentError, "wrong number of arguments" unless values.length == self.class.members.length

            super(*values)
          else
            raise ArgumentError, "cannot mix positional and keyword arguments" unless values.empty?

            missing = self.class.members - keywords.keys
            unknown = keywords.keys - self.class.members
            raise ArgumentError, "missing keyword: #{missing.first.inspect}" unless missing.empty?
            raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?

            super(*self.class.members.map { |member| keywords.fetch(member) })
          end
          freeze
        end

        define_method(:with) do |**changes|
          return self if changes.empty?

          unknown = changes.keys - self.class.members
          raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?

          self.class.new(**to_h.merge(changes))
        end
      end
    end
  end

  Breakpoint = Value.define(:id, :verified, :source, :line, :column, :message)
  SourceBreakpoint = Value.define(:line, :column, :condition, :hit_condition, :log_message)
  StackFrame = Value.define(:id, :name, :source, :line, :column, :presentation_hint)
  Scope = Value.define(:name, :variables_reference, :expensive, :presentation_hint)
  Variable = Value.define(:name, :value, :type, :variables_reference,
    :named_count, :indexed_count, :memory_reference)
  ThreadInfo = Value.define(:id, :name)
  private_constant :Value
end

require_relative "megrez/protocol"
require_relative "megrez/results"
require_relative "megrez/future"
require_relative "megrez/transport"
require_relative "megrez/session"
