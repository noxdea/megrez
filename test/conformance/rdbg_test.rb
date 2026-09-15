# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require "bundler"
require_relative "../test_helper"

class RdbgConformanceTest < Minitest::Test
  def test_break_variables_step_resume_and_exit
    skip "set MEGREZ_ADAPTERS=ruby to run" unless ENV.fetch("MEGREZ_ADAPTERS", "").split(",").include?("ruby")

    Dir.mktmpdir("megrez-rdbg") do |directory|
      program = File.join(directory, "program.rb")
      File.write(program, "value = 41\nvalue += 1\nputs value\n")
      port = available_port
      log = File.join(directory, "rdbg.log")
      command = ENV.fetch("RDBG", "rdbg")
      pid = Bundler.with_unbundled_env do
        Process.spawn(
          command, "--open=vscode", "--host", "127.0.0.1", "--port", port.to_s, "--", program,
          out: log, err: log
        )
      end
      session = connect(port, pid, log)
      stopped = Queue.new
      session.on(:stopped) { |event| stopped << event }

      session.start(adapter_id: "rdbg", timeout: 5)
      session.launch("localfs" => true).await(timeout: 5)
      breakpoint = Megrez::SourceBreakpoint.new(
        line: 2, column: nil, condition: nil, hit_condition: nil, log_message: nil
      )
      assert session.set_breakpoints(program, [breakpoint]).await(timeout: 5).first.verified
      session.configuration_done.await(timeout: 5)
      assert stopped.pop.fetch("threadId")

      frame = session.stack_trace(1).await(timeout: 5).first
      scope = session.scopes(frame.id).await(timeout: 5).first
      assert session.variables(scope.variables_reference).await(timeout: 5).any? { |variable| variable.name == "value" }
      session.step_over(1).await(timeout: 5)
      assert stopped.pop.fetch("threadId")
      session.continue(1).await(timeout: 5)
      wait_until(timeout: 5) { session.state == :terminated }
    ensure
      session&.close
      stop_process(pid)
    end
  end

  private

  def available_port
    server = TCPServer.new("127.0.0.1", 0)
    server.local_address.ip_port
  ensure
    server&.close
  end

  def connect(port, pid, log)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      return Megrez::Session.tcp(host: "127.0.0.1", port: port, connect_timeout: 0.2)
    rescue Megrez::Error
      Process.waitpid(pid, Process::WNOHANG)&.then do
        raise "rdbg exited before accepting DAP: #{File.read(log).byteslice(0, 2048)}"
      end
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def stop_process(pid)
    return unless pid
    return if Process.waitpid(pid, Process::WNOHANG)

    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
