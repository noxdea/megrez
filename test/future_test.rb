# frozen_string_literal: true

require_relative "test_helper"

class FutureTest < Minitest::Test
  def test_completion_callbacks_and_cancellation_are_bounded
    cancellations = []
    completed = []
    reported = []
    future = Megrez::Future.new(7, on_error: ->(error) { reported << error }) { |id| cancellations << id }
    subscription = future.on_complete { completed << :detached }
    subscription.detach
    40.times { future.then { raise "failure" * 1000 } }
    future.then { |value, error| completed << [value, error.class] }

    assert future.cancel
    refute future.cancel
    assert future.done?
    assert_equal [7], cancellations
    assert_equal [[nil, Megrez::Cancelled]], completed
    assert_equal 32, future.callback_errors.length
    assert_equal 40, reported.length
    assert future.callback_errors.all? { |error| error.message.bytesize <= 2048 }
    assert_raises(Megrez::Cancelled) { future.await }
  end

  def test_await_timeout_cancels_request
    cancellations = []
    future = Megrez::Future.new(9) { |id| cancellations << id }

    assert_raises(Megrez::Timeout) { future.await(timeout: 0.001) }
    assert_equal [9], cancellations
    assert_raises(ArgumentError) { future.await(timeout: Float::NAN) }
  end

  def test_fulfilled_value_is_returned_without_cancellation
    future = Megrez::Future.new(1) { flunk "completed request was cancelled" }
    future.fulfill(42)

    assert_equal 42, future.await(timeout: 0)
    refute future.cancel
  end
end
