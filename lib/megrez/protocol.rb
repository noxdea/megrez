# frozen_string_literal: true

module Megrez
  module Protocol
    MAX_COLLECTION = 100_000
    MAX_DEPTH = 64

    module_function

    def validate_message(message)
      raise Error, "DAP message must be an object" unless message.is_a?(Hash)

      uint(message["seq"], "DAP seq", positive: true)
      case message["type"]
      when "request" then validate_request(message)
      when "response" then validate_response(message)
      when "event" then validate_event(message)
      else raise Error, "invalid DAP message type"
      end
      message
    end

    def validate_outbound(value)
      validate_json(value, 0)
      value
    end

    def validate_request(message)
      string(message["command"], "DAP command", empty: false, max: 256)
      validate_json(object(message["arguments"], "DAP request arguments"), 0) if message.key?("arguments")
      forbidden = %w[request_seq success event]
      raise Error, "invalid DAP request fields" if forbidden.any? { |key| message.key?(key) }
    end

    def validate_response(message)
      uint(message["request_seq"], "DAP request_seq", positive: true)
      boolean(message["success"], "DAP response success")
      string(message["command"], "DAP response command", empty: false, max: 256)
      string(message["message"], "DAP response message", max: 4096) if message.key?("message")
      validate_json(object(message["body"], "DAP response body"), 0) if message.key?("body")
      raise Error, "invalid DAP response fields" if message.key?("event")
    end

    def validate_event(message)
      string(message["event"], "DAP event", empty: false, max: 256)
      validate_json(object(message["body"], "DAP event body"), 0) if message.key?("body")
      forbidden = %w[request_seq success command]
      raise Error, "invalid DAP event fields" if forbidden.any? { |key| message.key?(key) }
    end

    def validate_json(value, depth)
      raise Error, "DAP value is nested too deeply" if depth > MAX_DEPTH

      case value
      when nil, true, false, Integer, String
        string(value, "DAP string") if value.is_a?(String)
      when Float
        raise Error, "DAP number must be finite" unless value.finite?
      when Array
        collection(value, "DAP array").each { |item| validate_json(item, depth + 1) }
      when Hash
        value.each do |key, item|
          raise Error, "DAP object keys must be strings or symbols" unless key.is_a?(String) || key.is_a?(Symbol)

          string(key.to_s, "DAP object key", empty: false, max: 1024)
          validate_json(item, depth + 1)
        end
      else
        raise Error, "unsupported DAP value: #{value.class}"
      end
    end

    def object(value, name)
      raise Error, "#{name} must be an object" unless value.is_a?(Hash)

      value
    end

    def collection(value, name)
      raise Error, "#{name} must be an array" unless value.is_a?(Array)
      raise Error, "#{name} has too many elements" if value.length > MAX_COLLECTION

      value
    end

    def string(value, name, empty: true, max: 1 << 20)
      valid = value.is_a?(String) && value.encoding != Encoding::BINARY && value.valid_encoding? && !value.include?("\0")
      valid &&= !value.empty? unless empty
      valid &&= value.bytesize <= max
      raise Error, "#{name} must be a valid UTF-8 string" unless valid

      value
    end

    def integer(value, name)
      raise Error, "#{name} must be an integer" unless value.is_a?(Integer)

      value
    end

    def uint(value, name, positive: false)
      integer(value, name)
      minimum = positive ? 1 : 0
      raise Error, "#{name} must be at least #{minimum}" if value < minimum

      value
    end

    def boolean(value, name)
      raise Error, "#{name} must be boolean" unless value == true || value == false

      value
    end

    def optional_string(value, name, **options)
      value.nil? ? nil : string(value, name, **options)
    end

    def optional_uint(value, name)
      value.nil? ? nil : uint(value, name)
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      when Array
        value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
  end
end
