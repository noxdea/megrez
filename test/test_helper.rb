# frozen_string_literal: true

require "minitest/autorun"
require "megrez/testing"

module MegrezTestSupport
  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not reached" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.001
    end
  end

  def session_for(adapter = Megrez::Testing::FakeAdapter.new, **options)
    [Megrez::Session.new(adapter.transport, **options), adapter]
  end
end

class Minitest::Test
  include MegrezTestSupport
end
