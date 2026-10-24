# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class LeaderTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Leader*"

  def setup
    super
    @events = []
    config.on(:leader) { @events << :leader }
    config.on(:follower) { @events << :follower }
  end

  # A heartbeat's part: the lease request rides in a pipeline.
  def tick(elector) = elector.settle(config.redis { |c| c.pipelined { |p| elector.lease(p) } }.fetch(0))

  def test_lease_queues_the_lease_script
    a = Robin::Leader.new(config, "a")
    before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rec = recording { |c| c.pipelined { |p| assert_nil a.lease(p) } }

    assert_equal [[:pipelined], [:pipe, :evalsha, Robin::Scripts::LEASE, [config.key("leader")], ["a", Robin::Leader::TTL_MS]]],
      rec.calls
    assert_includes before..Process.clock_gettime(Process::CLOCK_MONOTONIC), a.instance_variable_get(:@asked)
    refute_predicate a, :leader?, "only #settle takes the reply"
  end

  def test_acquire_renew_and_transitions
    a = Robin::Leader.new(config, "a")
    b = Robin::Leader.new(config, "b")

    assert_equal "a", a.identity
    assert_false a.leader?
    logs = capture_logs

    assert_true tick(a)
    assert_equal "INFO: became cluster leader\n", logs.string
    assert_true a.leader?
    assert_equal [:leader], @events
    assert_false tick(b)
    refute_predicate b, :leader?
    assert_true tick(a)
    assert_equal [:leader], @events
    assert_equal "a", Robin::Leader.current(config)
    ttl = redis("PTTL", config.key("leader"))

    assert_operator ttl, :>, Robin::Leader::TTL_MS - 2_000
    assert_operator ttl, :<=, Robin::Leader::TTL_MS
  end

  def test_losing_the_lease_fires_follower
    a = Robin::Leader.new(config, "a")
    tick(a)
    redis("SET", config.key("leader"), "b")
    logs = capture_logs

    assert_false tick(a)
    assert_equal "INFO: lost cluster leadership\n", logs.string
    refute_predicate a, :leader?
    assert_equal %i[leader follower], @events
  end

  def test_lease_validity_is_bounded_locally
    a = Robin::Leader.new(config, "a")
    tick(a)
    a.instance_variable_set(:@until, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.001)

    refute_predicate a, :leader?
    a.instance_variable_set(:@until, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1)

    assert_predicate a, :leader?
  end

  def test_until_is_ninety_percent_of_ttl_from_request_start
    a = Robin::Leader.new(config, "a")
    before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    tick(a)
    expires = a.instance_variable_get(:@until)

    assert_in_delta before + Robin::Leader::TTL_MS / 1000.0 * 0.9, expires, 0.5
    b = Robin::Leader.new(config, "b")
    tick(b)

    assert_equal 0, b.instance_variable_get(:@until)
  end

  def test_resign
    a = Robin::Leader.new(config, "a")
    rec = recording { |c| a.resign(c) } # not leader: no round-trip at all

    assert_empty rec.calls
    assert_nil Robin::Leader.current(config)
    redis("SET", config.key("leader"), "someone")
    config.redis { |c| a.resign(c) }

    assert_equal "someone", Robin::Leader.current(config)
    redis("DEL", config.key("leader"))
    tick(a)
    rec = recording { |c| a.resign(c) }

    assert_equal [[:evalsha, Robin::Scripts::RELEASE, [config.key("leader")], ["a"]]], rec.calls
    assert_nil Robin::Leader.current(config)
    refute_predicate a, :leader?
  end

  def test_registry
    other = Robin::Config.new
    a = Robin::Leader.new(config, "a")

    refute Robin::Leader.leader?(config)
    assert_false Robin::Leader.leader?(config)
    Robin::Leader.register(config, a)

    assert_false Robin::Leader.leader?(config)
    tick(a)

    assert_true Robin::Leader.leader?(config)
    assert_true Robin::Leader.leader?
    assert_true Robin.leader?
    assert_false Robin::Leader.leader?(other)
    Robin::Leader.unregister(config)

    assert_false Robin::Leader.leader?(config)
    assert_equal "a", Robin::Leader.current
    other.key_prefix = "#{key_prefix_for_test}other:"
    other.redis = {url: REDIS_URL}

    assert_nil Robin::Leader.current(other)
  ensure
    Robin::Leader.unregister(config)
    other&.redis_pool&.shutdown
  end
end
