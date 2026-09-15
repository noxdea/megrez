# frozen_string_literal: true

require_relative "../test_helper"

class FakeAdapterConformanceTest < Minitest::Test
  def test_break_stop_variables_step_resume_and_terminate
    adapter = Megrez::Testing::FakeAdapter.new
    session = Megrez::Session.new(adapter.transport)
    initialized = Queue.new
    stopped = Queue.new
    session.on(:initialized) { initialized << true }
    session.on(:stopped) { |event| stopped << event }

    session.start(adapter_id: "fake")
    launch = session.launch("program" => "app.rb")
    wait_until { !initialized.empty? }
    breakpoint = Megrez::SourceBreakpoint.new(
      line: 1, column: nil, condition: nil, hit_condition: nil, log_message: nil
    )
    assert session.set_breakpoints("app.rb", [breakpoint]).await(timeout: 1).first.verified
    session.configuration_done.await(timeout: 1)
    launch.await(timeout: 1)
    wait_until { !stopped.empty? }
    assert_equal "breakpoint", stopped.pop.fetch("reason")

    frame = session.stack_trace(1).await(timeout: 1).first
    scope = session.scopes(frame.id).await(timeout: 1).first
    refute_empty session.variables(scope.variables_reference).await(timeout: 1)
    session.step_over(1).await(timeout: 1)
    wait_until { !stopped.empty? }
    assert_equal "breakpoint", stopped.pop.fetch("reason")
    session.continue(1).await(timeout: 1)
    session.terminate.await(timeout: 1)
    wait_until { session.state == :terminated }
  ensure
    session&.close
  end
end
