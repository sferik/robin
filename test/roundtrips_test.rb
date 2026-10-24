# frozen_string_literal: true

require_relative "test_helper"

# The round-trip counter behind assert_roundtrips (test/support/roundtrips.rb).
class RoundTripsTest < RobinTest
  def test_counts_calls_pipelines_and_transactions_as_one_each
    assert_roundtrips 3 do
      Robin.redis do |c|
        c.call("SET", key("a"), "1")
        c.pipelined { |p| 3.times { p.call("INCR", key("a")) } }
        c.multi { |tx| tx.call("GET", key("a")) }
      end
    end
  end

  def test_returns_the_blocks_value
    assert_equal "PONG", assert_roundtrips(1) { redis("PING") }
  end

  def test_connecting_isnt_a_round_trip
    config.redis_pool.shutdown
    config.redis = {url: REDIS_URL, db: 15}

    assert_roundtrips(1) { redis("PING") }
  end

  def test_accepts_a_range
    assert_roundtrips(1..2) { redis("PING") }
  end

  def test_a_wrong_count_lists_each_trip
    error = assert_raises(Minitest::Assertion) do
      assert_roundtrips 1 do
        Robin.redis do |c|
          c.call("SET", key("a"), "1")
          c.multi do |tx|
            tx.call("INCR", key("a"))
            tx.evalsha(Robin::Scripts::RELEASE, [key("lock")], ["token"])
          end
        end
      end
    end

    assert_equal <<~MSG.chomp, error.message
      Expected 1 Redis round trip, got 2:
        1. SET #{key("a")} 1
        2. INCR #{key("a")} + EVAL Robin::Scripts::RELEASE
    MSG
  end

  def test_none_made_says_so
    error = assert_raises(Minitest::Assertion) { assert_roundtrips(2) { nil } }

    assert_equal "Expected 2 Redis round trips, got 0", error.message
  end

  # (A script no one has loaded: its source is new. Flushing the server's
  # scripts would fail other tests' pipelines meanwhile.)
  def new_script = Robin::Redis::Script.new("return '#{key_prefix_for_test} #{rand(1 << 40)}'")

  def test_loading_a_missing_script_isnt_counted
    script = new_script
    _, trips = RoundTrips.record { assert_roundtrips(1) { Robin.redis { |c| c.evalsha(script) } } }

    assert_equal [false, true], trips.each_with_index.map { |trip, i| trip.reload?(i.positive? && trips[i - 1]) }
  end

  def test_a_pipeline_that_loads_a_script_as_it_goes_is_counted
    script = new_script
    _, trips = RoundTrips.record { assert_roundtrips(1) { Robin.redis { |c| c.pipelined { |p| p.evalsha(script) } } } }

    assert_equal [%w[SCRIPT EVALSHA]], trips.map { |trip| trip.commands.map(&:first) }
    refute trips.first.reload?(nil)
  end

  def test_counts_only_the_calling_thread_unless_asked
    assert_roundtrips(0) { Thread.new { redis("PING") }.join }
    assert_roundtrips(1, all_threads: true) { Thread.new { redis("PING") }.join }
  end

  private

  def key(name) = "#{key_prefix_for_test}#{name}"
end
