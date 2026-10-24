# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class HealthServerTest < Minitest::Test
  include RuntimeTestHelpers

  cover "Robin::HealthServer*"

  class FakeLauncher
    attr_accessor :report

    def initialize = @report = {"healthy" => true, "status" => "ok"}

    def health = @report
  end

  # A client socket stand-in for #answer.
  class FakeClient
    attr_reader :log

    def initialize(readable: true, read: "GET / HTTP/1.0\r\n\r\n", write: nil)
      @readable = readable
      @read = read
      @write = write
      @log = []
    end

    def wait_readable(timeout) = (@log << [:wait, timeout]) && @readable

    def readpartial(limit)
      @log << [:read, limit]
      raise @read if @read.is_a?(Class)

      @read
    end

    def write(data)
      @log << [:write, data]
      raise @write if @write
    end

    def close = @log << :close
  end

  def setup
    @launcher = FakeLauncher.new
    @server = Robin::HealthServer.new(@launcher, port: 0, bind: "127.0.0.1")
  end

  def teardown
    @server.stop
  end

  def test_response
    ok = Robin::HealthServer.response({"healthy" => true, "a" => 1})

    assert_equal "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 22\r\n" \
                 "connection: close\r\n\r\n{\"healthy\":true,\"a\":1}", ok
    bad = Robin::HealthServer.response({"healthy" => false})

    assert bad.start_with?("HTTP/1.1 503 Service Unavailable\r\n")
    assert bad.end_with?("content-length: 17\r\nconnection: close\r\n\r\n{\"healthy\":false}")
  end

  def test_serves_the_launchers_health
    assert_operator @server.port, :>, 0
    assert_equal Robin::HealthServer.response(@launcher.report), http_get(@server.port)
    @launcher.report = {"healthy" => false, "status" => "stale"}

    assert_includes http_get(@server.port), "503 Service Unavailable"
    thread = @server.instance_variable_get(:@thread)

    assert_equal "robin.health", thread.name
  end

  def test_listens_on_the_given_address
    assert_equal "127.0.0.1", @server.instance_variable_get(:@server).addr[3]
    server = Robin::HealthServer.new(@launcher, port: 0)

    # JRuby binds 0.0.0.0 as a dual-stack socket.
    assert_equal (RUBY_ENGINE == "jruby") ? "::" : "0.0.0.0", server.instance_variable_get(:@server).addr[3]
  ensure
    server&.stop
  end

  def test_stop_closes_the_port_and_ends_the_thread
    thread = @server.instance_variable_get(:@thread)
    @server.stop

    refute_predicate thread, :alive?
    assert_raises(Errno::ECONNREFUSED) { http_get(@server.port) }
    @server = Robin::HealthServer.new(@launcher, port: 0, bind: "127.0.0.1")
  end

  # JRuby 10.0's close can raise in the closing thread as it closes.
  def test_stop_when_closing_raises
    server = @server.instance_variable_get(:@server)
    close = server.method(:close)
    server.define_singleton_method(:close) do
      close.call
      raise IOError, "stream closed in another thread"
    end
    thread = @server.instance_variable_get(:@thread)
    @server.stop

    refute_predicate thread, :alive?
    assert_raises(Errno::ECONNREFUSED) { http_get(@server.port) }
    @server = Robin::HealthServer.new(@launcher, port: 0, bind: "127.0.0.1")
  end

  def test_stop_waits_up_to_a_second_for_the_thread
    joined = []
    thread = @server.instance_variable_get(:@thread)
    thread.define_singleton_method(:join) { |t| joined << t }
    @server.stop

    assert_equal [1], joined
    @server = Robin::HealthServer.new(@launcher, port: 0, bind: "127.0.0.1")
  end

  def test_answer_reads_the_request_then_responds_and_closes
    client = FakeClient.new
    @server.send(:answer, client)

    assert_equal [[:wait, 1], [:read, 16_384], [:write, Robin::HealthServer.response(@launcher.report)], :close], client.log
  end

  def test_silent_clients_are_dropped
    client = FakeClient.new(readable: nil)
    @server.send(:answer, client)

    assert_equal [[:wait, 1], :close], client.log
  end

  def test_clients_that_go_away_are_ignored
    [FakeClient.new(read: EOFError), FakeClient.new(write: Errno::EPIPE)].each do |client|
      @server.send(:answer, client)

      assert_equal :close, client.log.last
    end
  end

  def test_keeps_serving_after_a_client_hangs_up
    Socket.tcp("127.0.0.1", @server.port, &:close)

    assert_includes http_get(@server.port), "200 OK"
  end
end
