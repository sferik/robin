# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/redis"
require_relative "support/runtime"
require "timeout"

# Generate the TLS certificates once, up front (mutant forks after loading
# the tests, so the forks share them).
FakeRedis.tls("DNS:localhost,IP:127.0.0.1")
FakeRedis.tls("DNS:elsewhere.example")

class ConnectionTestCase < Minitest::Test
  Connection = Robin::Redis::Connection

  # A socket stand-in whose methods can be made to fail.
  class FakeSocket
    attr_reader :closed

    def initialize(write: nil, read: :wait_readable, close: nil)
      @write = write
      @read = read
      @close = close
    end

    def write_nonblock(data, **)
      raise @write if @write

      data.bytesize
    end

    def read_nonblock(*, **)
      raise @read if @read.is_a?(Class)

      @read
    end

    def wait_readable(_timeout) = true

    def to_io = self

    def close
      @closed = true
      raise @close if @close
    end
  end

  def setup
    @servers = []
    @saved_env = ENV.to_h.slice("ROBIN_REDIS_URL", "REDIS_URL", "REDIS_PROVIDER", "ROBIN_NO_EXT")
    %w[ROBIN_REDIS_URL REDIS_URL REDIS_PROVIDER ROBIN_NO_EXT].each { |k| ENV.delete(k) }
  end

  def teardown
    @conn&.close
    @servers.each(&:close)
    %w[ROBIN_REDIS_URL REDIS_URL REDIS_PROVIDER ROBIN_NO_EXT].each { |k| ENV.delete(k) }
    @saved_env.each { |k, v| ENV[k] = v }
  end

  def server(...)
    FakeRedis.new(...).tap { |s| @servers << s }
  end

  def connect(server, **)
    target = server.path ? {path: server.path} : {host: "127.0.0.1", port: server.port}
    @conn = Connection.new(**target, **)
  end

  def real
    @conn = Connection.new(url: REDIS_URL)
  end

  def sock(conn = @conn) = conn.instance_variable_get(:@sock)

  # Gives +conn+ a socket (read by Ruby, not the C extension).
  def give(conn, socket) = conn.instance_variable_set(:@sock, socket)

  def elapsed
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end

  def closed_port
    s = TCPServer.new("127.0.0.1", 0)
    s.addr[1].tap { s.close }
  end

  private

  def eventually_true(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
  end
end

class ConnectionParserTest < ConnectionTestCase
  cover "Robin::Redis.parser"

  def test_parser_selection
    loaded = []
    loader = ->(path) { loaded << path }

    assert_same Robin::Redis::RESP, Robin::Redis.parser(disabled: true, loader: loader)
    assert_empty loaded
    assert_same Robin::Redis::RESP, Robin::Redis.parser(disabled: false, loader: ->(_) { raise LoadError })
    skip "native parser not compiled" unless defined?(Robin::Redis::NativeRESP)

    assert_same Robin::Redis::NativeRESP, Robin::Redis.parser(disabled: false, loader: loader)
    assert_equal ["robin_resp/robin_resp"], loaded
  end

  def test_parser_honors_robin_no_ext
    refuse = ->(_) { flunk "must not load the extension" }
    ENV["ROBIN_NO_EXT"] = "1"

    assert_same Robin::Redis::RESP, Robin::Redis.parser(loader: refuse)
    ENV.delete("ROBIN_NO_EXT")
    loaded = []
    Robin::Redis.parser(loader: ->(path) { (loaded << path) && raise(LoadError) })

    assert_equal ["robin_resp/robin_resp"], loaded
  end

  def test_parser_loads_with_kernel_require_by_default
    parser = Robin::Redis.parser(disabled: false) # (may load the extension)

    assert_includes [Robin::Redis::RESP, defined?(Robin::Redis::NativeRESP) && Robin::Redis::NativeRESP], parser
  end
end

class ConnectionOptionsTest < ConnectionTestCase
  cover "Robin::Redis::Connection.parse_url"
  cover "Robin::Redis::Connection.tcp_options"
  cover "Robin::Redis::Connection#initialize"
  cover "Robin::Redis::Connection#id"

  def test_parse_url_tcp
    assert_equal({ssl: false, host: "example.com", port: 6380, db: 3}, Connection.parse_url("redis://example.com:6380/3"))
    assert_equal({ssl: true, host: "h", port: 1}, Connection.parse_url("rediss://h:1"))
    assert_equal({ssl: false, host: "h", port: 1}, Connection.parse_url("valkey://h:1/"))
    assert_equal({ssl: true, host: "h"}, Connection.parse_url("valkeys://h"))
    assert_equal({ssl: false}, Connection.parse_url("redis://"))
    assert_equal({ssl: false, db: 3}, Connection.parse_url("redis:/3"))
    assert_equal({ssl: false}, Connection.parse_url("redis:opaque"))
  end

  def test_parse_url_credentials_and_query
    assert_equal({ssl: false, host: "h", username: "us er", password: "p@ss"}, Connection.parse_url("redis://us%20er:p%40ss@h"))
    assert_equal({ssl: false, host: "h", password: "secret"}, Connection.parse_url("redis://:secret@h"))
    assert_equal({ssl: false, host: "h", username: "solo"}, Connection.parse_url("redis://solo@h"))
    assert_equal({ssl: false, host: "h", db: 4}, Connection.parse_url("redis://h/2?db=4&foo=7"))
    assert_equal({path: "/tmp/redis.sock", db: 2}, Connection.parse_url("unix:///tmp/redis.sock?db=2"))
    assert_equal({path: "/tmp/r.sock"}, Connection.parse_url("unix:///tmp/r.sock"))
  end

  def test_parse_url_rejects_bad_input
    error = assert_raises(ArgumentError) { Connection.parse_url("http://h") }
    assert_equal 'unsupported Redis URL scheme: "http"', error.message
    assert_raises(ArgumentError) { Connection.parse_url("redis://h/x") }
    assert_raises(ArgumentError) { Connection.parse_url("redis://h?db=x") }
  end

  def test_invalid_urls_never_show_the_password
    ["redis://:s3cr^t@redis:6379/0", "redis://user:p@ss^w0rd@h:1/2", "rediss://:a/b^c@h", "redis://h:1^"].each do |url|
      error = assert_raises(ArgumentError, url) { Connection.new(url: url) }

      refute_match(/s3cr|ss\^w0rd|a\/b|\^c/, error.message)
      assert_match(/\Ainvalid Redis URL: rediss?:\/\//, error.message)
    end
    assert_equal "redis://REDACTED@h:1/2", Connection.redact("redis://user:p@ss@h:1/2")
    assert_equal "redis://REDACTED@h", Connection.redact("redis://:x\n@y@h")
    assert_equal "redis://h:1/2", Connection.redact("redis://h:1/2")
    assert_equal "", Connection.redact(nil)
  end

  def test_options_and_defaults
    conn = Connection.new(url: "redis://h:7/2", port: 9, name: "n")

    assert_equal Connection::DEFAULTS.merge(host: "h", port: 9, db: 2, ssl: false, name: "n"), conn.options
    assert_equal "h:9/2", conn.id
    assert_equal "/s", Connection.new(path: "/s").id
    error = assert_raises(ArgumentError) { Connection.new(bogus: 1, other: 2) }
    assert_equal "unknown Redis options: bogus, other", error.message
  end

  def test_environment_urls
    ENV["REDIS_URL"] = "redis://from-redis-url:1"

    assert_equal "from-redis-url", Connection.new.options[:host]
    ENV["ROBIN_REDIS_URL"] = "redis://from-robin:1"

    assert_equal "from-robin", Connection.new.options[:host]
    assert_equal "explicit", Connection.new(host: "explicit").options[:host]
    assert_equal 6379, Connection.new(host: "explicit").options[:port]
    assert_equal "127.0.0.1", Connection.new(path: "/p").options[:host]
    assert_equal "from-url", Connection.new(url: "redis://from-url").options[:host]
  end

  def test_redis_provider_names_the_variable_holding_the_url
    env = {"REDIS_PROVIDER" => "CLOUD_URL", "CLOUD_URL" => "redis://cloud:1", "REDIS_URL" => "redis://plain:2"}

    assert_equal "redis://cloud:1", Connection.env_url(env)
    assert_equal "redis://robin:3", Connection.env_url(env.merge("ROBIN_REDIS_URL" => "redis://robin:3"))
    assert_equal "redis://plain:2", Connection.env_url(env.merge("REDIS_PROVIDER" => "MISSING_URL"))
    assert_equal "redis://plain:2", Connection.env_url(env.merge("REDIS_PROVIDER" => ""))
    # A URL put straight into REDIS_PROVIDER works too.
    assert_equal "redis://direct:4", Connection.env_url(env.merge("REDIS_PROVIDER" => "redis://direct:4"))
    assert_nil Connection.env_url({})
    assert_equal "redis://plain:2", Connection.env_url({"REDIS_URL" => "redis://plain:2"})
    ENV["REDIS_PROVIDER"] = "ROBIN_TEST_PROVIDED"
    ENV["ROBIN_TEST_PROVIDED"] = "redis://provided:5"

    assert_equal "provided", Connection.new.options[:host]
  ensure
    ENV.delete("REDIS_PROVIDER")
    ENV.delete("ROBIN_TEST_PROVIDED")
  end

  def test_inspect_hides_the_password
    conn = Connection.new(url: "redis://user:secret@h:7/2")

    assert_equal "#<Robin::Redis::Connection h:7/2>", conn.inspect
    refute_includes Robin::Redis::Pool.new(size: 1) { conn }.tap { |p| p.with { nil } }.inspect, "secret"
  end

  def test_defaults_without_environment
    assert_equal Connection::DEFAULTS, Connection.new.options
  end
end

class ConnectionScriptTest < ConnectionTestCase
  cover "Robin::Redis::Script*"
  cover "Robin::Redis::Pipeline*"
  cover "Robin::Redis::Pipeline#evalsha" # (as ConnectionTest says it too)

  def test_script_and_pipeline
    script = Robin::Redis::Script.new("  return 1  \n")

    assert_equal "return 1", script.source
    assert_predicate script.source, :frozen?
    assert_equal Digest::SHA1.hexdigest("return 1"), script.sha
    assert_predicate script.sha, :frozen?

    pipe = Robin::Redis::Pipeline.new

    assert_nil pipe.call("GET", "a")
    assert_nil pipe.evalsha(script, ["k"], ["v"])
    assert_nil pipe.evalsha(script)
    assert_equal [["GET", "a"], ["EVAL", "return 1", 1, "k", "v"], ["EVAL", "return 1", 0]], pipe.commands, "a transaction's"
    assert_empty pipe.loads
    assert_empty pipe.loading
  end

  def test_a_pipelines_scripts
    script = Robin::Redis::Script.new("return 1")
    known = Robin::Redis::Script.new("return 2")
    pipe = Robin::Redis::Pipeline.new(Set[known.sha])
    pipe.call("GET", "a")

    assert_nil pipe.evalsha(script, ["k"], ["v"])
    assert_nil pipe.evalsha(script)
    assert_nil pipe.evalsha(known)
    assert_equal [["GET", "a"], ["SCRIPT", "LOAD", "return 1"], ["EVALSHA", script.sha, 1, "k", "v"], ["EVALSHA", script.sha, 0],
      ["EVALSHA", known.sha, 0]], pipe.commands
    assert_equal [1], pipe.loads
    assert_equal [script.sha], pipe.loading
  end
end

class ConnectionTest < ConnectionTestCase
  cover "Robin::Redis::Connection#initialize"
  cover "Robin::Redis::Connection#reset"
  cover "Robin::Redis::Connection#call"
  cover "Robin::Redis::Connection#blocking_call"
  cover "Robin::Redis::Connection#pipelined"
  cover "Robin::Redis::Pipeline#evalsha"
  cover "Robin::Redis::Connection#multi"
  cover "Robin::Redis::Connection#evalsha"
  cover "Robin::Redis::Connection#close"
  cover "Robin::Redis::Connection#call_with_timeout"
  cover "Robin::Redis::Connection#raise_first_error"
  cover "Robin::Redis::Connection#reconnect_error?"
  cover "Robin::Redis::Connection#encode"
  cover "Robin::Redis::Connection#roundtrip"
  cover "Robin::Redis::Connection#send_commands"
  cover "Robin::Redis::Connection#read_replies"
  cover "Robin::Redis::Connection#stale?"
  cover "Robin::Redis::Connection#connect"
  cover "Robin::Redis::Connection#open_socket"
  cover "Robin::Redis::Connection#handshake"
  cover "Robin::Redis::Connection#wrap_ssl"
  cover "Robin::Redis::Connection#write"
  cover "Robin::Redis::Connection#read_reply"
  cover "Robin::Redis::Connection#consume"
  cover "Robin::Redis::Connection#fill"
  cover "Robin::Redis::Connection#wait"
  cover "Robin::Redis::Connection#native_fill"
  cover "Robin::Redis.native_io"
  cover "Robin::Redis.encoder"

  def test_commands_round_trip
    conn = real

    assert_equal "PONG", conn.call("PING")
    assert_equal "PONG", conn.call(:PING)
    assert_raises(Robin::Redis::CommandError) { conn.call("NOPE") }
    assert_equal "PONG", conn.call("PING")
  end

  def test_large_values_need_partial_writes_and_reads
    conn = real
    key = "robintest:#{Process.pid}:big"
    big = "x" * 4_000_000

    assert_equal "OK", conn.call("SET", key, big)
    assert_equal big, conn.call("GET", key)
    conn.instance_variable_set(:@native_io, nil) # Ruby's own writes and reads

    assert_equal "OK", conn.call("SET", key, big.upcase)
    assert_equal big.upcase, conn.call("GET", key)
  ensure
    conn&.call("DEL", key)
  end

  def test_pipelined
    conn = real

    assert_empty(conn.pipelined { |_p| nil })
    assert_equal ["PONG", "x"], conn.pipelined { |p|
      p.call("PING")
      p.call("ECHO", "x")
    }
    error = assert_raises(Robin::Redis::CommandError) do
      conn.pipelined do |p|
        p.call("ECHO", "a")
        p.call("NOPE1")
        p.call("NOPE2")
      end
    end
    assert_match(/nope1/i, error.message)
    assert_equal "PONG", conn.call("PING")
  end

  # Records each round trip's commands.
  def recorded(conn)
    sent = []
    conn.define_singleton_method(:roundtrip) do |commands, timeout|
      sent << commands.map(&:first)
      super(commands, timeout)
    end
    sent
  end

  # A script nobody has loaded yet (its source is new every time).
  def fresh_script = Robin::Redis::Script.new("return #{rand(1 << 40)}")

  # A pipeline loads a script its server may not have, in the pipeline (its
  # reply isn't a result), then runs it by its SHA from then on.
  def test_pipelined_scripts_are_loaded_once
    conn = real
    script = fresh_script
    sent = recorded(conn)
    results = conn.pipelined do |p|
      p.call("PING")
      p.evalsha(script)
      p.evalsha(script, ["k"], ["v"])
    end

    assert_equal ["PONG", script.source[/\d+/].to_i, script.source[/\d+/].to_i], results
    assert_equal [%w[PING SCRIPT EVALSHA EVALSHA]], sent
    assert_equal [script.source[/\d+/].to_i], conn.pipelined { |p| p.evalsha(script) }
    assert_equal %w[EVALSHA], sent.last, "loaded: just its SHA"
  end

  def test_two_new_scripts_in_one_pipeline
    conn = real
    one = fresh_script
    two = fresh_script
    sent = recorded(conn)

    assert_equal [one, two].map { |s| s.source[/\d+/].to_i }, conn.pipelined { |p| [one, two].each { |s| p.evalsha(s) } }
    assert_equal [%w[SCRIPT EVALSHA SCRIPT EVALSHA]], sent
  end

  def test_a_script_run_alone_is_known_to_be_loaded
    conn = real
    script = fresh_script
    conn.evalsha(script)
    sent = recorded(conn)
    conn.pipelined { |p| p.evalsha(script) }

    assert_equal [%w[EVALSHA]], sent
  end

  # A server that lost a script (SCRIPT FLUSH) fails the pipeline once; the
  # connection then loads its scripts again.
  def test_a_lost_script_is_loaded_again
    conn = real
    conn.call("PING")
    script = fresh_script
    conn.instance_variable_get(:@scripts) << script.sha # as if loaded, and since lost
    error = assert_raises(Robin::Redis::CommandError) { conn.pipelined { |p| p.evalsha(script) } }

    assert_match(/\ANOSCRIPT/, error.message)
    assert_empty conn.instance_variable_get(:@scripts)
    assert_equal [script.source[/\d+/].to_i], conn.pipelined { |p| p.evalsha(script) }
  end

  def test_a_new_connection_knows_no_scripts
    conn = real
    script = fresh_script
    conn.pipelined { |p| p.evalsha(script) }
    conn.close
    sent = recorded(conn)
    conn.pipelined { |p| p.evalsha(script) }

    assert_equal [%w[SCRIPT EVALSHA]], sent, "it may be another server"
  end

  def test_other_errors_keep_the_scripts
    conn = real
    script = fresh_script
    conn.pipelined { |p| p.evalsha(script) }
    assert_raises(Robin::Redis::CommandError) { conn.pipelined { |p| p.call("NOPE") } }

    assert_includes conn.instance_variable_get(:@scripts), script.sha
  end

  def test_transactions_send_scripts_themselves
    conn = real
    script = fresh_script
    conn.pipelined { |p| p.evalsha(script) }
    sent = recorded(conn)

    assert_equal [script.source[/\d+/].to_i], conn.multi { |t| t.evalsha(script) }
    assert_equal [%w[MULTI EVAL EXEC]], sent
  end

  def test_multi
    conn = real
    key = "robintest:#{Process.pid}:m"

    assert_equal [1, 2], conn.multi { |t|
      t.call("INCR", key)
      t.call("INCR", key)
    }
    queue_error = assert_raises(Robin::Redis::CommandError) { conn.multi { |t| t.call("NOPE") } }
    assert_match(/unknown command/i, queue_error.message)
    conn.call("SET", key, "str")
    exec_error = assert_raises(Robin::Redis::CommandError) do
      conn.multi do |t|
        t.call("GET", key)
        t.call("LPUSH", key, "x")
      end
    end
    assert_match(/WRONGTYPE/, exec_error.message)
    assert_equal "PONG", conn.call("PING")
  ensure
    conn&.call("DEL", key)
  end

  def test_blocking_call_extends_read_timeout
    srv = server { |cmd, _|
      sleep 0.35 if cmd.first == "BLPOP"
      FakeRedis.ok
    }
    conn = connect(srv, read_timeout: 0.3)

    assert_equal "OK", conn.blocking_call(0.2, "BLPOP", "k", 1)
    assert_raises(Robin::Redis::TimeoutError) { conn.call("BLPOP", "k", 1) }
  end

  def test_a_pipeline_with_a_blocking_command_extends_read_timeout
    srv = server { |cmd, _|
      sleep 0.35 if cmd.first == "BLMOVE"
      sleep 0.1 if cmd.first == "GET"
      FakeRedis.ok
    }
    conn = connect(srv, read_timeout: 0.3)

    assert_equal %w[OK], conn.pipelined { |p| p.call("GET", "k") }, "waits up to the read timeout by default"
    blocking = ->(p) { [p.call("BLMOVE", "a", "b", "RIGHT", "LEFT", 1), p.call("SISMEMBER", "s", "m")] }

    assert_equal %w[OK OK], conn.pipelined(timeout: 0.2, &blocking)
    assert_raises(Robin::Redis::TimeoutError) { conn.pipelined(&blocking) }
  end

  def test_blocking_call_raises_error_replies
    srv = server { FakeRedis.error("ERR blocked") }

    assert_raises(Robin::Redis::CommandError) { connect(srv).blocking_call(1, "BLPOP") }
  end

  ROLE_ERRORS = ["READONLY You can't write against a read only replica.", "NOREPLICAS Not enough good replicas to write.",
    "UNBLOCKED force unblock from blocking operation, instance state changed (master -> replica?)",
    "MASTERDOWN Link with MASTER is down and replica-serve-stale-data is set to 'no'.",
    "LOADING Redis is loading the dataset in memory"].freeze

  def test_role_change_errors_reconnect_and_retry_a_single_command_once
    ROLE_ERRORS.each do |message|
      srv = server { |_cmd, index| index.zero? ? FakeRedis.error(message) : FakeRedis.ok }
      conn = connect(srv)

      assert_equal "OK", conn.call("SET", "k", "v")
      assert_equal "OK", conn.blocking_call(1, "BLMOVE", "a", "b", "RIGHT", "LEFT", 1)
      assert_equal [["SET", "k", "v"], ["SET", "k", "v"], ["BLMOVE", "a", "b", "RIGHT", "LEFT", "1"]], srv.received
      assert_equal 2, srv.connections
    end
  end

  def test_role_change_errors_give_up_after_one_retry_and_drop_the_connection
    srv = server { |cmd, _index| (cmd.first == "SET") ? FakeRedis.error(ROLE_ERRORS.first) : FakeRedis.ok }
    conn = connect(srv)

    error = assert_raises(Robin::Redis::CommandError) { conn.call("SET", "k", "v") }
    assert_equal ROLE_ERRORS.first, error.message
    assert_equal 2, srv.connections
    assert_nil sock(conn)
    assert_equal "OK", conn.call("PING")
    assert_equal 3, srv.connections
  end

  def test_role_change_errors_in_pipelines_and_transactions_drop_the_connection_without_retrying
    srv = server { |cmd, _index| (cmd.first == "SET") ? FakeRedis.error(ROLE_ERRORS.first) : FakeRedis.ok }
    conn = connect(srv)

    assert_raises(Robin::Redis::CommandError) do
      conn.pipelined do |p|
        p.call("PING")
        p.call("SET", "k", "v")
      end
    end
    assert_nil sock(conn)
    assert_equal [["PING"], ["SET", "k", "v"]], srv.received
    assert_raises(Robin::Redis::CommandError) { conn.multi { |t| t.call("SET", "k", "v") } }
    assert_nil sock(conn)
    assert_equal 2, srv.connections
    nested = server do |cmd, _index|
      (cmd.first == "EXEC") ? "*1\r\n#{FakeRedis.error(ROLE_ERRORS.last)}" : "+QUEUED\r\n"
    end
    conn = connect(nested)

    error = assert_raises(Robin::Redis::CommandError) { conn.multi { |t| t.call("GET", "k") } }
    assert_equal ROLE_ERRORS.last, error.message
    assert_nil sock(conn)
  end

  def test_other_error_replies_keep_the_connection
    ["ERR unknown command", "WRONGTYPE Operation against a key", "OOM command not allowed", "READONLYISH x", "ERR READONLY"].each do |message|
      srv = server { FakeRedis.error(message) }
      conn = connect(srv)

      assert_raises(Robin::Redis::CommandError) { conn.call("SET", "k", "v") }
      assert_raises(Robin::Redis::CommandError) { conn.pipelined { |p| p.call("SET", "k", "v") } }
      refute_nil sock(conn)
      assert_equal 2, srv.received.size
      assert_equal 1, srv.connections
    end
  end

  def test_evalsha_loads_missing_scripts
    script = Robin::Redis::Script.new("  return 1\n")
    loaded = false
    srv = server do |cmd, _|
      case cmd.first
      when "EVALSHA" then loaded ? FakeRedis.bulk("ran") : FakeRedis.error("NOSCRIPT No matching script")
      when "SCRIPT"
        loaded = true
        FakeRedis.bulk(script.sha)
      end
    end
    conn = connect(srv)

    ran, trips = RoundTrips.record { conn.evalsha(script, ["k1", "k2"], ["a"]) }

    assert_equal "ran", ran
    assert_equal 2, trips.size, "one more, to load it and run it again"
    assert_equal [
      ["EVALSHA", script.sha, "2", "k1", "k2", "a"],
      ["SCRIPT", "LOAD", "return 1"],
      ["EVALSHA", script.sha, "2", "k1", "k2", "a"]
    ], srv.received
    assert_equal "ran", assert_roundtrips(1) { conn.evalsha(script) }
    assert_equal [["EVALSHA", script.sha, "0"]], srv.received
  end

  def test_evalsha_raises_other_errors
    srv = server { FakeRedis.error("ERR boom NOSCRIPT") }
    conn = connect(srv)

    error = assert_raises(Robin::Redis::CommandError) { conn.evalsha(Robin::Redis::Script.new("return 1")) }
    assert_equal "ERR boom NOSCRIPT", error.message
    assert_equal 1, srv.received.size
  end

  def test_evalsha_against_real_redis
    conn = real
    script = Robin::Redis::Script.new("return ARGV[1] .. KEYS[1] -- #{rand(1 << 40)}") # new to the server

    assert_equal ["ab", 2], RoundTrips.record { conn.evalsha(script, ["b"], ["a"]) }.then { |ab, trips| [ab, trips.size] }
    assert_equal "ab", assert_roundtrips(1) { conn.evalsha(script, ["b"], ["a"]) }
  end

  def test_handshake_sends_auth_select_and_name
    srv = server
    conn = connect(srv, username: "u", password: "p", db: "3", name: "worker")
    conn.call("PING")

    assert_equal [["AUTH", "u", "p"], ["SELECT", "3"], ["CLIENT", "SETNAME", "worker"], ["PING"]], srv.received
  end

  def test_handshake_password_only_and_default_db
    srv = server
    connect(srv, password: "p").call("PING")

    assert_equal [["AUTH", "p"], ["PING"]], srv.received
  end

  def test_no_handshake_by_default
    srv = server
    connect(srv).call("PING")

    assert_equal [["PING"]], srv.received
  end

  def test_failed_auth_closes_the_socket
    srv = server { |cmd, _| (cmd.first == "AUTH") ? FakeRedis.error("WRONGPASS invalid") : FakeRedis.ok }
    conn = connect(srv, password: "bad")

    assert_raises(Robin::Redis::CommandError) { conn.call("PING") }
    assert_nil sock(conn)
    assert_raises(Robin::Redis::CommandError) { conn.call("PING") }
    assert_equal [["AUTH", "bad"], ["AUTH", "bad"]], srv.received
    assert_equal 2, srv.connections
  end

  def test_handshake_read_timeout_includes_connect_timeout
    srv = server { |cmd, _| (cmd.first == "AUTH") ? :ignore : FakeRedis.ok }
    conn = connect(srv, password: "p", connect_timeout: 0.1, read_timeout: 0.1)

    took = elapsed { assert_raises(Robin::Redis::TimeoutError) { Timeout.timeout(5) { conn.call("PING") } } }

    assert_operator took, :>=, 0.19
  end

  def test_unix_socket_paths
    path = REDIS_URL.start_with?("unix:") ? URI.parse(REDIS_URL).path : nil
    skip "test Redis isn't on a unix socket" unless path

    assert_equal "PONG", Connection.new(path: path).call("PING")
    assert_instance_of UNIXSocket, sock(@conn = Connection.new(path: path).tap { |c| c.call("PING") })
  end

  def test_connection_errors_are_wrapped
    conn = Connection.new(host: "127.0.0.1", port: closed_port)
    error = assert_raises(Robin::Redis::ConnectionError) { conn.call("PING") }
    assert_match(/\AErrno::ECONNREFUSED: .* \(127\.0\.0\.1:\d+\/0\)\z/, error.message)

    error = assert_raises(Robin::Redis::ConnectionError) { Connection.new(path: "/nonexistent/robin.sock").call("PING") }
    assert_match(/\AErrno::ENOENT: .*\(\/nonexistent\/robin\.sock\)\z/, error.message)
  end

  def test_socket_and_timeout_errors_are_wrapped
    [SocketError, IO::TimeoutError].each do |klass|
      conn = Connection.new(host: "h")
      conn.define_singleton_method(:open_socket) { raise klass, "nope" }

      error = assert_raises(Robin::Redis::ConnectionError) { conn.call("PING") }
      assert_equal "#{klass}: nope (h:6379/0)", error.message
    end
  end

  def test_tcp_socket_options
    skip "JRuby can't read TCP socket options back" if RUBY_ENGINE == "jruby"
    conn = connect(server(tcp: true))
    conn.call("PING")

    assert sock(conn).getsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY).bool
    assert sock(conn).getsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE).bool
  end

  def test_tls
    srv = server(tls: "DNS:localhost,IP:127.0.0.1", tcp: true)
    conn = connect(srv, ssl: true, ssl_params: {cert_store: FakeRedis.tls("DNS:localhost,IP:127.0.0.1").last})

    assert_equal "OK", conn.call("PING")
    assert_kind_of OpenSSL::SSL::SSLSocket, sock(conn)
    tcp = sock(conn).to_io
    conn.close

    assert_predicate tcp, :closed?
    eventually_true { srv.disconnects == 1 }
  end

  def test_tls_verifies_peer_by_default
    srv = server(tls: "DNS:localhost,IP:127.0.0.1", tcp: true)

    assert_raises(OpenSSL::SSL::SSLError) { connect(srv, ssl: true).call("PING") }
  end

  def test_tls_verifies_hostname
    names = "DNS:elsewhere.example"
    srv = server(tls: names, tcp: true)
    conn = connect(srv, ssl: true, ssl_params: {cert_store: FakeRedis.tls(names).last})

    error = assert_raises(OpenSSL::SSL::SSLError) { conn.call("PING") }
    # Robin's own check (the same on every engine), not OpenSSL's.
    assert_match(/does not match the server certificate/, error.message)
  end

  def test_tls_hostname_checks_can_be_turned_off
    names = "DNS:elsewhere.example"
    srv = server(tls: names, tcp: true)
    store = FakeRedis.tls(names).last

    assert_equal "OK", connect(srv, ssl: true, ssl_params: {cert_store: store, verify_hostname: false}).call("PING")
    assert_equal "OK", connect(srv, ssl: true, ssl_params: {verify_mode: OpenSSL::SSL::VERIFY_NONE}).call("PING")
  end

  def test_tls_handshake_timeout_closes_socket
    srv = server(tls: "DNS:localhost", mode: :silent, tcp: true)
    conn = connect(srv, ssl: true, connect_timeout: 0.1)

    assert_raises(Robin::Redis::TimeoutError) { Timeout.timeout(5) { conn.call("PING") } }
    eventually_true { srv.disconnects == 1 }
  end

  def test_url_scheme_turns_on_tls
    srv = server(tls: "DNS:localhost,IP:127.0.0.1", tcp: true)
    conn = @conn = Connection.new(url: "rediss://127.0.0.1:#{srv.port}", ssl_params: {cert_store: FakeRedis.tls("DNS:localhost,IP:127.0.0.1").last})

    assert_equal "OK", conn.call("PING")
  end

  def test_reconnects_when_server_closed_idle_connection
    srv = server do |cmd, index|
      case cmd.first
      when "BYE" then ->(s) { s.write("+bye\r\n") && s.close }
      when "DROP" then :close
      else FakeRedis.bulk("c#{index}")
      end
    end
    conn = connect(srv)

    assert_equal "bye", conn.call("BYE")
    sleep 0.05

    assert_equal "c1", conn.call("PING")
    assert_raises(Robin::Redis::ConnectionError) { conn.call("DROP") }
    assert_equal "c2", conn.call("PING")
  end

  def test_unsolicited_data_marks_the_connection_stale
    srv = server do |cmd, index|
      if cmd.first == "LATER"
        ->(s) { s.write("+ok\r\n+unexpected\r\n") }
      else
        FakeRedis.bulk("c#{index}")
      end
    end
    conn = connect(srv)

    assert_equal "ok", conn.call("LATER")
    # The extra reply is still buffered: the stream is out of sync.
    assert_equal "c1", conn.call("PING")
    assert_equal 2, srv.connections
  end

  def test_unsolicited_data_on_the_socket_marks_the_connection_stale
    srv = server do |cmd, index|
      if cmd.first == "LATER"
        lambda do |s|
          s.write("+ok\r\n")
          Thread.new do
            sleep 0.02
            s.write("+push\r\n")
          end
        end
      else
        FakeRedis.bulk("c#{index}")
      end
    end
    conn = connect(srv)

    assert_equal "ok", conn.call("LATER")
    sleep 0.1

    assert_equal "c1", conn.call("PING")
  end

  def test_stale_check_errors_reconnect
    [IOError, Errno::EBADF].each do |error|
      conn = connect(server)
      give(conn, FakeSocket.new(read: error))

      assert_equal "OK", conn.call("PING")
    end
  end

  def test_stale_check
    conn = Connection.new(host: "h")
    give(conn, FakeSocket.new)

    refute conn.send(:stale?)
    give(conn, FakeSocket.new(read: "+late\r\n"))

    assert conn.send(:stale?), "bytes nothing asked for"
    give(conn, FakeSocket.new(read: nil))

    assert conn.send(:stale?), "closed by the server"
    conn.instance_variable_set(:@buf, "+x".b)
    give(conn, FakeSocket.new)

    assert conn.send(:stale?), "leftover bytes mean the stream is out of sync"
  end

  def test_stale_check_asks_the_c_extension_when_it_reads
    conn = Connection.new(host: "h")
    give(conn, sock = Object.new)
    asked = []
    reader = Object.new
    reader.define_singleton_method(:stale?) { |io| (asked << io) && true }
    conn.instance_variable_set(:@native_io, reader)

    assert conn.send(:stale?)
    assert_equal [sock], asked
    reader.define_singleton_method(:stale?) { |_io| raise IOError, "closed stream" }

    assert conn.send(:stale?)
  end

  # Records the order of reads and waits on a real socket.
  def spy_on(conn, log)
    io = sock(conn)
    io.define_singleton_method(:wait_readable) { |t| (log << :wait) && super(t) }
    io.define_singleton_method(:read_nonblock) { |*a, **k| super(*a, **k).tap { |r| log << (r.instance_of?(Symbol) ? :not_yet : :read) } }
  end

  def test_replies_are_awaited_rather_than_read_for_first
    conn = connect(server)
    conn.call("PING")
    conn.instance_variable_set(:@native_io, nil) # Ruby's own reads
    log = []
    spy_on(conn, log)
    conn.call("PING")

    assert_equal %i[not_yet wait read], log, "the stale check's read, then the reply's"
  end

  # A socket whose replies are already there, that mustn't be waited on.
  def no_wait_socket(read)
    FakeSocket.new(read: read).tap { |f| f.define_singleton_method(:wait_readable) { |_t| raise "waited" } }
  end

  def test_buffered_replies_are_read_without_waiting
    conn = Connection.new(host: "h")
    give(conn, no_wait_socket(:wait_readable))
    conn.instance_variable_set(:@buf, "+x\r\n".b)

    assert_equal ["x"], conn.send(:read_replies, 1, 1)
  end

  # As the openssl gem before 3.3 (Ruby 3.3 and earlier) has it: a TLS
  # socket without wait methods, waiting on the socket under it.
  class WaitlessTLSSocket
    def initialize(io, replies)
      @io = io
      @replies = replies
    end

    def to_io = @io

    def read_nonblock(*, **) = @replies.shift

    def close = nil
  end

  def test_tls_waits_on_the_socket_under_it
    conn = Connection.new(host: "h", ssl: true)
    under = FakeSocket.new
    waits = []
    under.define_singleton_method(:wait_readable) { |t| (waits << t) && true }
    give(conn, WaitlessTLSSocket.new(under, [:wait_readable, "+x\r\n"]))

    assert_equal ["x"], conn.send(:read_replies, 1, 1)
    assert_equal [1], waits
    under.define_singleton_method(:wait_readable) { |_t| nil }
    give(conn, WaitlessTLSSocket.new(under, [:wait_readable]))
    error = assert_raises(Robin::Redis::TimeoutError) { conn.send(:read_replies, 1, 1) }

    assert_equal "timed out talking to Redis (h:6379/0)", error.message
  end

  def test_tls_reads_before_waiting
    conn = Connection.new(host: "h", ssl: true)
    give(conn, no_wait_socket("+x\r\n"))

    assert_equal ["x"], conn.send(:read_replies, 1, 1)
  end

  def test_encoder_is_the_extensions_where_it_has_one
    with_encode = Module.new { def self.encode(args, out) = out << args.inspect }

    assert_same with_encode, Robin::Redis.encoder(with_encode)
    assert_same Robin::Redis::RESP, Robin::Redis.encoder(Module.new)
    assert_same Robin::Redis.encoder(Robin::Redis::PARSER), Robin::Redis::ENCODER
    conn = Robin::Redis::Connection.new(url: REDIS_URL)

    assert_equal "*1\r\n$4\r\nPING\r\n*2\r\n$3\r\nGET\r\n$1\r\nk\r\n", conn.send(:encode, [["PING"], ["GET", "k"]])
  end

  def test_native_io_comes_with_the_c_parser
    assert_nil Robin::Redis.native_io(Robin::Redis::RESP, Robin::Redis)
    assert_nil Robin::Redis.native_io(Object.new, Module.new)
    reader = Module.new
    mod = Module.new.tap { |m| m.const_set(:NativeIO, reader) }

    assert_same reader, Robin::Redis.native_io(Object.new, mod)
    if Robin::Redis::PARSER.equal?(Robin::Redis::RESP)
      assert_nil Robin::Redis::NATIVE_IO
    else
      assert_same Robin::Redis::NativeIO, Robin::Redis::NATIVE_IO
    end
  end

  def test_plain_sockets_use_the_c_reader_and_tls_does_not
    conn = connect(server)
    conn.call("PING")

    if Robin::Redis::NATIVE_IO
      assert_same Robin::Redis::NATIVE_IO, conn.instance_variable_get(:@native_io)
    else
      assert_nil conn.instance_variable_get(:@native_io)
    end
    srv = server(tls: "DNS:localhost,IP:127.0.0.1", tcp: true)
    tls = @conn = Connection.new(url: "rediss://127.0.0.1:#{srv.port}", ssl_params: {cert_store: FakeRedis.tls("DNS:localhost,IP:127.0.0.1").last})
    tls.call("PING")

    assert_nil tls.instance_variable_get(:@native_io)
  end

  def test_c_reader_results_become_connection_errors
    conn = Connection.new(host: "h")
    reader = Object.new
    results = [nil, false]
    reader.define_singleton_method(:fill) { |_io, _buf, _timeout| results.shift }
    conn.instance_variable_set(:@native_io, reader)

    error = assert_raises(Robin::Redis::ConnectionError) { conn.send(:fill, 1) }
    assert_equal "connection closed by Redis server (h:6379/0)", error.message
    error = assert_raises(Robin::Redis::TimeoutError) { conn.send(:fill, 1) }
    assert_equal "timed out talking to Redis (h:6379/0)", error.message
  end

  def test_c_reads_do_their_own_waiting
    conn = Connection.new(host: "h")
    give(conn, no_wait_socket(:wait_readable))
    reader = Object.new
    reader.define_singleton_method(:fill) { |_io, buf, _timeout| (buf << "+x\r\n") && 4 }
    conn.instance_variable_set(:@native_io, reader)

    assert_equal ["x"], conn.send(:read_replies, 1, 1)
  end

  # A connection whose C extension answers roundtrip with +results+ (a
  # result, or a callable taking the buffer); connecting counts in +opened+.
  def scripted_roundtrips(results, calls = [], opened = [])
    conn = Connection.new(host: "h")
    reader = Object.new
    reader.define_singleton_method(:roundtrip) do |*args|
      calls << args
      result = results.shift
      result.respond_to?(:call) ? result.call(args[2]) : result
    end
    conn.define_singleton_method(:connect) do
      opened << (@sock = FakeSocket.new)
      @native_io = reader
    end
    conn
  end

  def reply(text) = ->(buf) { (buf << text) && text.bytesize }

  def test_a_c_reader_without_roundtrip_reads_after_ruby_writes
    conn = Connection.new(host: "h")
    give(conn, FakeSocket.new)
    reader = Object.new
    reader.define_singleton_method(:stale?) { |_io| false }
    reader.define_singleton_method(:fill) { |_io, buf, _timeout| (buf << "+x\r\n") && 4 }
    conn.instance_variable_set(:@native_io, reader)

    assert_equal "x", conn.call("PING")
  end

  def test_c_roundtrips_send_and_start_reading
    calls = []
    conn = scripted_roundtrips([reply("+x\r\n"), reply("+y\r\n")], calls)

    assert_equal "x", conn.call("PING")
    assert_equal %w[y], conn.pipelined { |p| p.call("GET", "k") }
    sock, payload, buf, write_timeout, read_timeout = calls.first

    assert_same sock(conn), sock
    assert_equal ["*1\r\n$4\r\nPING\r\n", 3.0, 3.0], [payload, write_timeout, read_timeout]
    assert_same conn.instance_variable_get(:@buf), buf
  end

  def test_c_roundtrips_reconnect_once_for_a_stale_connection
    opened = []
    conn = scripted_roundtrips([:stale, reply("+x\r\n"), :stale, :stale], [], opened)

    assert_equal "x", conn.call("PING")
    assert_equal 2, opened.size
    first = opened.first

    assert first.closed
    error = assert_raises(Robin::Redis::ConnectionError) { conn.call("PING") }
    assert_equal "connection unusable right after connecting (h:6379/0)", error.message
    assert_nil sock(conn)
  end

  def test_c_roundtrips_retry_a_write_that_sent_nothing_once
    opened = []
    conn = scripted_roundtrips([[0, Errno::EPIPE::Errno], reply("+x\r\n"), [0, Errno::ECONNRESET::Errno], [0, Errno::EPIPE::Errno]], [], opened)

    assert_equal "x", conn.call("PING")
    assert_equal 2, opened.size
    error = assert_raises(Robin::Redis::ConnectionError) { conn.call("PING") }
    assert_equal "Errno::EPIPE: Broken pipe - writing to Redis (h:6379/0)", error.message
  end

  def test_c_roundtrips_never_retry_a_partial_or_timed_out_write
    conn = scripted_roundtrips([[5, Errno::ECONNRESET::Errno], [5, nil]])
    error = assert_raises(Robin::Redis::ConnectionError) { conn.call("PING") }

    assert_equal "Errno::ECONNRESET: #{Errno::ECONNRESET.new.message} - writing to Redis after a partial write (h:6379/0)", error.message
    assert_nil sock(conn)
    error = assert_raises(Robin::Redis::TimeoutError) { conn.call("PING") }

    assert_equal "timed out talking to Redis (h:6379/0)", error.message
    assert_nil sock(conn)
  end

  def test_c_roundtrip_read_results_become_connection_errors
    calls = []
    conn = scripted_roundtrips([nil, false, ->(_buf) { raise Errno::ECONNRESET }, reply("+x\r\n")], calls)

    assert_equal "connection closed by Redis server (h:6379/0)", assert_raises(Robin::Redis::ConnectionError) { conn.call("PING") }.message
    assert_nil sock(conn)
    assert_raises(Robin::Redis::TimeoutError) { conn.call("PING") }
    error = assert_raises(Robin::Redis::ConnectionError) { conn.call("PING") }

    assert_equal "Errno::ECONNRESET: #{Errno::ECONNRESET.new.message} (h:6379/0)", error.message
    assert_equal 3, calls.size, "a failed read is never retried"
    assert_nil sock(conn)
  end

  def test_c_roundtrips_replace_a_connection_with_leftover_bytes
    opened = []
    conn = scripted_roundtrips([reply("+x\r\n+extra\r\n"), reply("+y\r\n")], [], opened)

    assert_equal "x", conn.call("PING")
    assert_equal "y", conn.call("PING")
    assert_equal 2, opened.size
  end

  def test_ruby_reads_wait_for_more
    conn = Connection.new(host: "h")
    give(conn, FakeSocket.new.tap { |f| f.define_singleton_method(:wait_readable) { |_t| nil } })

    assert_raises(Robin::Redis::TimeoutError) { conn.send(:fill, 1) }
  end

  def test_ruby_reads_notice_a_closed_connection
    conn = Connection.new(host: "h")
    give(conn, FakeSocket.new(read: nil))

    error = assert_raises(Robin::Redis::ConnectionError) { conn.send(:fill, 1) }
    assert_equal "connection closed by Redis server (h:6379/0)", error.message
  end

  def test_c_reader_gets_the_socket_buffer_and_timeout
    conn = Connection.new(host: "h")
    seen = nil
    reader = Object.new
    reader.define_singleton_method(:fill) { |*args| (seen = args) && 3 }
    give(conn, sock = Object.new)
    conn.instance_variable_set(:@native_io, reader)

    assert_nil conn.send(:fill, 2.5)
    assert_equal [sock, conn.instance_variable_get(:@buf), 2.5], seen
    assert_same conn.instance_variable_get(:@buf), seen[1]
  end

  def test_an_idle_healthy_connection_is_kept
    srv = server(tcp: true)
    conn = connect(srv)
    conn.call("PING")
    conn.call("PING")

    assert_equal 1, srv.connections
  end

  def test_a_tcp_connection_the_server_dropped_is_replaced_before_the_next_command
    srv = server(tcp: true) do |cmd, index|
      (cmd.first == "BYE") ? ->(s) { s.write("+bye\r\n") && s.close } : FakeRedis.bulk("c#{index}")
    end
    conn = connect(srv)

    assert_equal "bye", conn.call("BYE")
    sleep 0.05

    assert_match(/\Ac\d\z/, conn.call("PING"))
    assert_equal 2, srv.connections
  end

  def test_failed_writes_are_retried_once
    [Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNABORTED, IOError].each do |error|
      srv = server
      conn = connect(srv)
      old = FakeSocket.new(write: error)
      give(conn, old)

      assert_equal "OK", conn.call("PING")
      assert old.closed
      assert_equal [["PING"]], srv.received
    end
  end

  def test_failed_writes_give_up_after_one_retry
    conn = Connection.new(host: "h")
    opened = 0
    conn.define_singleton_method(:open_socket) do
      opened += 1
      FakeSocket.new(write: Errno::EPIPE)
    end

    error = assert_raises(Robin::Redis::ConnectionError) { conn.call("PING") }
    assert_equal "Errno::EPIPE: Broken pipe (h:6379/0)", error.message
    assert_equal 2, opened
  end

  # Sends a few bytes, then the connection breaks.
  class PartialSocket < FakeSocket
    def write_nonblock(data, **)
      return 3 if (@calls = @calls.to_i + 1) == 1

      raise Errno::EPIPE
    end
  end

  def test_writes_that_sent_some_bytes_are_not_retried
    conn = Connection.new(host: "h")
    opened = []
    conn.define_singleton_method(:open_socket) { PartialSocket.new.tap { |s| opened << s } }

    error = assert_raises(Robin::Redis::ConnectionError) { conn.call("INCR", "counter") }
    assert_equal "Errno::EPIPE: Broken pipe (h:6379/0)", error.message
    assert_equal 1, opened.size, "must not resend a command the server may have run"
    assert opened.first.closed
  end

  def test_read_errors_are_wrapped_and_close_the_socket
    [Errno::ECONNRESET, IOError].each do |klass|
      conn = Connection.new(host: "h")
      fake = FakeSocket.new(read: klass)
      conn.define_singleton_method(:open_socket) { fake }
      conn.define_singleton_method(:stale?) { false }

      error = assert_raises(Robin::Redis::ConnectionError) { conn.call("PING") }
      assert_equal "#{klass}: #{klass.new.message} (h:6379/0)", error.message
      assert fake.closed
      assert_nil sock(conn)
    end
  end

  def test_server_closing_mid_reply
    srv = server { :close }
    conn = connect(srv)

    error = assert_raises(Robin::Redis::ConnectionError) { conn.call("PING") }
    assert_equal "connection closed by Redis server (#{srv.path})", error.message
  end

  def test_read_timeout
    srv = server { :ignore }
    conn = connect(srv, read_timeout: 0.1)

    took = elapsed do
      error = assert_raises(Robin::Redis::TimeoutError) { Timeout.timeout(5) { conn.call("PING") } }
      assert_equal "timed out talking to Redis (#{srv.path})", error.message
    end

    assert_operator took, :>=, 0.09
    assert_nil sock(conn)
  end

  def test_slow_replies_within_the_timeout
    srv = server { ->(s) { s.write("$5\r\nhel") && sleep(0.1) && s.write("lo\r\n") } }

    assert_equal "hello", Timeout.timeout(5) { connect(srv, read_timeout: 1).call("GET") }
  end

  def test_write_timeout
    srv = server(mode: :deaf)
    conn = connect(srv, write_timeout: 0.1, read_timeout: 10)

    took = elapsed { assert_raises(Robin::Redis::TimeoutError) { Timeout.timeout(5) { conn.call("SET", "k", "x" * 8_000_000) } } }

    assert_operator took, :<, 4
    conn.send(:connect)
    conn.instance_variable_set(:@native_io, nil) # Ruby's own writes
    took = elapsed { assert_raises(Robin::Redis::TimeoutError) { Timeout.timeout(5) { conn.call("SET", "k", "x" * 8_000_000) } } }

    assert_operator took, :<, 4
  end

  def test_interrupted_reads_close_the_connection
    srv = server { |cmd, _| (cmd.first == "SLOW") ? :ignore : FakeRedis.ok }
    conn = connect(srv, read_timeout: 5)

    assert_raises(Timeout::Error) { Timeout.timeout(0.1) { conn.call("SLOW") } }
    assert_nil sock(conn)
    assert_equal "OK", conn.call("PING")
  end

  def test_empty_pipelines_do_not_connect
    srv = server

    conn = connect(srv)

    assert_empty(conn.pipelined { |_p| nil })
    assert_nil sock(conn)
  end

  def test_reply_buffer_is_released
    srv = server { |cmd, _| (cmd.first == "BIG") ? FakeRedis.bulk("x" * 300_000) : FakeRedis.ok }
    conn = connect(srv)

    assert_equal 300_000, conn.call("BIG").bytesize
    assert_equal 0, conn.instance_variable_get(:@buf).bytesize
    assert_equal 0, conn.instance_variable_get(:@pos)
    assert_equal "OK", conn.call("PING")
  end

  def test_pipelined_replies_split_across_reads
    srv = server do |cmd, _|
      next :ignore unless cmd.first == "ONE"

      lambda do |s|
        s.write("+a\r\n$5\r\nhe")
        sleep 0.05
        s.write("llo\r\n:7\r\n")
      end
    end
    conn = connect(srv)

    assert_equal ["a", "hello", 7], conn.pipelined { |p|
      p.call("ONE")
      p.call("TWO")
      p.call("THREE")
    }
    assert_equal 0, conn.instance_variable_get(:@buf).bytesize
  end

  def test_multi_waits_for_slow_replies
    srv = server do |cmd, _|
      case cmd.first
      when "MULTI" then FakeRedis.ok
      when "EXEC"
        sleep 0.05
        "*1\r\n:1\r\n"
      else "+QUEUED\r\n"
      end
    end

    assert_equal [1], connect(srv).multi { |t| t.call("INCR", "k") }
  end

  def test_handshake_network_errors_close_the_socket
    conn = Connection.new(host: "h", password: "p")
    fake = FakeSocket.new(write: Errno::ECONNRESET)
    conn.define_singleton_method(:open_socket) { fake }

    assert_raises(Robin::Redis::ConnectionError) { conn.call("PING") }
    assert fake.closed
    assert_nil sock(conn)
  end

  def test_connects_to_the_configured_host
    address = Socket.ip_address_list.find { |a| a.ipv4? && !a.ipv4_loopback? }&.ip_address
    skip "no non-loopback IPv4 address" unless address
    srv = server(tcp: true, host: address)

    assert_equal "OK", Connection.new(host: address, port: srv.port).call("PING")
  end

  def test_connect_timeout
    conn = Connection.new(host: "192.0.2.1", connect_timeout: 0.1) # TEST-NET-1: never answers

    took = elapsed { assert_raises(Robin::Redis::ConnectionError) { Timeout.timeout(3) { conn.call("PING") } } }

    assert_operator took, :<, 2
  end

  def test_tls_sends_the_server_name
    srv = server(tls: "DNS:localhost,IP:127.0.0.1", tcp: true)
    FakeRedis.last_server_name = nil
    conn = Connection.new(host: "localhost", port: srv.port, ssl: true,
      ssl_params: {cert_store: FakeRedis.tls("DNS:localhost,IP:127.0.0.1").last})

    assert_equal "OK", conn.call("PING")
    skip "this OpenSSL binding doesn't report SNI" if FakeRedis.last_server_name.nil? && RUBY_ENGINE != "ruby"

    assert_equal "localhost", FakeRedis.last_server_name
  end

  def test_successful_reads_keep_the_connection
    srv = server
    conn = connect(srv)
    3.times { conn.call("PING") }

    assert_equal 1, srv.connections
  end

  def test_pipelined_replies_in_one_chunk
    srv = server { |cmd, _| (cmd.first == "TWO") ? "+a\r\n+b\r\n" : :ignore }
    conn = connect(srv)

    assert_equal ["a", "b"], conn.pipelined { |p|
      p.call("TWO")
      p.call("SKIP")
    }
  end

  # An OpenSSL::SSL::SSLSocket stand-in: closing it says goodbye on +io+.
  class FakeTLSSocket < FakeSocket
    attr_reader :io

    def initialize(io) = @io = io
  end

  def test_abandon_closes_only_the_file_descriptor
    conn = connect(server)
    conn.call("PING")
    plain = sock(conn)

    assert_nil conn.abandon
    assert_predicate plain, :closed?
    assert_nil sock(conn)
    io = FakeSocket.new
    tls = FakeTLSSocket.new(io)
    conn.instance_variable_set(:@sock, tls)
    conn.abandon

    assert io.closed
    refute tls.closed
    conn.instance_variable_set(:@sock, FakeTLSSocket.new(FakeSocket.new(close: Errno::EBADF)))

    assert_nil conn.abandon
    conn.instance_variable_set(:@sock, FakeSocket.new(close: IOError))

    assert_nil conn.abandon
    assert_nil conn.abandon # nothing open
    assert_equal ["".b, 0], [conn.instance_variable_get(:@buf), conn.instance_variable_get(:@pos)]
  end

  # Runs the block in a forked child, which always leaves with exit!: an
  # error must not run the test framework's exit hooks in the child.
  def in_child
    Process.wait(fork do
      yield
    ensure
      exit!(0)
    end)
  end

  def test_a_forked_child_abandoning_a_tls_connection_leaves_the_parents_working
    skip "needs fork" unless Process.respond_to?(:fork)

    srv = server(tls: "DNS:localhost,IP:127.0.0.1", tcp: true)
    conn = connect(srv, ssl: true, ssl_params: {cert_store: FakeRedis.tls("DNS:localhost,IP:127.0.0.1").last})

    reply = conn.call("PING")
    in_child { conn.abandon }

    assert_equal reply, conn.call("PING")
    in_child { conn.close } # what the child used to do: a TLS goodbye on the parent's socket
    assert_raises(Robin::Redis::ConnectionError, OpenSSL::SSL::SSLError, IOError) { conn.call("PING") }
  end

  def test_close
    conn = connect(server)

    assert_nil conn.close
    conn.call("PING")

    assert_nil conn.close
    assert_nil sock(conn)
    conn.instance_variable_set(:@sock, FakeSocket.new(close: IOError))

    assert_nil conn.close
    conn.instance_variable_set(:@sock, FakeSocket.new(close: Errno::EBADF))

    assert_nil conn.close
    assert_nil sock(conn)
    assert_equal ["".b, 0], [conn.instance_variable_get(:@buf), conn.instance_variable_get(:@pos)]
    assert_equal Encoding::BINARY, conn.instance_variable_get(:@buf).encoding
    assert_equal Encoding::BINARY, Connection.new(host: "h").instance_variable_get(:@buf).encoding
  end

  def test_wait
    conn = Connection.new(host: "h")
    a, b = UNIXSocket.pair
    b.write("x")

    assert_nil conn.send(:wait, a, :wait_readable, 1)
    assert_raises(Robin::Redis::TimeoutError) { conn.send(:wait, a, :wait_readable, 0) }
    assert_raises(Robin::Redis::TimeoutError) { conn.send(:wait, a, :wait_readable, -1) }
    a.read(1)

    assert_raises(Robin::Redis::TimeoutError) { conn.send(:wait, a, :wait_readable, 0.05) }
    assert_nil conn.send(:wait, a, :wait_writable, 1)
  ensure
    a&.close
    b&.close
  end
end

class ConnectionSentinelTest < ConnectionTestCase
  include RuntimeTestHelpers

  cover "Robin::Redis::Connection.sentinel_list"
  cover "Robin::Redis::Connection#initialize"
  cover "Robin::Redis::Connection#id"
  cover "Robin::Redis::Connection#open_socket"
  cover "Robin::Redis::Connection#sentinel_master"
  cover "Robin::Redis::Connection#ask_sentinel"
  cover "Robin::Redis::Connection#handshake"
  cover "Robin::Redis::Connection#wrap_ssl"

  def array(*items) = Robin::Redis::RESP.encode(items.map(&:to_s), +"")

  # A Sentinel that knows +master+ (a FakeRedis) under the name "mymaster".
  def sentinel(master = nil, **)
    server(tcp: true, **) do |cmd, _|
      next FakeRedis.ok unless cmd.first == "SENTINEL"

      (master && cmd == %w[SENTINEL GET-MASTER-ADDR-BY-NAME mymaster]) ? array("127.0.0.1", master.port) : "*-1\r\n"
    end
  end

  def master(role = "master", **)
    server(tcp: true, **) { |cmd, _| (cmd == ["ROLE"]) ? array(role) : FakeRedis.ok }
  end

  def sentinels(conn) = conn.instance_variable_get(:@sentinels)

  def test_sentinel_list
    list = Connection.sentinel_list(["a:1", "b", {host: "c", port: "3"}, {"host" => "d"}])

    assert_equal [["a", 1], ["b", 26_379], ["c", 3], ["d", 26_379]], list
    assert_equal [["e", 2]], Connection.sentinel_list("e:2")
    assert_nil Connection.sentinel_list(nil)
    assert_raises(ArgumentError) { Connection.sentinel_list("a:x") }
    error = assert_raises(ArgumentError) { Connection.sentinel_list([]) }
    assert_equal "sentinels must not be empty", error.message
  end

  def test_master_name_comes_from_the_option_or_the_url
    conn = Connection.new(url: "redis://mymaster/2", sentinels: ["s:1"])

    assert_equal "mymaster", conn.options[:master_name]
    assert_equal "sentinel:mymaster/2", conn.id
    assert_equal [["s", 1]], sentinels(conn)
    assert_equal "other", Connection.new(url: "redis://mymaster", sentinels: ["s"], master_name: "other").options[:master_name]
    assert_equal "/p", Connection.new(path: "/p", sentinels: ["s"], master_name: "m").id
    assert_nil Connection.new(host: "h").options[:master_name]
    error = assert_raises(ArgumentError) { Connection.new(port: 1, sentinels: ["s"]) }
    assert_equal "Sentinel needs a master_name (or the URL's host)", error.message
  end

  def test_connects_to_the_master_a_sentinel_names
    redis = master
    lost = sentinel
    good = sentinel(redis)
    list = ["127.0.0.1:#{closed_port}", "127.0.0.1:#{lost.port}", "127.0.0.1:#{good.port}"]
    @conn = Connection.new(host: "mymaster", sentinels: list, sentinel_username: "su", sentinel_password: "sp", db: 1)

    assert_equal "OK", @conn.call("PING")
    assert_equal [["SELECT", "1"], ["ROLE"], ["PING"]], redis.received
    assert_equal [%w[AUTH su sp], %w[SENTINEL GET-MASTER-ADDR-BY-NAME mymaster]], good.received
    # The Sentinel that answered is asked first from now on.
    assert_equal [good.port, list.first.split(":").last.to_i, lost.port], sentinels(@conn).map(&:last)
    eventually_true { good.disconnects == 1 }
  end

  def test_refuses_a_server_that_is_not_the_master
    good = sentinel(master("slave"))
    @conn = Connection.new(host: "mymaster", sentinels: ["127.0.0.1:#{good.port}"])

    error = assert_raises(Robin::Redis::ConnectionError) { @conn.call("PING") }
    assert_equal "sentinel:mymaster/0 reached a slave, not the master", error.message
    assert_nil sock
  end

  def test_fails_when_no_sentinel_knows_the_master
    lost = sentinel
    broken = server(tcp: true) { FakeRedis.error("ERR unknown command") }
    port = closed_port
    @conn = Connection.new(host: "mymaster", sentinels: ["127.0.0.1:#{port}", "127.0.0.1:#{lost.port}", "127.0.0.1:#{broken.port}"])

    error = assert_raises(Robin::Redis::ConnectionError) { @conn.call("PING") }
    assert_match(/\Ano Sentinel could locate master mymaster \(127\.0\.0\.1:#{port} Errno::ECONNREFUSED: .+; /o, error.message)
    assert_includes error.message, "; 127.0.0.1:#{lost.port} doesn't know it; 127.0.0.1:#{broken.port} ERR unknown command)"
  end

  def test_sentinel_connections_use_the_connect_timeout_and_shared_settings
    good = sentinel(master)
    seen = []
    original = Connection.method(:new)
    stub_method(Connection, :new, ->(**kw) { original.call(**kw).tap { seen << kw } }) do
      @conn = Connection.new(host: "mymaster", sentinels: ["127.0.0.1:#{good.port}"], connect_timeout: 0.5, read_timeout: 7, write_timeout: 8, ssl_params: {a: 1})
      @conn.call("PING")
    end

    expected = {host: "127.0.0.1", port: good.port, username: nil, password: nil, ssl: false, ssl_params: {a: 1}, connect_timeout: 0.5, read_timeout: 0.5, write_timeout: 0.5}

    assert_equal [expected], seen.drop(1)
  end

  def test_silent_sentinels_time_out_after_the_connect_timeout
    silent = server(tcp: true) { :ignore }
    @conn = Connection.new(host: "mymaster", sentinels: ["127.0.0.1:#{silent.port}"], connect_timeout: 0.1, read_timeout: 5)

    took = elapsed { assert_raises(Robin::Redis::ConnectionError) { @conn.call("PING") } }

    assert_operator took, :<, 2
  end

  def test_tls_checks_the_resolved_master_host
    names = "DNS:localhost,IP:127.0.0.1"
    store = FakeRedis.tls(names).last
    redis = master(tls: names)
    good = sentinel(redis, tls: names)
    @conn = Connection.new(host: "mymaster", sentinels: ["127.0.0.1:#{good.port}"], ssl: true, ssl_params: {cert_store: store})

    assert_equal "OK", @conn.call("PING")
    assert_kind_of OpenSSL::SSL::SSLSocket, sock
  end
end
