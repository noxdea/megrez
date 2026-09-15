# frozen_string_literal: true

module Megrez
  module Testing
    class FakeTransport < Transport
      STOP = Object.new.freeze
      private_constant :STOP

      attr_reader :stderr_lines, :pid

      def initialize(adapter, &receive)
        @adapter = adapter
        @receive = receive
        @stderr_lines = []
        @pid = Process.pid
        @lock = Mutex.new
        @write_lock = Mutex.new
        @responses = Queue.new
        @alive = true
        @sink = @adapter.attach { |messages| enqueue(messages) }
        @reader = Thread.new { read }
        @reader.report_on_exception = false
      end

      def listen(&receive)
        raise ArgumentError, "receiver required" unless receive
        raise Error, "debug adapter transport is already listening" if @receive

        @receive = receive
        self
      end

      def write(message)
        message = wire(message)
        responses = @write_lock.synchronize do
          raise Error, "debug adapter write failed: closed transport" unless alive?

          @adapter.dispatch(message)
        end
        enqueue(responses)
        nil
      end

      def alive? = @lock.synchronize { @alive }

      def close
        reader = @lock.synchronize do
          if @alive
            @alive = false
            @responses << STOP
          end
          @reader
        end
        @adapter.detach(@sink)
        return if reader == Thread.current

        reader.kill unless reader.join(1)
        reader.join
        nil
      end

      private

      def wire(message)
        frame = Transport.frame(message)
        Transport.read_message(StringIO.new(frame))
      end

      def enqueue(messages)
        values = messages.map { |message| wire(message) }
        @lock.synchronize do
          return unless @alive

          values.each { |message| @responses << message }
        end
      end

      def read
        loop do
          message = @responses.pop
          break if message.equal?(STOP)

          @receive.call(message, nil)
        end
      rescue StandardError => error
        @receive.call(nil, error) if alive?
      ensure
        @lock.synchronize { @alive = false }
      end
    end
  end
end
