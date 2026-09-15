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

  def test_launch_response_may_wait_for_configuration_done
    launch_request = nil
    adapter = Megrez::Testing::FakeAdapter.new(responses: {
      "launch" => lambda do |_arguments, request|
        launch_request = request
        [{"seq" => 800, "type" => "event", "event" => "initialized", "body" => {}}]
      end,
      "configurationDone" => lambda do |_arguments, request|
        [
          {"seq" => 801, "type" => "response", "request_seq" => request["seq"],
           "success" => true, "command" => "configurationDone", "body" => {}},
          {"seq" => 802, "type" => "response", "request_seq" => launch_request["seq"],
           "success" => true, "command" => "launch", "body" => {}}
        ]
      end
    })
    session, = session_for(adapter)
    initialized = Queue.new
    session.on(:initialized) { initialized << true }
    session.start(adapter_id: "fake")

    launch = session.launch("program" => "app.rb")
    wait_until { !initialized.empty? }
    refute launch.done?
    assert_equal({}, session.configuration_done.await(timeout: 1))
    assert_equal({}, launch.await(timeout: 1))
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
    wait_until { events.length >= 6 }
    assert_equal %i[continued stopped continued output stopped output], events.map(&:first)
    assert_raises(Megrez::Error) { session.pause(1) }
    session.continue(1).await(timeout: 1)
    wait_until { session.state == :running }
    session.pause(1).await(timeout: 1)
    wait_until { session.state == :stopped }
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

    request = adapter.messages.find { |message| message["command"] == "never" }
    session.send(:enqueue, {
      "seq" => 999, "type" => "response", "request_seq" => request["seq"],
      "success" => true, "command" => "never", "body" => {}
    }, nil)
    assert_empty session.errors
  ensure
    session&.close
  end

  def test_event_handler_can_await_a_follow_up_request
    session, adapter = stopped_session
    result = Queue.new
    session.on(:stopped) do
      frame = session.stack_trace(1).await(timeout: 1).first
      result << frame.name
    end

    adapter.emit("stopped", "reason" => "step", "threadId" => 1)

    wait_until { !result.empty? }
    assert_equal "main", result.pop
  ensure
    session&.close
  end

  def test_queued_event_is_ignored_after_close
    callbacks = Queue.new
    session, adapter = session_for(dispatch: ->(&block) { callbacks << block })
    called = false
    session.on(:stopped) { called = true }
    adapter.emit("stopped", "reason" => "pause", "threadId" => 1)
    wait_until { !callbacks.empty? }

    session.close
    callbacks.pop.call

    assert_equal :terminated, session.state
    refute called
  ensure
    session&.close
  end

  def test_unhandled_event_names_are_not_retained
    session, adapter = session_for
    received = Queue.new
    session.on(:marker) { received << true }
    100.times { |index| adapter.emit("unknown#{index}") }
    adapter.emit("marker")
    wait_until { !received.empty? }

    assert_equal [:marker], session.instance_variable_get(:@handlers).keys
  ensure
    session&.close
  end

  def test_close_during_a_write_still_reports_a_session_error
    entered = Queue.new
    release = Queue.new
    transport_class = Class.new do
      define_method(:initialize) do |entered_queue, release_queue|
        @entered = entered_queue
        @release = release_queue
      end
      define_method(:listen) { |&_receive| self }
      define_method(:write) do |_message|
        @entered << true
        @release.pop
        raise Megrez::Error, "write failed"
      end
      define_method(:close) { @release << true }
    end
    session = Megrez::Session.new(transport_class.new(entered, release))
    failure = Queue.new
    worker = Thread.new do
      session.start(adapter_id: "fake")
    rescue StandardError => error
      failure << error
    end
    entered.pop

    session.close
    worker.join

    assert_kind_of Megrez::Error, failure.pop
  ensure
    session&.close
    worker&.kill
    worker&.join
  end

  def test_close_does_not_restore_a_pending_disconnect_state
    adapter = Megrez::Testing::FakeAdapter.new(responses: {"disconnect" => ->(*) { [] }})
    session, = session_for(adapter)
    session.start(adapter_id: "fake")
    disconnect = session.disconnect

    session.close

    assert_equal :terminated, session.state
    assert_raises(Megrez::Error) { disconnect.await }
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

    initialize_request = adapter.messages.find { |message| message["command"] == "initialize" }
    assert initialize_request.dig("arguments", "supportsStartDebuggingRequest")
    refute initialize_request.dig("arguments", "supportsRunInTerminalRequest")

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
