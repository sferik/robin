# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

# Deterministic limiter tests: the clock, sleep and rand are stubbed, so
# every Lua decision is checked against exact numbers.
class LimiterUnitTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Limiter*"

  NOW = 1_800_000_000_000

  def setup
    @frozen = Robin.method(:now_ms)
    super
  end

  def teardown
    Robin.define_singleton_method(:now_ms, @frozen)
    super
  end

  def at(limiter, ms)
    limiter.define_singleton_method(:now_ms) { ms }
    limiter
  end

  # Makes waiting deterministic: monotonic time only moves when sleep is
  # called, rand is 1, and sleeps are recorded.
  def fake_time(limiter)
    clock = [100.0]
    sleeps = []
    limiter.define_singleton_method(:monotonic) { clock[0] }
    limiter.define_singleton_method(:sleep) do |s|
      sleeps << s
      clock[0] += s
    end
    limiter.define_singleton_method(:rand) { 0.5 }
    sleeps
  end

  def key(*parts) = config.key(*parts)

  def meta(name) = redis("HGETALL", key("lmtr", name)).each_slice(2).to_h

  # -- module helpers -----------------------------------------------------

  def test_seconds
    assert_equal 1, Robin::Limiter.seconds(:second)
    assert_equal 60, Robin::Limiter.seconds("minute")
    assert_equal 3_600, Robin::Limiter.seconds(:hour)
    assert_equal 86_400, Robin::Limiter.seconds(:day)
    assert_nil Robin::Limiter.seconds(nil)
    assert_in_delta 2.5, Robin::Limiter.seconds(2.5)
    assert_instance_of Float, Robin::Limiter.seconds(3)
    e = assert_raises(ArgumentError) { Robin::Limiter.seconds(:fortnight) }
    assert_equal "unknown interval :fortnight", e.message
    assert_raises(ArgumentError) { Robin::Limiter.seconds("2") }
    assert_raises(TypeError) { Robin::Limiter.seconds([]) }
  end

  def test_constructors
    c = Robin::Limiter.concurrent(:api, "3", wait_timeout: 1, lock_timeout: "2.5", config: other_config)

    assert_instance_of Robin::Limiter::Concurrent, c
    assert_equal ["api", 3, nil, 1.0, 2.5, "concurrent"], [c.name, c.limit, c.interval, c.wait_timeout, c.lock_timeout, c.type]
    assert_same other_config, c.config
    assert_equal [5.0, 30.0], [Robin::Limiter.concurrent("d", 1).wait_timeout, Robin::Limiter.concurrent("d", 1).lock_timeout]
    {bucket: Robin::Limiter::Bucket, window: Robin::Limiter::Window, leaky: Robin::Limiter::Leaky,
     points: Robin::Limiter::Points}.each do |kind, klass|
      l = Robin::Limiter.public_send(kind, "n", 4, :minute, wait_timeout: 2, config: other_config)

      assert_instance_of klass, l
      assert_equal ["n", 4, 60.0, 2.0, kind.to_s], [l.name, l.limit, l.interval, l.wait_timeout, l.type]
      assert_same other_config, l.config
      assert_in_delta 5.0, Robin::Limiter.public_send(kind, "n", 4, :minute).wait_timeout
      e = assert_raises(ArgumentError) { Robin::Limiter.public_send(kind, "n", 4, nil) }
      assert_equal "#{kind} limiters need an interval", e.message
    end
  end

  def test_validation
    e = assert_raises(ArgumentError) { Robin::Limiter.concurrent("", 1) }
    assert_equal "limiter name can't be blank", e.message
    assert_raises(ArgumentError) { Robin::Limiter.concurrent(nil, 1) }
    [0, -1].each do |bad|
      e = assert_raises(ArgumentError) { Robin::Limiter.concurrent("x", bad) }
      assert_equal "limit must be positive", e.message
    end
    assert_raises(ArgumentError) { Robin::Limiter.concurrent("x", "many") }
    assert_raises(ArgumentError) { Robin::Limiter.concurrent("x", 1, wait_timeout: "soon") }
  end

  def test_default_config
    assert_same Robin.config, Robin::Limiter.concurrent("x", 1).config
  end

  def test_reschedule_and_backoff_options
    backoff = ->(*) { 1 }
    c = Robin::Limiter.concurrent("x", 1, reschedule: "3", backoff: backoff)

    assert_equal [3, backoff], [c.reschedule, c.backoff]
    assert_equal [nil, nil], [Robin::Limiter.concurrent("x", 1).reschedule, Robin::Limiter.concurrent("x", 1).backoff]
    %i[bucket window leaky points].each do |kind|
      l = Robin::Limiter.public_send(kind, "n", 4, :minute, reschedule: 0, backoff: backoff)

      assert_equal [0, backoff], [l.reschedule, l.backoff]
    end
    e = assert_raises(ArgumentError) { Robin::Limiter.concurrent("x", 1, reschedule: -1) }
    assert_equal "reschedule can't be negative", e.message
    assert_raises(ArgumentError) { Robin::Limiter.concurrent("x", 1, reschedule: "often") }
    e = assert_raises(ArgumentError) { Robin::Limiter.bucket("x", 1, :hour, backoff: 5) }
    assert_equal "backoff must respond to #call", e.message
  end

  def test_policy_option
    assert_equal :raise, Robin::Limiter.concurrent("x", 1).policy
    assert_equal :skip, Robin::Limiter.concurrent("x", 1, policy: :skip).policy
    %i[bucket window leaky points].each do |kind|
      assert_equal :skip, Robin::Limiter.public_send(kind, "n", 4, :minute, policy: :skip).policy
    end
    e = assert_raises(ArgumentError) { Robin::Limiter.window("x", 1, :hour, policy: "skip") }
    assert_equal 'policy must be :raise or :skip, not "skip"', e.message
  end

  def test_skip_policy_returns_nil_without_running_the_block
    l = Robin::Limiter.bucket("b", 1, 10, wait_timeout: 2, policy: :skip, config: config)
    sleeps = fake_time(at(l, NOW + 1_000))
    released = []
    l.define_singleton_method(:release) { |token| released << token }

    assert_equal :ran, l.within_limit { :ran }
    assert_nil l.within_limit { flunk }
    assert_empty sleeps
    assert_equal [true], released
    assert_equal "1", meta("b")["over"]
  end

  def test_skip_policy_still_waits_for_capacity
    l = Robin::Limiter.concurrent("c", 1, wait_timeout: 1, policy: :skip, config: config)
    sleeps = fake_time(l)
    calls = 0
    l.define_singleton_method(:acquire) do |**|
      calls += 1
      (calls == 3) ? ["token", nil] : [nil, nil]
    end

    assert_equal :ok, l.within_limit { :ok }
    assert_equal 2, sleeps.size
  end

  def test_unlimited
    l = Robin::Limiter.unlimited
    named = Robin::Limiter.unlimited(:stripe)

    assert_equal ["unlimited", "stripe", "unlimited"], [l.name, named.name, l.type]
    assert_equal [:ran, l], l.within_limit { |limiter| [:ran, limiter] }
    assert_equal :ran, l.within_limit(points: 1_000_000) { :ran }
    assert_equal 0, l.used
    assert_equal [Float::INFINITY, Float::INFINITY], [l.adjust(5), l.refund(5)]
    assert_equal({"name" => "unlimited", "type" => "unlimited", "limit" => nil, "interval" => nil, "used" => 0}, l.to_h)
    assert_empty redis("KEYS", "#{config.key_prefix}*")
  end

  def other_config
    @other_config ||= Robin::Config.new.tap do |c|
      c.redis = {url: REDIS_URL}
      c.key_prefix = "#{key_prefix_for_test}other:"
    end
  end

  def test_reset_and_delete_with_an_explicit_config
    l = at(Robin::Limiter.bucket("x", 1, :minute, wait_timeout: 0, config: other_config), Robin.now_ms)
    l.within_limit {}
    Robin::Limiter.reset!("x", config: other_config)

    assert_equal 0, l.used
    l.within_limit {}
    Robin::Limiter.delete!("x", config: other_config)

    assert_equal 0, l.used
    assert_empty Robin::Limiter.list(config: other_config)
  ensure
    other_config.redis_pool.shutdown
  end

  def test_explicit_config_is_used
    l = Robin::Limiter.window("w", 1, 60, config: other_config)
    l.within_limit {}

    assert_same other_config, l.config
    assert_equal 1, Robin::Limiter.list(config: other_config).first["used"]
    assert_empty Robin::Limiter.list(config: config)
  ensure
    other_config.redis_pool.shutdown
  end

  def test_class_defaults
    c = Robin::Limiter::Concurrent.new("c", 1, config: other_config)

    assert_equal [5.0, 30.0, 30_000], [c.wait_timeout, c.lock_timeout, c.lock_timeout_ms]
    assert_same other_config, c.config
    assert_nil c.interval_ms
    assert_same Robin.config, Robin::Limiter::Concurrent.new("c", 1).config
    b = Robin::Limiter::Bucket.new("b", 1, 1.5)

    assert_in_delta 5.0, b.wait_timeout
    assert_same Robin.config, b.config
    assert_equal 1_500, b.interval_ms
    assert_instance_of Integer, b.interval_ms
    assert_instance_of Integer, Robin::Limiter.concurrent("c", 1, lock_timeout: 0.25).lock_timeout_ms
    assert_equal 250, Robin::Limiter.concurrent("c", 1, lock_timeout: 0.25).lock_timeout_ms
  end

  def test_to_h
    l = at(Robin::Limiter.bucket("b", 2, :minute, config: config), NOW)

    assert_equal({"name" => "b", "type" => "bucket", "limit" => 2, "interval" => 60.0, "used" => 0}, l.to_h)
  end

  def test_over_limit_error
    l = Robin::Limiter.concurrent("x", 1, config: config)
    e = Robin::Limiter::OverLimit.new(l, 1.5)

    assert_same l, e.limiter
    assert_in_delta 1.5, e.retry_after
    assert_equal 'rate limiter "x" (concurrent) is over its limit', e.message
    assert_kind_of Robin::Error, e
    assert_nil Robin::Limiter::OverLimit.new(l).retry_after
  end

  # -- registration and waiting -----------------------------------------------

  def test_registration_is_refreshed_every_ten_minutes
    l = at(Robin::Limiter.window("w", 5, 30, config: config), NOW)
    clock = [1_000.0]
    l.define_singleton_method(:monotonic) { clock[0] }
    l.within_limit {}

    assert_equal({"type" => "window", "limit" => "5", "interval" => "30.0", "last" => NOW.to_s}, meta("w"))
    assert_in_delta Robin::Limiter::META_TTL, redis("TTL", key("lmtr", "w")), 2
    assert_equal ["w"], redis("SMEMBERS", key("limiters"))
    redis("DEL", key("lmtr", "w"))
    redis("DEL", key("limiters"))
    clock[0] = 1_599.0
    l.within_limit {}

    assert_equal({"last" => NOW.to_s}, meta("w")) # not re-registered yet
    clock[0] = 1_600.0
    l.within_limit {}

    assert_equal "window", meta("w")["type"]
    assert_equal ["w"], redis("SMEMBERS", key("limiters"))
  end

  def test_concurrent_registers_without_interval
    Robin::Limiter.concurrent("c", 1, config: config).within_limit {}

    assert_equal "", meta("c")["interval"]
  end

  # The pipelines (registrations) sent through +pool+, as command names.
  def registrations(pool)
    pool.calls.chunk_while { |_, b| b[0] == :pipe }.select { |c| c[0] == [:pipelined] }.map { |c| c.drop(1).map { |x| x[1] } }
  end

  def test_limiters_with_the_same_definition_register_once
    recording_pool do |pool|
      Robin::Limiter.window("w", 5, 30, config: config).within_limit {}

      assert_equal [%w[HSET EXPIRE SADD]], registrations(pool)
      Robin::Limiter.window("w", 5, 30, config: config).within_limit {}
      Robin::Limiter.window(:w, 5, 30.0, config: config).within_limit {}

      assert_equal [%w[HSET EXPIRE SADD]], registrations(pool)
    end
  end

  def test_a_redefined_limiter_registers_again
    five = Robin::Limiter.window("w", 5, 30, config: config)
    six = Robin::Limiter.window("w", 6, 30, config: config)
    five.within_limit {}
    six.within_limit {}

    assert_equal "6", meta("w")["limit"]
    five.within_limit {}

    assert_equal "5", meta("w")["limit"]
    Robin::Limiter.window("w", 5, 60, config: config).within_limit {}

    assert_equal "60.0", meta("w")["interval"]
    Robin::Limiter.bucket("w", 5, 60, config: config).within_limit {}

    assert_equal "bucket", meta("w")["type"]
  end

  def test_registration_is_per_redis_and_key
    Robin::Limiter.concurrent("c", 1, config: config).within_limit {}
    with_shard do |other|
      Robin::Limiter.via(other) { Robin::Limiter.concurrent("c", 1, config: config).within_limit {} }

      assert_equal "concurrent", other.with { |c| c.call("HGET", key("lmtr", "c"), "type") }
    end
    other_config = Robin::Config.new
    other_config.redis = {url: REDIS_URL}
    other_config.key_prefix = "#{key_prefix_for_test}other:"
    other_config.redis_pool = config.redis_pool
    Robin::Limiter.concurrent("c", 1, config: other_config).within_limit {}

    assert_equal "concurrent", redis("HGET", other_config.key("lmtr", "c"), "type")
    config.redis = {url: REDIS_URL}
    redis("DEL", key("lmtr", "c"))
    Robin::Limiter.concurrent("c", 1, config: config).within_limit {}

    assert_equal "concurrent", meta("c")["type"] # a new pool registers again
  end

  def test_delete_forgets_the_registration
    l = Robin::Limiter.concurrent("c", 1, config: config)
    l.within_limit {}
    Robin::Limiter.delete!("c", config: config)
    l.within_limit {}

    assert_equal "concurrent", meta("c")["type"]
    assert_equal ["c"], redis("SMEMBERS", key("limiters"))
  end

  def test_within_limit_yields_and_returns
    l = Robin::Limiter.concurrent("c", 1, config: config)
    seen = nil

    assert_equal :done, l.within_limit { |x|
      seen = x
      :done
    }
    assert_same l, seen
  end

  def test_waits_for_announced_capacity_then_runs
    l = at(Robin::Limiter.bucket("b", 1, 1, wait_timeout: 2, config: config), NOW + 400)
    sleeps = fake_time(l)
    l.within_limit {}
    calls = 0
    l.define_singleton_method(:acquire) do |**|
      calls += 1
      (calls == 1) ? [nil, 600] : [true, nil]
    end

    assert_equal :ok, l.within_limit { :ok }
    assert_equal [0.6025], sleeps.map { |s| s.round(4) }
  end

  def test_announced_wait_beyond_the_deadline_raises
    l = at(Robin::Limiter.bucket("b", 1, 10, wait_timeout: 2, config: config), NOW + 1_000)
    sleeps = fake_time(l)
    l.within_limit {}
    e = assert_raises(Robin::Limiter::OverLimit) { l.within_limit { flunk } }

    assert_in_delta 9.0, e.retry_after, 0.5
    assert_empty sleeps
    assert_equal "1", meta("b")["over"]
  end

  def test_announced_wait_exactly_at_the_deadline_still_waits
    l = Robin::Limiter.bucket("b", 1, 1, wait_timeout: 2, config: config)
    fake_time(l)
    calls = 0
    l.define_singleton_method(:acquire) do |**|
      calls += 1
      (calls == 1) ? [nil, 2_000] : [true, nil]
    end

    assert_equal :ok, l.within_limit { :ok }
  end

  def test_polls_with_capped_backoff
    l = Robin::Limiter.concurrent("c", 1, wait_timeout: 1, config: config)
    sleeps = fake_time(l)
    redis("ZADD", config.key("lmtr", "c", "s"), Robin.now_ms + 60_000, "holder")
    e = assert_raises(Robin::Limiter::OverLimit) { assert_roundtrips(9) { l.within_limit {} } }

    assert_nil e.retry_after
    assert_equal [0.0125, 0.0225, 0.0425, 0.0825, 0.1625, 0.2525, 0.2525], sleeps.map { |s| s.round(4) }
    assert_equal "1", meta("c")["over"], "counted once, by the last try"
  end

  # Registering the limiter, then a try that gives up and counts it over.
  def test_giving_up_counts_the_limiter_over_in_the_same_round_trip
    l = at(Robin::Limiter.bucket("b", 1, 10, wait_timeout: 2, config: config), NOW + 1_000)
    l.within_limit {}

    assert_raises(Robin::Limiter::OverLimit) { assert_roundtrips(1) { l.within_limit { flunk } } }
    assert_equal "1", meta("b")["over"]
  end

  # The acquiring scripts count a wait longer than the caller's budget.
  def test_the_acquiring_scripts_count_only_waits_past_the_budget
    script = Robin::Limiter.acquiring("return tonumber(ARGV[1])")
    meta_key = config.key("lmtr", "s")
    run = ->(result, guess, left) { config.redis { |c| c.evalsha(script, ["state", meta_key], [result, guess, left]) } }

    assert_equal 0, run.call(0, 10, -1), "took capacity"
    assert_equal 500, run.call(500, 10, 500), "a wait the caller will sit out"
    assert_nil meta("s")["over"]
    assert_equal 501, run.call(501, 10, 500)
    assert_equal "1", meta("s")["over"]
    falsy = Robin::Limiter.acquiring("return false")
    config.redis { |c| c.evalsha(falsy, ["state", meta_key], [20, 20]) }

    assert_equal "1", meta("s")["over"], "the backoff the caller will sit out"
    config.redis { |c| c.evalsha(falsy, ["state", meta_key], [21, 20]) }

    assert_equal "2", meta("s")["over"]
    assert_equal "token", config.redis { |c| c.evalsha(Robin::Limiter.acquiring("return 'token'"), ["state", meta_key], [0, -1]) }
    assert_equal "2", meta("s")["over"]
  end

  def test_zero_wait_timeout_fails_fast
    l = Robin::Limiter.concurrent("c", 1, wait_timeout: 0, config: config)
    sleeps = fake_time(l)
    l.define_singleton_method(:acquire) { |**| [nil, nil] }

    assert_raises(Robin::Limiter::OverLimit) { l.within_limit {} }
    assert_empty sleeps
  end

  def test_real_monotonic_clock
    l = Robin::Limiter.concurrent("c", 1, config: config)

    assert_in_delta Process.clock_gettime(Process::CLOCK_MONOTONIC), l.send(:monotonic), 1
  end

  def test_over_limit_counts
    l = Robin::Limiter.concurrent("c", 1, config: config)

    assert_equal 1, l.over_limit!
    assert_equal 2, l.over_limit!
    assert_equal "2", meta("c")["over"]
  end

  def test_an_announced_wait_a_millisecond_past_the_deadline_raises_at_once
    l = Robin::Limiter.bucket("b", 1, 1, wait_timeout: 2, config: config)
    sleeps = fake_time(l)
    l.define_singleton_method(:acquire) { |**| [nil, 2_001] }

    assert_raises(Robin::Limiter::OverLimit) { l.within_limit { flunk } }
    assert_empty sleeps
  end

  # Each try that fails and waits doesn't count; the last one, that gives
  # up, does.
  def test_only_the_try_that_gives_up_counts_the_limiter_over
    %i[bucket window leaky points].each do |kind|
      l = at(Robin::Limiter.public_send(kind, "k-#{kind}", 1, 1, wait_timeout: 3, config: config), NOW + 400)
      l.within_limit {}
      sleeps = fake_time(l)

      assert_raises(Robin::Limiter::OverLimit) { l.within_limit { flunk } }
      assert_operator sleeps.size, :>, 1, kind
      assert_equal "1", meta("k-#{kind}")["over"], kind
    end
  end

  def test_over_limit_counter_ignores_redis_errors
    l = Robin::Limiter.concurrent("c", 1, config: config)
    broken = Object.new
    def broken.redis = raise(Robin::Redis::ConnectionError, "down")
    l.define_singleton_method(:config) { broken }

    assert_nil l.over_limit!
  end

  def test_acquire_options_are_passed_through
    l = Robin::Limiter.points("p", 10, 10, config: config)
    seen = nil
    l.define_singleton_method(:acquire) do |**opts|
      seen = opts
      [true, nil]
    end
    l.within_limit(points: 3) {}

    assert_equal({points: 3}, seen.except(:wait))
    assert_in_delta 10.0, seen.fetch(:wait).first, 0.001, "the first backoff"
  end

  # -- concurrent --------------------------------------------------------------

  def test_concurrent_leases
    l = at(Robin::Limiter.concurrent("c", 2, lock_timeout: 10, wait_timeout: 0, config: config), NOW)
    held = []
    l.within_limit do
      held << redis("ZRANGE", key("lmtr", "c", "s"), 0, -1, "WITHSCORES")

      assert_equal 1, l.used
      l.within_limit do
        assert_equal 2, l.used
        assert_raises(Robin::Limiter::OverLimit) { l.within_limit {} }
      end
      assert_equal 1, l.used
    end

    assert_equal 0, l.used
    token, expiry = held.first

    assert_match(/\A\h{24}\z/, token)
    assert_equal (NOW + 10_000).to_s, expiry
    assert_equal NOW.to_s, meta("c")["last"]
  end

  def test_concurrent_lease_expiry
    l = at(Robin::Limiter.concurrent("c", 1, lock_timeout: 10, wait_timeout: 0, config: config), NOW)
    redis("ZADD", key("lmtr", "c", "s"), NOW + 1, "crashed")

    assert_equal 1, l.used
    assert_raises(Robin::Limiter::OverLimit) { l.within_limit {} }
    at(l, NOW + 1)

    assert_equal 0, l.used # a lease is over at its expiry
    assert_equal :ok, l.within_limit {
      pttl = redis("PTTL", key("lmtr", "c", "s"))

      assert_includes 1..70_000, pttl
      :ok
    }
  end

  def test_concurrent_releases_on_error
    l = Robin::Limiter.concurrent("c", 1, wait_timeout: 0, config: config)

    assert_raises(RuntimeError) { l.within_limit { raise "boom" } }
    assert_equal 0, l.used
  end

  def test_concurrent_reset_state
    l = at(Robin::Limiter.concurrent("c", 1, config: config), NOW)
    l.within_limit { l.reset_state }

    assert_equal 0, redis("EXISTS", key("lmtr", "c", "s"))
  end

  # -- bucket ------------------------------------------------------------------

  def test_bucket
    l = at(Robin::Limiter.bucket("b", 2, 10, wait_timeout: 0, config: config), NOW + 2_500)
    bucket = key("lmtr", "b", "b", (NOW + 2_500) / 10_000)
    l.within_limit {}

    assert_equal 1, l.used
    assert_includes 1..7_500, redis("PTTL", bucket)
    l.within_limit {}
    e = assert_raises(Robin::Limiter::OverLimit) { l.within_limit {} }

    assert_includes 0.001..7.5, e.retry_after
    assert_equal "2", redis("GET", bucket)
    assert_equal 2, l.used
    assert_equal (NOW + 2_500).to_s, meta("b")["last"]
    at(l, NOW + 10_000)

    assert_equal 0, l.used
    l.within_limit {}

    assert_equal 1, l.used
  end

  def test_bucket_minimum_wait
    l = at(Robin::Limiter.bucket("b", 1, 1, wait_timeout: 0, config: config), NOW)
    redis("SET", key("lmtr", "b", "b", NOW / 1000), "1") # full, and (oddly) without a TTL
    e = assert_raises(Robin::Limiter::OverLimit) { l.within_limit {} }

    assert_in_delta 0.001, e.retry_after
  end

  def test_bucket_reset_state
    l = at(Robin::Limiter.bucket("b", 1, :minute, wait_timeout: 0, config: config), NOW)
    l.within_limit {}
    l.reset_state

    assert_equal 0, l.used
    l.within_limit {}
  end

  # -- window ------------------------------------------------------------------

  def test_window
    l = at(Robin::Limiter.window("w", 2, 10, wait_timeout: 0, config: config), NOW)
    l.within_limit {}
    at(l, NOW + 4_000).within_limit {}

    assert_equal 2, l.used
    assert_includes 1..11_000, redis("PTTL", key("lmtr", "w", "s"))
    e = assert_raises(Robin::Limiter::OverLimit) { at(l, NOW + 6_000).within_limit {} }

    assert_in_delta 4.0, e.retry_after
    at(l, NOW + 10_000)

    assert_equal 1, l.used # the first entry left the window
    l.within_limit {}

    assert_equal 2, l.used
    assert_equal (NOW + 10_000).to_s, meta("w")["last"]
  end

  def test_window_counts_entries_at_the_window_edge
    l = at(Robin::Limiter.window("w", 1, 10, wait_timeout: 0, config: config), NOW)
    l.within_limit {}
    at(l, NOW + 9_999)

    assert_equal 1, l.used
    assert_raises(Robin::Limiter::OverLimit) { l.within_limit {} }
  end

  # -- used: ------------------------------------------------------------------

  def test_bucket_counts_several_uses
    l = at(Robin::Limiter.bucket("b", 5, 10, wait_timeout: 0, config: config), NOW + 2_500)
    bucket = key("lmtr", "b", "b", (NOW + 2_500) / 10_000)
    l.within_limit(used: 3) {}

    assert_equal 3, l.used
    assert_includes 1..7_500, redis("PTTL", bucket)
    e = assert_raises(Robin::Limiter::OverLimit) { l.within_limit(used: 3) {} }

    assert_includes 0.001..7.5, e.retry_after
    assert_equal 3, l.used # the refused uses were given back
    l.within_limit(used: 2) {}

    assert_equal 5, l.used
    assert_includes 1..7_500, redis("PTTL", bucket)
  end

  def test_window_counts_several_uses
    l = at(Robin::Limiter.window("w", 4, 10, wait_timeout: 0, config: config), NOW)
    l.within_limit(used: 2) {}
    at(l, NOW + 3_000).within_limit {}

    assert_equal 3, l.used
    assert_equal 3, redis("ZCARD", key("lmtr", "w", "s"))
    # 3 used, 3 more need 2 of them to leave: the second leaves at +10s
    e = assert_raises(Robin::Limiter::OverLimit) { at(l, NOW + 5_000).within_limit(used: 3) {} }

    assert_in_delta 5.0, e.retry_after
    e = assert_raises(Robin::Limiter::OverLimit) { at(l, NOW + 5_000).within_limit(used: 4) {} }

    assert_in_delta 8.0, e.retry_after
    at(l, NOW + 10_000).within_limit(used: 3) {}

    assert_equal 4, l.used
  end

  def test_uses_must_fit_the_limit
    [Robin::Limiter.bucket("b", 3, 10, config: config), Robin::Limiter.window("w", 3, 10, config: config)].each do |l|
      [0, 4, -1, 1.5, "2", nil].each do |bad|
        e = assert_raises(ArgumentError) { l.within_limit(used: bad) { flunk } }
        assert_equal "used (#{bad.inspect}) must be a whole number from 1 to the limit (3)", e.message
      end
      assert_equal :ran, l.within_limit(used: 3) { :ran }
    end
  end

  # -- via ---------------------------------------------------------------------

  def test_via_sends_limiter_calls_to_another_redis
    with_shard do |other|
      l = Robin::Limiter.bucket("v", 1, 60, wait_timeout: 0, config: config)
      bucket = key("lmtr", "v", "b", Robin.now_ms / 60_000)

      assert_nil Robin::Limiter.current_pool
      Robin::Limiter.via(other) do
        assert_same other, Robin::Limiter.current_pool
        l.within_limit {}

        assert_equal 1, l.used
      end

      assert_nil Robin::Limiter.current_pool
      assert_equal "1", other.with { |c| c.call("GET", bucket) }
      assert_nil redis("GET", bucket)
      assert_equal 0, l.used
      assert_raises(RuntimeError) { Robin::Limiter.via(other) { raise "boom" } }
      assert_nil Robin::Limiter.current_pool
      outer = Object.new
      Robin::Limiter.via(outer) do
        Robin::Limiter.via(other) { assert_same other, Robin::Limiter.current_pool }

        assert_same outer, Robin::Limiter.current_pool
      end
    end
  end

  # -- leaky -------------------------------------------------------------------

  def test_leaky
    l = at(Robin::Limiter.leaky("l", 2, 10, wait_timeout: 0, config: config), NOW)
    2.times { l.within_limit {} }

    assert_equal 2, l.used
    assert_equal({"level" => "2", "at" => NOW.to_s}, redis("HGETALL", key("lmtr", "l", "s")).each_slice(2).to_h)
    assert_includes 1..11_000, redis("PTTL", key("lmtr", "l", "s"))
    e = assert_raises(Robin::Limiter::OverLimit) { at(l, NOW + 1_000).within_limit {} }

    assert_in_delta 4.0, e.retry_after # level 1.8 needs to fall to 1.0
    at(l, NOW + 5_000)

    assert_equal 1, l.used
    l.within_limit {}

    assert_equal 2, l.used
    at(l, NOW + 100_000)

    assert_equal 0, l.used
    assert_equal (NOW + 5_000).to_s, meta("l")["last"]
  end

  def test_leaky_used_rounds_fractional_levels_up
    l = at(Robin::Limiter.leaky("l", 4, 10, config: config), NOW)
    redis("HSET", key("lmtr", "l", "s"), "level", "1.5", "at", NOW)

    assert_equal 2, l.used
    redis("HSET", key("lmtr", "l", "s"), "level", "3", "at", NOW - 1_250) # drained 0.5

    assert_equal 3, l.used
  end

  def test_leaky_used_without_state
    assert_equal 0, Robin::Limiter.leaky("l", 2, 10, config: config).used
  end

  # -- points ------------------------------------------------------------------

  def test_points
    l = at(Robin::Limiter.points("p", 10, 10, wait_timeout: 0, config: config), NOW)
    l.within_limit(points: 7) {}

    assert_equal 7, l.used
    assert_includes 1..20_000, redis("PTTL", key("lmtr", "p", "s"))
    e = assert_raises(Robin::Limiter::OverLimit) { l.within_limit(points: 5) {} }

    assert_in_delta 2.0, e.retry_after
    at(l, NOW + 2_000)

    assert_equal 5, l.used
    l.within_limit(points: 5) {}

    assert_equal 10, l.used
    l.within_limit(points: 0) {}
    assert_raises(Robin::Limiter::OverLimit) { l.within_limit {} } # one point by default
    at(l, NOW + 3_000) # one point refilled
    l.within_limit {}

    assert_equal 10, l.used
  end

  def test_points_capacity_check
    l = Robin::Limiter.points("p", 10, 10, config: config)
    e = assert_raises(ArgumentError) { l.within_limit(points: 11) {} }

    assert_equal "points (11) exceed the limiter's capacity (10)", e.message
    assert_equal :ok, l.within_limit(points: 10) { :ok }
  end

  def test_points_adjust_and_refund
    l = at(Robin::Limiter.points("p", 10, 10, wait_timeout: 0, config: config), NOW)

    assert_instance_of Float, l.adjust(0)
    assert_in_delta 6.0, l.adjust(4)
    assert_equal 4, l.used
    assert_in_delta 9.0, l.refund(3)
    assert_in_delta 10.0, l.refund(5) # capped
    at(l, NOW + 1_000)

    assert_in_delta 7.0, l.adjust(3)
    assert_includes 1..20_000, redis("PTTL", key("lmtr", "p", "s"))
    assert_equal 3, l.used
  end

  def test_points_used_refills_to_capacity
    l = at(Robin::Limiter.points("p", 10, 10, config: config), NOW)
    redis("HSET", key("lmtr", "p", "s"), "tokens", "9.5", "at", NOW - 5_000)

    assert_equal 0, l.used
    redis("HSET", key("lmtr", "p", "s"), "tokens", "2.5", "at", NOW - 1_500)

    assert_equal 6, l.used # 2.5 + 1.5 available
  end

  def test_points_used_is_clamped
    l = at(Robin::Limiter.points("p", 10, 10, config: config), NOW)

    assert_equal 0, l.used
    redis("HSET", key("lmtr", "p", "s"), "tokens", "-5", "at", NOW)

    assert_equal 10, l.used
    redis("HSET", key("lmtr", "p", "s"), "tokens", "2.5", "at", NOW - 1_000)

    assert_equal 7, l.used # 2.5 + 1 refilled = 3.5 available
  end

  # -- list / reset / delete ---------------------------------------------------

  def test_list
    a = at(Robin::Limiter.bucket("listed", 1, :minute, wait_timeout: 0, config: config), NOW)
    a.within_limit {}
    assert_raises(Robin::Limiter::OverLimit) { a.within_limit {} }
    Robin::Limiter.concurrent("other", 2, config: config).within_limit {}
    redis("SADD", key("limiters"), "expired")
    redis("SADD", key("limiters"), "mystery")
    redis("HSET", key("lmtr", "mystery"), "type", "quantum", "limit", "3", "interval", "")
    rows = assert_roundtrips(2) { Robin::Limiter.list(config: config) }

    assert_equal %w[listed mystery other], rows.map { |r| r["name"] }
    assert_equal({"name" => "listed", "type" => "bucket", "limit" => 1, "interval" => 60.0, "used" => 0,
                  "over_limit_count" => 1, "last_used_at" => NOW}, rows[0])
    assert_equal({"name" => "mystery", "type" => "quantum", "limit" => 3, "interval" => nil, "used" => 0,
                  "over_limit_count" => 0, "last_used_at" => nil}, rows[1])
    assert_nil rows[2]["interval"]
    refute_includes redis("SMEMBERS", key("limiters")), "expired"
    assert_includes redis("SMEMBERS", key("limiters")), "mystery"
  end

  def test_list_reports_current_usage
    Robin::Limiter.window("busy", 5, 60, config: config).within_limit {}

    assert_equal 1, Robin::Limiter.list(config: config).first["used"]
    assert_empty Robin::Limiter.list(config: Robin::Config.new.tap { |c|
      c.redis = {url: REDIS_URL}
      c.key_prefix = "#{key_prefix_for_test}empty:"
    })
  end

  def test_list_reads_every_kinds_usage_together
    Robin::Limiter.concurrent("concurrent", 4, config: config).within_limit {}
    %i[bucket window leaky points].each do |kind|
      Robin::Limiter.public_send(kind, kind, 4, :hour, config: config).within_limit {}
    end
    rows = assert_roundtrips(2) { Robin::Limiter.list(config: config) }

    assert_equal({"bucket" => 1, "concurrent" => 0, "leaky" => 1, "points" => 1, "window" => 1}, rows.to_h { |r| r.values_at("name", "used") })
    empty = Robin::Config.new.tap do |c|
      c.redis = {url: REDIS_URL}
      c.key_prefix = "#{key_prefix_for_test}empty:"
    end

    assert_roundtrips(1) { assert_empty Robin::Limiter.list(config: empty) }
  end

  def test_list_defaults_to_robin_config
    Robin::Limiter.concurrent("dflt", 1).within_limit {}

    assert_equal ["dflt"], Robin::Limiter.list.map { |r| r["name"] }
  end

  def test_reset
    l = at(Robin::Limiter.bucket("r", 1, :minute, wait_timeout: 0, config: config), Robin.now_ms)
    l.within_limit {}
    assert_raises(Robin::Limiter::OverLimit) { l.within_limit {} }

    assert_true assert_roundtrips(2) { Robin::Limiter.reset!("r", config: config) }
    assert_equal "0", meta("r")["over"]
    l.within_limit {}

    assert Robin::Limiter.reset!("unknown", config: config)
    assert_equal 0, redis("EXISTS", key("lmtr", "unknown"))
    redis("HSET", key("lmtr", "odd"), "type", "quantum", "limit", "1", "interval", "", "over", "4")

    assert Robin::Limiter.reset!("odd", config: config)
    assert_equal "0", meta("odd")["over"]
    Robin::Limiter.concurrent("dflt", 1).within_limit {}

    assert Robin::Limiter.reset!("dflt")
  end

  def test_delete
    Robin::Limiter.window("d", 1, 60, config: config).within_limit {}

    assert_true assert_roundtrips(2) { Robin::Limiter.delete!("d", config: config) }
    assert_equal 0, redis("EXISTS", key("lmtr", "d"))
    assert_equal 0, redis("EXISTS", key("lmtr", "d", "s"))
    assert_empty redis("SMEMBERS", key("limiters"))
    Robin::Limiter.concurrent("dflt", 1).within_limit {}

    assert Robin::Limiter.delete!("dflt")
    assert_empty Robin::Limiter.list
    redis("SADD", key("limiters"), "expired")

    assert assert_roundtrips(2) { Robin::Limiter.delete!("expired", config: config) }
    assert_empty redis("SMEMBERS", key("limiters")), "unlisted though its definition had expired"
    assert assert_roundtrips(1) { Robin::Limiter.reset!("expired", config: config) }
    assert_equal 0, redis("EXISTS", key("lmtr", "expired")), "not brought back"
  end

  # -- middleware --------------------------------------------------------------

  def freeze_now(ms = NOW) = Robin.define_singleton_method(:now_ms) { ms }

  def middleware
    freeze_now
    mw = Robin::Limiter::ServerMiddleware.new
    mw.config = config
    mw.define_singleton_method(:rand) { 0.5 } # jitter factor 1.0
    mw
  end

  def over(retry_after = nil) = Robin::Limiter::OverLimit.new(Robin::Limiter.concurrent("api", 1, config: config), retry_after)

  def scheduled
    redis("ZRANGE", key("schedule"), 0, -1, "WITHSCORES").each_slice(2).map { |raw, score| [JSON.parse(raw), Robin.epoch_ms(score)] }
  end

  def test_middleware_passes_through
    assert_equal :ran, middleware.call(nil, {}, "q") { :ran }
  end

  def test_middleware_reschedules
    errors = capture_errors
    log = StringIO.new
    config.logger = Logger.new(log)
    payload = {"class" => "Job", "jid" => "j1", "args" => [1], "at" => 1.5, "enqueued_at" => 2}

    assert_nil middleware.call(nil, payload, "q") { raise over }
    (item, score), = scheduled

    assert_equal [1_800_000_005.0], redis("ZRANGE", key("schedule"), 0, -1, "WITHSCORES").values_at(1).map { |s| Float(s) }
    assert_equal({"class" => "Job", "jid" => "j1", "args" => [1], "limited" => 1}, item)
    assert_equal NOW + 5_000, score
    assert_equal [1], item["args"]
    refute payload.key?("limited") # the running payload is untouched
    assert_includes log.string, 'Job jid=j1 over limit "api"; rescheduled in 5.0s'
    assert_empty errors
  end

  def test_middleware_reschedules_are_events
    events = capture_events
    first = {"class" => "Job", "jid" => "j1", "args" => [1], "at" => 1.5}
    second = {"class" => "Job", "jid" => "j2", "limited" => 1}
    middleware.call(nil, first, "q") { raise over }
    middleware.call(nil, second, "q") { raise over(60.5) }

    assert_equal [["job.rate_limited", {job: first, limiter: "api", delay: 5.0}],
      ["job.rate_limited", {job: second, limiter: "api", delay: 60.5}]], events
  end

  def test_middleware_backoff_grows_and_respects_retry_after
    before = NOW
    middleware.call(nil, {"jid" => "a", "limited" => 2, "limiter_backoff" => 1}, "q") { raise over }
    middleware.call(nil, {"jid" => "b", "limited" => 2}, "q") { raise over(60.5) }
    middleware.call(nil, {"jid" => "c", "limited" => 19, "limiter_backoff" => 20}, "q") { raise over(1) }
    middleware.call(nil, {"jid" => "d", "limiter_backoff" => 2.0006}, "q") { raise over }
    jobs = scheduled.to_h { |item, score| [item["jid"], score - before] }

    assert_equal [3, 3, 20, 1], scheduled.sort_by { |i, _| i["jid"] }.map { |i, _| i["limited"] }
    assert_equal 3_000, jobs["a"]
    assert_equal 60_500, jobs["b"]
    assert_equal 300_000, jobs["c"] # capped at five minutes
    assert_equal 2_000, jobs["d"] # to the whole millisecond
  end

  def test_middleware_jitter
    mw = middleware
    mw.define_singleton_method(:rand) { 0.0 }
    before = NOW
    mw.call(nil, {"jid" => "a"}, "q") { raise over }
    mw.define_singleton_method(:rand) { 1.0 }
    mw.call(nil, {"jid" => "b"}, "q") { raise over }
    jobs = scheduled.to_h { |item, score| [item["jid"], score - before] }

    assert_equal 4_250, jobs["a"]
    assert_equal 5_750, jobs["b"]
  end

  def test_middleware_logs_the_rounded_delay
    log = StringIO.new
    config.logger = Logger.new(log)
    mw = middleware
    mw.define_singleton_method(:rand) { 0.123 }
    mw.call(nil, {"class" => "Job", "jid" => "a"}, "q") { raise over }

    assert_includes log.string, "rescheduled in 4.4s"
  end

  def test_middleware_stores_the_job_as_it_was
    raw = JSON.generate({"jid" => "a", "args" => ["cipher"]})
    payload = Robin.remember_raw(JSON.parse(raw), raw)
    payload["args"] = ["plain"] # decrypted (or changed) while running
    middleware.call(nil, payload, "q") { raise over }

    assert_equal ["cipher"], scheduled.first.first["args"]
  end

  def over_with(**options) = Robin::Limiter::OverLimit.new(Robin::Limiter.concurrent("api", 1, config: config, **options))

  def test_middleware_uses_the_limiters_reschedule_count
    config.max_rate_limit_retries = 2
    middleware.call(nil, {"jid" => "a", "limited" => 4}, "q") { raise over_with(reschedule: 5) }
    assert_raises(Robin::Limiter::OverLimit) { middleware.call(nil, {"jid" => "b", "limited" => 5}, "q") { raise over_with(reschedule: 5) } }
    assert_raises(Robin::Limiter::OverLimit) { middleware.call(nil, {"jid" => "c"}, "q") { raise over_with(reschedule: 0) } }

    assert_equal ["a"], scheduled.map { |i, _| i["jid"] }
  end

  def test_middleware_uses_the_limiters_backoff_then_the_configs
    errors = capture_errors
    seen = []
    config.rate_limit_backoff = ->(count, _error, payload) { (payload["jid"] == "c") ? nil : count * 100 }
    middleware.call(nil, {"jid" => "a", "limited" => 1}, "q") do
      raise over_with(backoff: ->(count, error, payload) { seen << [count, error.class, payload["jid"]] && 7.5 })
    end
    middleware.call(nil, {"jid" => "b", "limited" => 2}, "q") { raise over }
    middleware.call(nil, {"jid" => "c"}, "q") { raise over }
    middleware.call(nil, {"jid" => "d"}, "q") { raise over_with(backoff: ->(*) {}) }
    jobs = scheduled.to_h { |item, score| [item["jid"], score - NOW] }

    assert_equal [[2, Robin::Limiter::OverLimit, "a"]], seen
    # A limiter's backoff returning nil means the default, not the config's.
    assert_equal({"a" => 7_500, "b" => 300_000, "c" => 5_000, "d" => 5_000}, jobs)
    assert_empty errors
  end

  def test_middleware_backoff_of_zero_and_without_jitter
    errors = capture_errors
    config.rate_limit_backoff = ->(*) { 0 }
    mw = middleware
    mw.define_singleton_method(:rand) { 0.0 }
    mw.call(nil, {"jid" => "a"}, "q") { raise over }

    assert_equal [NOW], scheduled.map(&:last)
    assert_empty errors
  end

  def test_middleware_reports_unusable_backoffs_and_uses_the_default
    errors = capture_errors
    [-1, "5", Float::INFINITY, Complex(1, 1), :later].each_with_index do |bad, i|
      config.rate_limit_backoff = ->(*) { bad }
      middleware.call(nil, {"jid" => "j#{i}"}, "q") { raise over }
    end
    config.rate_limit_backoff = ->(*) { raise "oops" }
    middleware.call(nil, {"jid" => "raised"}, "q") { raise over }

    assert_equal [5_000], scheduled.map { |_, score| score - NOW }.uniq
    assert_equal [ArgumentError] * 5 + [RuntimeError], errors.map { |e, _| e.class }
    assert_equal "rate limit backoff returned -1; expected seconds (>= 0) or nil", errors.first.first.message
    assert_equal %(rate limit backoff returned "5"; expected seconds (>= 0) or nil), errors[1].first.message
    assert_equal({context: "rate limit backoff", job: {"jid" => "j0"}}, errors.first.last)
    assert_equal "oops", errors.last.first.message
  end

  def test_middleware_gives_up_after_max
    config.max_rate_limit_retries = 2
    middleware.call(nil, {"jid" => "a", "limited" => 1}, "q") { raise over }
    assert_raises(Robin::Limiter::OverLimit) { middleware.call(nil, {"jid" => "b", "limited" => 2}, "q") { raise over } }

    assert_equal ["a"], scheduled.map { |i, _| i["jid"] }
  end
end
