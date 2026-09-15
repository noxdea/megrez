# frozen_string_literal: true

require "json"

module Megrez
  class Transport
    def self.read_message(io)
      headers = {}
      bytes = 0
      loop do
        line = io.gets("\r\n", MAX_HEADER_LINE + 1)
        return nil if line.nil? && headers.empty?
        valid = line && line.end_with?("\r\n") && line.bytesize <= MAX_HEADER_LINE
        raise Error, "truncated or oversized DAP header" unless valid
        break if line == "\r\n"

        bytes += line.bytesize
        raise Error, "oversized DAP headers" if bytes > MAX_HEADERS
        raise Error, "non-ASCII DAP header" unless line.ascii_only?

        key, value = line.strip.split(":", 2)
        raise Error, "invalid DAP header" unless value && key.match?(/\A[A-Za-z][A-Za-z0-9-]*\z/)

        key = key.downcase
        raise Error, "duplicate DAP header" if headers.key?(key)

        headers[key] = value.strip
      end

      raw_length = headers["content-length"]
      raise Error, "missing or invalid Content-Length" unless raw_length&.match?(/\A\d+\z/)

      length = Integer(raw_length, 10)
      raise Error, "oversized DAP message" unless length.between?(1, MAX_MESSAGE)

      charset = headers["content-type"]&.match(/charset\s*=\s*"?([^;"\s]+)/i)&.[](1)
      raise Error, "unsupported DAP character encoding" if charset && !%w[utf-8 utf8].include?(charset.downcase)

      body = io.read(length)
      raise Error, "truncated DAP body" unless body && body.bytesize == length

      body.force_encoding(Encoding::UTF_8)
      raise Error, "invalid DAP UTF-8 body" unless body.valid_encoding?

      Protocol.validate_message(JSON.parse(body))
    rescue JSON::ParserError => error
      raise Error, "invalid DAP JSON: #{error.message.byteslice(0, 256)}"
    end

    def self.frame(message)
      raise Error, "DAP message must be an object" unless message.is_a?(Hash)

      normalized = JSON.parse(JSON.generate(message))
      Protocol.validate_message(normalized)
      body = JSON.generate(message).b
      raise Error, "oversized DAP message" unless body.bytesize.between?(1, MAX_MESSAGE)

      "Content-Length: #{body.bytesize}\r\n\r\n".b + body
    rescue JSON::GeneratorError, JSON::NestingError => error
      raise Error, "invalid DAP JSON: #{error.message.byteslice(0, 256)}"
    end
  end
end
