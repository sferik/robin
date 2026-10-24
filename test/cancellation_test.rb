# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class CancellationTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Cancellation*"

  def cancelled_scores = redis("ZRANGE", config.key("cancelled"), 0, -1, "WITHSCORES").each_slice(2).to_h

  # Asserts +jid+ expires exactly +ttl+ seconds after the cancel! call.
  def assert_expiry(jid, ttl)
    before = Robin.now_ms
    yield
    after = Robin.now_ms
    score = cancelled_scores.fetch(jid).to_i

    assert_operator score, :>=, before + ttl * 1000
    assert_operator score, :<=, after + ttl * 1000
  end

  def unreachable_config
    Robin::Config.new.tap { |c| c.redis = {url: "redis://127.0.0.1:1", connect_timeout: 0.2} }
  end

  def test_cancel_records_jid_with_expiry_and_prunes_expired
    redis("ZADD", config.key("cancelled"), Robin.now_ms - 1_000, "old")
    redis("ZADD", config.key("cancelled"), -5, "ancient")

    assert_expiry("j1", 60) { assert_true Robin::Cancellation.cancel!("j1", ttl: 60, config: config) }
    assert_equal ["j1"], cancelled_scores.keys
  end

  def test_cancel_default_ttl_and_config
    assert_expiry("j2", 86_400) { Robin::Cancellation.cancel!("j2") }
    assert_expiry("j3", 5) { assert Robin.cancel!("j3", ttl: 5) }
  end

  def test_cancel_takes_several_jids_in_one_round_trip
    pool = recording_pool { assert_true assert_roundtrips(1) { Robin::Cancellation.cancel!("j1", ["j2", ["j3"]], ttl: 60, config: config) } }

    assert_equal [[:pipelined], [:pipe, "ZADD"], [:pipe, "ZREMRANGEBYSCORE"]], pool.calls.map { |call| call.first(2) }
    scores = cancelled_scores

    assert_equal %w[j1 j2 j3], scores.keys.sort
    assert_equal 1, scores.values.uniq.size
    assert_expiry("j4", 5) { Robin.cancel!("j4", "j5", ttl: 5) }
    assert_equal cancelled_scores.fetch("j4"), cancelled_scores.fetch("j5")
  end

  def test_cancel_with_no_jids_sends_nothing
    pool = recording_pool { assert_true assert_roundtrips(0) { Robin::Cancellation.cancel!([], config: config) } }

    assert_empty pool.calls
    assert_true Robin.cancel!
  end

  def test_cancelled_live_check
    refute assert_roundtrips(1) { Robin::Cancellation.cancelled?("j1", config: config) }
    Robin::Cancellation.cancel!("j1", config: config)

    assert_true Robin::Cancellation.cancelled?("j1", config: config)
    assert_true Robin::Cancellation.cancelled?("j1")
    assert_false Robin::Cancellation.cancelled?("zz")
  end

  def test_cancelled_without_jid_never_touches_redis
    assert_false Robin::Cancellation.cancelled?(nil, config: unreachable_config)
    assert_false Robin::Cancellation.cancelled?(nil, bid: nil, config: unreachable_config)
  end

  def test_jobs_of_a_cancelled_batch_are_cancelled
    Robin::Cancellation.cancel!("batch:b1", config: config)

    assert_true Robin::Cancellation.cancelled?("j1", bid: "b1", config: config)
    assert_true Robin::Cancellation.cancelled?(nil, bid: "b1", config: config)
    assert_false Robin::Cancellation.cancelled?("j1", bid: "b2", config: config)
    assert_false Robin::Cancellation.cancelled?("b1", config: config)
    Robin::Cancellation.cancel!("j3", config: config)

    assert_true Robin::Cancellation.cancelled?("j3", bid: "b2", config: config)
  end

  def test_skip_uses_local_cache_refreshed_from_redis
    other = Robin::Config.new
    j1 = "j1-#{SecureRandom.hex(4)}" # unique, so nothing another run left behind matches

    refute Robin::Cancellation.skip?(other, j1)
    redis("ZADD", config.key("cancelled"), Robin.now_ms + 60_000, j1)
    redis("ZADD", config.key("cancelled"), Robin.now_ms - 10, "expired")
    redis("ZADD", "cancelled", Robin.now_ms + 60_000, "unprefixed")

    refute Robin::Cancellation.skip?(config, j1)
    config.redis { |c| Robin::Cancellation.refresh(config, c) }

    assert_true Robin::Cancellation.skip?(config, j1)
    assert_false Robin::Cancellation.skip?(config, "expired")
    assert_false Robin::Cancellation.skip?(config, "unprefixed")
    assert_false Robin::Cancellation.skip?(other, j1)
    # cancel! also updates an existing local cache immediately
    Robin::Cancellation.cancel!("j2", ["j7"], config: config)

    assert Robin::Cancellation.skip?(config, "j2")
    assert Robin::Cancellation.skip?(config, "j7")
    Robin::Cancellation.cancel!("batch:b1", config: config)

    assert_true Robin::Cancellation.skip?(config, "j9", "b1")
    assert_true Robin::Cancellation.skip?(config, "j2", "b2")
    assert_false Robin::Cancellation.skip?(config, "j9", "b2")
    assert_false Robin::Cancellation.skip?(config, "j9", nil)
    assert_false Robin::Cancellation.skip?(other, "j9", "b1")
  ensure
    redis("DEL", "cancelled")
  end

  def test_refresh_with_empty_set
    config.redis { |c| Robin::Cancellation.refresh(config, c) }

    assert_false Robin::Cancellation.skip?(config, "x")
  end
end
