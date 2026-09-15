# frozen_string_literal: true

require "megrez/testing"

def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

session = nil
begin
  adapter = Megrez::Testing::FakeAdapter.new(variable_count: 100)
  session = Megrez::Session.new(adapter.transport)
  stops = Queue.new
  session.on(:stopped) { |_event| stops << monotonic }
  session.start(adapter_id: "fake")
  session.launch({}).await(timeout: 1)
  session.configuration_done.await(timeout: 1)
  stops.pop

  scope = session.scopes(session.stack_trace(1).await(timeout: 1).first.id).await(timeout: 1).first
  variable_samples = Array.new(20) do
    started = monotonic
    values = session.variables(scope.variables_reference).await(timeout: 1)
    raise "expected 100 variables" unless values.length == 100

    (monotonic - started) * 1000
  end

  stack_samples = Array.new(20) do
    adapter.emit("stopped", "reason" => "breakpoint", "threadId" => 1)
    stopped_at = stops.pop
    session.stack_trace(1).await(timeout: 1)
    (monotonic - stopped_at) * 1000
  end

  variable_ms = variable_samples.sort.fetch(variable_samples.length / 2)
  stack_ms = stack_samples.sort.fetch(stack_samples.length / 2)
  puts format("variables (100): %.3f ms", variable_ms)
  puts format("stopped to stackTrace: %.3f ms", stack_ms)

  if ENV["BUDGET"] == "1"
    raise format("variable budget exceeded: %.3f ms > 50 ms", variable_ms) if variable_ms > 50
    raise format("stackTrace budget exceeded: %.3f ms > 5 ms", stack_ms) if stack_ms > 5
  end
ensure
  session&.close
end
