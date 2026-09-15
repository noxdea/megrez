# frozen_string_literal: true

require_relative "test_helper"

class SessionTest < Minitest::Test
  def test_handshake_breakpoints_and_state_machine
    session, adapter = session_for
    breakpoint = Megrez::SourceBreakpoint.new(
      line: 4, column: 2, condition: "ready?", hit_condition: "3", log_message: "hit"
    )

    assert_equal :initialized, session.state
    assert_raises(Megrez::Error) { session.launch({}) }
    capabilities = session.start(adapter_id: "fake")
    assert capabilities.frozen?
    assert_raises(Megrez::Error) { session.start(adapter_id: "fake") }
    assert_equal({}, session.launch("program" => "app.rb").await(timeout: 1))
    assert_equal :configuring, session.state

    result = session.set_breakpoints("app.rb", [breakpoint]).await(timeout: 1)
    assert_equal [4], result.map(&:line)
    assert result.first.verified
    assert result.first.frozen?
    assert_equal 1, session.set_function_breakpoints(["main"]).await(timeout: 1).length
    assert_equal 1, session.set_exception_breakpoints(["raised"]).await(timeout: 1).length
    assert_equal 1, session.set_data_breakpoints([{dataId: "object.value"}]).await(timeout: 1).length

    session.configuration_done.await(timeout: 1)
    wait_until { session.state == :stopped }
    assert_equal 1, session.generation
    commands = adapter.messages.select { |message| message["type"] == "request" }.map { |message| message["command"] }
    assert_equal %w[initialize launch setBreakpoints setFunctionBreakpoints setExceptionBreakpoints setDataBreakpoints configurationDone], commands
    assert_raises(Megrez::Error) { session.configuration_done }
  ensure
    session&.close
  end

  def test_stack_variables_evaluation_and_stale_generation
    session, adapter = stopped_session(variable_count: 3)

    assert_equal [Megrez::ThreadInfo.new(id: 1, name: "main")], session.threads.await(timeout: 1)
    frame = session.stack_trace(1).await(timeout: 1).first
    assert_equal "main", frame.name
    scope = session.scopes(frame.id).await(timeout: 1).first
    variables = session.variables(scope.variables_reference, start: 0, count: 3, filter: :named).await(timeout: 1)
    assert_equal %w[value0 value1 value2], variables.map(&:name)
    assert_equal "changed", session.set_variable(scope.variables_reference, "value0", "changed").await(timeout: 1).value
    assert_equal "changed", session.set_expression("value0", "changed", frame_id: frame.id).await(timeout: 1).value
    assert_equal "42", session.evaluate("6 * 7", frame_id: frame.id).await(timeout: 1).value
    assert_equal "value", session.completions("val", 3, frame_id: frame.id).await(timeout: 1).first["label"]
    assert_equal "puts :ok\n", session.source(1).await(timeout: 1)["content"]

    adapter.emit("stopped", "reason" => "step", "threadId" => 1)
    wait_until { session.generation == 2 }
    error = assert_raises(Megrez::Error) { session.variables(scope.variables_reference) }
    assert_match(/stale/, error.message)
  ensure
    session&.close
  end

  def test_execution_control_and_event_order
    dispatch = ->(&block) { Thread.new { sleep 0.001; block.call } }
    session, adapter = stopped_session(dispatch: dispatch)
    events = []
    %i[continued stopped output terminated].each do |event|
      session.on(event) { |body| events << [event, body] }
    end

    session.step_over(1, granularity: :line).await(timeout: 1)
    wait_until { session.state == :stopped && session.generation == 2 }
    assert_equal %i[continued stopped], events.map(&:first)

    session.continue(1, all: true).await(timeout: 1)
    wait_until { session.state == :running }
    adapter.emit("output", "category" => "stdout", "output" => "one")
    adapter.emit("stopped", "reason" => "pause", "threadId" => 1)
    adapter.emit("output", "category" => "stdout", "output" => "two")
    wait_until { events.length == 5 }
    assert_equal %i[continued stopped continued output stopped], events.map(&:first)
    assert session.pause(1).await(timeout: 1) if session.state == :running
    assert_raises(Megrez::Error) { session.step_in(1, target_id: 2) } unless session.state == :stopped
  ensure
    session&.close
  end

  def test_request_cancellation_and_timeout_send_cancel
    session, adapter = session_for
    session.start(adapter_id: "fake")

    future = session.request("never")
    assert future.cancel
    assert_raises(Megrez::Cancelled) { future.await }
    wait_until { adapter.messages.any? { |message| message["command"] == "cancel" } }

    timed = session.request("never")
    assert_raises(Megrez::Timeout) { timed.await(timeout: 0.001) }
    wait_until { adapter.messages.count { |message| message["command"] == "cancel" } == 2 }
  ensure
    session&.close
  end

  def test_adapter_errors_and_invalid_results_reject_only_the_request
    failed_response = lambda do |_arguments, request|
      [{"seq" => 900, "type" => "response", "request_seq" => request["seq"], "success" => false,
        "command" => request["command"], "message" => "denied", "body" => {"error" => {"id" => 1}}}]
    end
    adapter = Megrez::Testing::FakeAdapter.new(responses: {
      "fail" => failed_response,
      "threads" => {"threads" => "invalid"}
    })
    session, = session_for(adapter)
    session.start(adapter_id: "fake")

    error = assert_raises(Megrez::AdapterError) { session.request("fail").await(timeout: 1) }
    assert_equal "fail", error.command
    assert_equal "denied", error.message
    session.launch({}).await(timeout: 1)
    session.configuration_done.await(timeout: 1)
    wait_until { session.state == :stopped }
    assert_raises(Megrez::Error) { session.threads.await(timeout: 1) }
    assert_equal :stopped, session.state
  ensure
    session&.close
  end

  def test_rejected_transition_restores_the_previous_state
    failed_launch = lambda do |_arguments, request|
      [{"seq" => 901, "type" => "response", "request_seq" => request["seq"], "success" => false,
        "command" => "launch", "message" => "invalid configuration"}]
    end
    adapter = Megrez::Testing::FakeAdapter.new(responses: {"launch" => failed_launch})
    session, = session_for(adapter)
    session.start(adapter_id: "fake")

    assert_raises(Megrez::AdapterError) { session.launch({}).await(timeout: 1) }
    assert_equal :initialized, session.state
  ensure
    session&.close
  end

  def test_adapter_reverse_requests_are_answered
    session, adapter = session_for
    received = []
    session.on_request("startDebugging") do |arguments|
      received << arguments
      {accepted: true}
    end
    session.start(adapter_id: "fake")

    request = adapter.request_client("startDebugging", "configuration" => {"name" => "child"})
    wait_until do
      adapter.messages.any? { |message| message["type"] == "response" && message["request_seq"] == request["seq"] }
    end
    response = adapter.messages.find { |message| message["type"] == "response" && message["request_seq"] == request["seq"] }
    assert response["success"]
    assert_equal({"accepted" => true}, response["body"])
    assert received.first.frozen?

    unknown = adapter.request_client("runInTerminal", {})
    wait_until do
      adapter.messages.any? { |message| message["type"] == "response" && message["request_seq"] == unknown["seq"] }
    end
    response = adapter.messages.find { |message| message["type"] == "response" && message["request_seq"] == unknown["seq"] }
    refute response["success"]
  ensure
    session&.close
  end

  private

  def stopped_session(variable_count: 3, **options)
    adapter = Megrez::Testing::FakeAdapter.new(variable_count: variable_count)
    session, = session_for(adapter, **options)
    session.start(adapter_id: "fake")
    session.launch({}).await(timeout: 1)
    session.configuration_done.await(timeout: 1)
    wait_until { session.state == :stopped }
    [session, adapter]
  end
end
