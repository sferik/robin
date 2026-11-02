# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SystemdTest < Minitest::Test
  cover "Robin::Systemd*"

  Systemd = Robin::Systemd

  def with_notify_socket
    Dir.mktmpdir("robin-sd") do |dir|
      path = File.join(dir, "notify")
      server = Socket.new(:UNIX, :DGRAM)
      begin
        server.bind(Socket.sockaddr_un(path))
      rescue SocketError
        skip "no datagram Unix sockets on #{RUBY_ENGINE}"
      end
      yield path, server
    ensure
      server&.close
    end
  end

  def test_notify_sends_the_state
    with_notify_socket do |path, server|
      assert Systemd.notify("READY=1\nSTATUS=working", env: {"NOTIFY_SOCKET" => path})
      assert_equal "READY=1\nSTATUS=working", server.recv(100)
    end
  end

  def test_notify_without_a_socket_is_a_no_op
    refute Systemd.notify("READY=1", env: {})
    refute Systemd.notify("READY=1", env: {"NOTIFY_SOCKET" => ""})
  end

  def test_unsupported_sockets_are_quiet
    socket = Object.new
    socket.define_singleton_method(:connect) { |_| raise SocketError, "No message available" }
    original = Socket.method(:open)
    Socket.define_singleton_method(:open) { |*, &blk| blk.call(socket) }

    refute Systemd.notify("READY=1", env: {"NOTIFY_SOCKET" => "/run/notify"})
  ensure
    Socket.define_singleton_method(:open, original)
  end

  def test_notify_failures_are_quiet
    refute Systemd.notify("READY=1", env: {"NOTIFY_SOCKET" => "/nonexistent/robin/notify"})
    refute Systemd.notify("READY=1", env: {"NOTIFY_SOCKET" => "x" * 200}) # too long for a socket path
  end

  def test_notify_defaults_to_the_process_environment
    with_notify_socket do |path, server|
      ENV["NOTIFY_SOCKET"] = path

      assert Systemd.notify("WATCHDOG=1")
      assert_equal "WATCHDOG=1", server.recv(100)
    ensure
      ENV.delete("NOTIFY_SOCKET")
    end
  end

  def test_abstract_addresses
    assert_equal "\0robin/notify", Systemd.address("@robin/notify")
    assert_equal "/run/systemd/notify", Systemd.address("/run/systemd/notify")
  end

  def test_watchdog
    refute Systemd.watchdog?(env: {}, pid: 1)
    refute Systemd.watchdog?(env: {"WATCHDOG_USEC" => "0"}, pid: 1)
    assert Systemd.watchdog?(env: {"WATCHDOG_USEC" => "30000000"}, pid: 1)
    assert Systemd.watchdog?(env: {"WATCHDOG_USEC" => "30000000", "WATCHDOG_PID" => ""}, pid: 1)
    assert Systemd.watchdog?(env: {"WATCHDOG_USEC" => "30000000", "WATCHDOG_PID" => "42"}, pid: 42)
    refute Systemd.watchdog?(env: {"WATCHDOG_USEC" => "30000000", "WATCHDOG_PID" => "42"}, pid: 43)
    refute Systemd.watchdog?(env: {"WATCHDOG_USEC" => "30000000", "WATCHDOG_PID" => "nope"}, pid: 43)
    ENV["WATCHDOG_USEC"] = "1"
    ENV["WATCHDOG_PID"] = Process.pid.to_s

    assert_predicate Systemd, :watchdog?
  ensure
    ENV.delete("WATCHDOG_USEC")
    ENV.delete("WATCHDOG_PID")
  end
end
