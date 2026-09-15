# frozen_string_literal: true

require_relative "test_helper"

class TransportTest < Minitest::Test
  def test_frame_round_trip
    message = {seq: 1, type: "event", event: "output", body: {output: "hello 日本語\n"}}
    frame = Megrez::Transport.frame(message)

    assert_equal JSON.parse(JSON.generate(message)), Megrez::Transport.read_message(StringIO.new(frame))
  end

  def test_rejects_invalid_headers_and_bodies
    valid = '{"seq":1,"type":"event","event":"stopped"}'
    cases = [
      "Content-Type: application/json\r\n\r\n#{valid}",
      "Content-Length: x\r\n\r\n#{valid}",
      "Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
      "Content-Length: 20\r\n\r\n{}",
      "Content-Length: 1\n\n{}",
      "Content-Length: 2\r\n\r\n[]",
      "Content-Length: 2\r\nContent-Type: application/json; charset=latin1\r\n\r\n{}"
    ]

    cases.each { |frame| assert_raises(Megrez::Error) { Megrez::Transport.read_message(StringIO.new(frame.b)) } }
  end

  def test_rejects_malformed_messages_and_resource_exhaustion
    invalid = [
      {seq: 0, type: "event", event: "stopped"},
      {seq: 1, type: "unknown"},
      {seq: 1, type: "request", command: ""},
      {seq: 1, type: "response", request_seq: 1, success: "yes", command: "x"},
      {seq: 1, type: "event", event: "x", body: []},
      {seq: 1, type: "event", event: "x", body: {items: Array.new(100_001)}}
    ]
    invalid.each { |message| assert_raises(Megrez::Error) { Megrez::Transport.frame(message) } }

    huge = {seq: 1, type: "event", event: "output", body: {output: "x" * (33 << 20)}}
    assert_raises(Megrez::Error) { Megrez::Transport.frame(huge) }
  end

  def test_stdio_transport_uses_an_argument_array
    session = Megrez::Session.stdio(command: Megrez::Testing::FakeAdapter.command)

    assert session.start(adapter_id: "fake")["supportsCancelRequest"]
    assert_equal({}, session.request("echo", value: 1).await(timeout: 1))
    assert session.transport.pid
    assert session.transport.stderr_lines.all? { |line| line.bytesize <= Megrez::Transport::MAX_HEADER_LINE }
  ensure
    session&.close
  end

  def test_tcp_transport_round_trip
    adapter = Megrez::Testing::FakeAdapter.new
    server = TCPServer.new("127.0.0.1", 0)
    worker = Thread.new do
      socket = server.accept
      adapter.serve(socket)
      socket.close
    end
    session = Megrez::Session.tcp(host: "127.0.0.1", port: server.local_address.ip_port)

    assert_equal adapter.instance_variable_get(:@capabilities), session.start(adapter_id: "fake")
  ensure
    session&.close
    server&.close
    if worker && !worker.join(1)
      worker.kill
      worker.join
    end
  end

  def test_transport_factory_validates_process_boundaries
    invalid_commands = ["ruby", [], ["ruby", "bad\0arg"]]
    invalid_commands.each do |command|
      assert_raises(ArgumentError) { Megrez::Transport.stdio(command: command) }
    end
    assert_raises(ArgumentError) { Megrez::Transport.stdio(command: ["ruby"], env: {"BAD=KEY" => "x"}) }
    assert_raises(ArgumentError) { Megrez::Transport.tcp(host: "", port: 1) }
    assert_raises(ArgumentError) { Megrez::Transport.tcp(host: "localhost", port: 0) }
  end
end
