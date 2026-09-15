# frozen_string_literal: true

module Megrez
  class Future
    class Subscription
      def initialize(&detach) = @detach = detach

      def detach
        callback, @detach = @detach, nil
        callback&.call
      end
    end

    attr_reader :id, :callback_errors

    def initialize(id, on_error: nil, &cancel)
      @id = id
      @cancel_callback = cancel
      @on_error = on_error
      @lock = Mutex.new
      @ready = ConditionVariable.new
      @callbacks = []
      @callback_errors = []
    end

    def fulfill(value = nil, error: nil)
      callbacks = @lock.synchronize do
        return if @done

        @value = value
        @error = error
        @done = true
        @ready.broadcast
        saved, @callbacks = @callbacks, []
        saved
      end
      callbacks.each { |callback| invoke(callback, @value, @error) }
      self
    end

    def then(&callback)
      raise ArgumentError, "callback required" unless callback

      ready = @lock.synchronize do
        @callbacks << callback unless @done
        @done
      end
      invoke(callback, @value, @error) if ready
      self
    end

    def on_complete(&callback)
      raise ArgumentError, "callback required" unless callback

      self.then(&callback)
      Subscription.new { @lock.synchronize { @callbacks.delete(callback) } }
    end

    def done? = @lock.synchronize { !!@done }

    def await(timeout: nil)
      valid = timeout.nil? || (timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0)
      raise ArgumentError, "timeout must be finite and nonnegative" unless valid

      deadline = timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @lock.synchronize do
        until @done
          remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Timeout, "DAP request #{@id} timed out" if remaining && remaining <= 0

          @ready.wait(@lock, remaining)
        end
        raise @error if @error

        @value
      end
    rescue Timeout
      cancel
      raise
    end

    def cancel
      callback = @lock.synchronize do
        return false if @done || @cancelling

        @cancelling = true
        @cancel_callback
      end
      invoke(->(*) { callback.call(@id) }, nil, nil) if callback
      fulfill(error: Cancelled.new("DAP request #{@id} cancelled"))
      true
    end

    private

    def invoke(callback, value, error)
      callback.call(value, error)
    rescue StandardError => callback_error
      bounded = Error.new("#{callback_error.class}: #{callback_error.message}".scrub.byteslice(0, 2048).scrub(""))
      @lock.synchronize do
        @callback_errors << bounded
        @callback_errors.shift if @callback_errors.length > 32
      end
      begin
        @on_error&.call(bounded)
      rescue StandardError
        nil
      end
    end
  end
end
