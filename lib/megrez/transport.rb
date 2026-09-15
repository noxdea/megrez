# frozen_string_literal: true

require "open3"
require "socket"

module Megrez
  class Transport
    MAX_MESSAGE = 32 << 20
    MAX_HEADER_LINE = 8192
    MAX_HEADERS = 16_384

    attr_reader :stderr_lines, :pid

    def self.stdio(command:, env: {}, cwd: nil)
      valid = command.is_a?(Array) && !command.empty? && command.all? do |part|
        part.is_a?(String) && !part.empty? && !part.include?("\0")
      end
      raise ArgumentError, "command must be a nonempty argument array" unless valid
      raise ArgumentError, "environment must be a string map" unless valid_environment?(env)
      raise ArgumentError, "cwd must be a path string" unless cwd.nil? || (cwd.is_a?(String) && !cwd.include?("\0"))

      options = cwd ? {chdir: cwd} : {}
      input, output, error, process = Open3.popen3(env, *command, **options)
      new(output, input, process: process, stderr: error, closeables: [input, output, error])
    rescue SystemCallError => error
      raise Error, "debug adapter spawn failed: #{error.message}"
    end

    def self.tcp(host:, port:, connect_timeout: 10)
      valid_host = host.is_a?(String) && !host.empty? && !host.include?("\0")
      valid_port = port.is_a?(Integer) && port.between?(1, 65_535)
      valid_timeout = connect_timeout.is_a?(Numeric) && connect_timeout.finite? && connect_timeout.positive?
      raise ArgumentError, "host must be a nonempty string" unless valid_host
      raise ArgumentError, "port must be between 1 and 65535" unless valid_port
      raise ArgumentError, "connect_timeout must be positive and finite" unless valid_timeout

      socket = Socket.tcp(host, port, connect_timeout: connect_timeout)
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      new(socket, socket, closeables: [socket])
    rescue SystemCallError, SocketError => error
      raise Error, "debug adapter connection failed: #{error.message}"
    end

    def self.valid_environment?(env)
      env.is_a?(Hash) && env.all? do |key, value|
        key.is_a?(String) && !key.empty? && !key.include?("\0") && !key.include?("=") &&
          (value.nil? || (value.is_a?(String) && !value.include?("\0")))
      end
    end

    def initialize(input, output, process: nil, stderr: nil, closeables: [])
      @input = input
      @output = output
      @process = process
      @stderr = stderr
      @closeables = closeables.uniq
      @pid = process&.pid
      @stderr_lines = []
      @write_lock = Mutex.new
      @close_lock = Mutex.new
      @closing = false
      [@input, @output, @stderr].compact.uniq.each(&:binmode)
    end

    def listen(&receive)
      raise ArgumentError, "receiver required" unless receive

      @close_lock.synchronize do
        raise Error, "debug adapter transport is closed" if @closing
        raise Error, "debug adapter transport is already listening" if @reader

        @reader = Thread.new { read(receive) }
        @logger = Thread.new { read_stderr } if @stderr
        [@reader, @logger].compact.each { |thread| thread.report_on_exception = false }
      end
      self
    end

    def write(message)
      frame = self.class.frame(message)
      @write_lock.synchronize do
        raise Error, "debug adapter write failed: closed transport" unless alive?

        @output.write(frame)
        @output.flush
      end
      nil
    rescue IOError, SystemCallError => error
      raise Error, "debug adapter write failed: #{error.message}"
    end

    def alive?
      @close_lock.synchronize do
        !@closing && (@process ? @process.alive? : !@input.closed? && !@output.closed?)
      end
    end

    def close
      threads = @close_lock.synchronize do
        next if @closing

        @closing = true
        [@reader, @logger]
      end
      return unless threads

      begin
        @output.close unless @output.closed?
        stop_process
      ensure
        @closeables.each do |io|
          io.close unless io.closed?
        rescue IOError
          nil
        end
        threads.compact.each do |thread|
          next if thread == Thread.current

          thread.kill unless thread.join(1)
          thread.join(1)
        end
      end
      nil
    end

    private

    def read(receive)
      while (message = self.class.read_message(@input))
        receive.call(message, nil)
      end
      receive.call(nil, Error.new("debug adapter closed its connection")) unless closing?
    rescue StandardError => error
      begin
        receive.call(nil, error) unless closing?
      rescue StandardError
        nil
      end
    end

    def read_stderr
      while (line = @stderr.gets("\n", MAX_HEADER_LINE))
        @stderr_lines << line.scrub.byteslice(0, MAX_HEADER_LINE).scrub("")
        @stderr_lines.shift if @stderr_lines.length > 200
      end
    rescue IOError
      nil
    end

    def closing? = @close_lock.synchronize { @closing }

    def stop_process
      return unless @process
      return if @process.join(1)

      Process.kill("TERM", @process.pid)
      return if @process.join(1)

      Process.kill("KILL", @process.pid)
      @process.join(1)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end

require_relative "transport/framing"
