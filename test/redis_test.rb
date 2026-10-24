# frozen_string_literal: true

require_relative "test_helper"

class RedisTest < RobinTest
  def test_basic_commands
    assert_equal "OK", redis("SET", "#{key_prefix_for_test}k", "v")
    assert_equal "v", redis("GET", "#{key_prefix_for_test}k")
    assert_nil redis("GET", "#{key_prefix_for_test}missing")
    assert_equal 3, redis("RPUSH", "#{key_prefix_for_test}l", "a", "b", "c")
    assert_equal %w[a b c], redis("LRANGE", "#{key_prefix_for_test}l", 0, -1)
  end

  def test_binary_and_unicode_round_trip
    value = "héllo ✓ \r\n\x00 bytes"
    redis("SET", "#{key_prefix_for_test}u", value)

    assert_equal value.b, redis("GET", "#{key_prefix_for_test}u").b
  end

  def test_large_values
    big = "x" * 3_000_000
    redis("SET", "#{key_prefix_for_test}big", big)

    assert_equal big.bytesize, redis("GET", "#{key_prefix_for_test}big").bytesize
    redis("RPUSH", "#{key_prefix_for_test}many", *Array.new(20_000) { |i| "item-#{i}" })

    assert_equal 20_000, redis("LRANGE", "#{key_prefix_for_test}many", 0, -1).size
  end

  def test_errors_raise
    redis("SET", "#{key_prefix_for_test}s", "x")
    assert_raises(Robin::Redis::CommandError) { redis("LPUSH", "#{key_prefix_for_test}s", "y") }
    # connection is still usable afterwards
    assert_equal "x", redis("GET", "#{key_prefix_for_test}s")
  end

  def test_pipelined_and_multi
    results = Robin.redis { |c|
      c.pipelined { |p|
        p.call("INCR", "#{key_prefix_for_test}n")
        p.call("INCR", "#{key_prefix_for_test}n")
      }
    }

    assert_equal [1, 2], results
    results = Robin.redis { |c|
      c.multi { |t|
        t.call("INCR", "#{key_prefix_for_test}n")
        t.call("GET", "#{key_prefix_for_test}n")
      }
    }

    assert_equal [3, "3"], results
  end

  def test_evalsha_loads_scripts
    # A script the server doesn't have (new source; flushing would fail
    # other tests' pipelines meanwhile).
    script = Robin::Redis::Script.new("return ARGV[1] .. KEYS[1] -- #{rand(1 << 40)}")

    assert_equal "ab", Robin.redis { |c| c.evalsha(script, ["b"], ["a"]) }
  end

  def test_reconnects_after_server_side_kill
    id = Robin.redis do |c|
      c.call("SET", "#{key_prefix_for_test}x", "1")
      c.call("CLIENT", "ID")
    end
    # Only this test's connection: other test processes share the server.
    other = Robin::Redis::Connection.new(url: REDIS_URL)

    assert_equal 1, other.call("CLIENT", "KILL", "ID", id)
    other.close

    assert_equal "1", Robin.redis { |c| c.call("GET", "#{key_prefix_for_test}x") }
  end

  def test_url_parsing
    opts = Robin::Redis::Connection.parse_url("rediss://user:p%40ss@example.com:6380/3")

    assert_equal({host: "example.com", port: 6380, ssl: true, db: 3, username: "user", password: "p@ss"}, opts)
    assert_equal({path: "/tmp/redis.sock", db: 2}, Robin::Redis::Connection.parse_url("unix:///tmp/redis.sock?db=2"))
  end

  def test_pool_is_reentrant_and_thread_safe
    pool = Robin::Redis::Pool.new(size: 3) { Robin::Redis::Connection.new(url: REDIS_URL) }
    pool.with { |a| pool.with { |b| assert_same a, b } }
    threads = 10.times.map { Thread.new { 50.times { pool.call("INCR", "#{key_prefix_for_test}ctr") } } }
    threads.each(&:join)

    assert_equal "500", redis("GET", "#{key_prefix_for_test}ctr")
  ensure
    pool&.shutdown
  end
end
