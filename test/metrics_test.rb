# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/api"
require_relative "support/runtime"

class MetricsTest < RobinTest
  include ApiTestSupport

  cover "Robin::Metrics*"

  NOW = Time.utc(2026, 3, 4, 5, 6, 7)

  class StatsdSpy
    attr_reader :calls

    def initialize = @calls = []

    def job_metrics(jobs) = @calls << [:jobs, jobs]

    def queue_metrics(queues) = @calls << [:queues, queues]
  end

  # Fails before taking any commands (e.g. it can't connect).
  class UnreachableConn
    def pipelined = raise(Robin::Redis::ConnectionError, "unreachable")
  end

  # Takes the commands, then fails to send them.
  class FailingConn
    def pipelined
      yield Robin::Redis::Pipeline.new
      raise Robin::Redis::ConnectionError, "down"
    end
  end

  def collector = @collector ||= Robin::Metrics::Collector.new

  def flush(time = NOW) = alt_config.redis { |c| collector.flush(alt_config, c, time) }

  def hash(*parts) = alt("HGETALL", alt_key(*parts)).each_slice(2).to_h

  def test_bucket_for
    assert_equal 0, Robin::Metrics.bucket_for(0)
    assert_equal 0, Robin::Metrics.bucket_for(5)
    assert_equal 1, Robin::Metrics.bucket_for(5.1)
    assert_equal 23, Robin::Metrics.bucket_for(600_000)
    assert_equal 24, Robin::Metrics.bucket_for(600_001)
    assert_equal Robin::Metrics::BUCKETS.size - 1, Robin::Metrics.bucket_for(10**12)
  end

  def test_stamps_are_utc_and_leave_the_time_alone
    local = Time.new(2026, 3, 4, 10, 6, 7, "+05:00")

    assert_equal "202603040506", Robin::Metrics.minute_stamp(local)
    assert_equal "2026030405", Robin::Metrics.hour_stamp(local)
    assert_equal 18_000, local.utc_offset
  end

  def test_record_and_drain
    collector.record("A", 4.0, true)
    collector.record("A", 7.5, false)
    collector.record("B", 1_000, true)
    jobs, processed, failed = collector.drain

    assert_equal({"A" => {s: 1, f: 1, ms: 4.0, hist: {0 => 1}},
                  "B" => {s: 1, f: 0, ms: 1_000.0, hist: {11 => 1}}}, jobs)
    assert_equal [3, 1], [processed, failed]
    assert_equal [{}, 0, 0], collector.drain
  end

  # Asserts the block can't finish while another thread holds +mutex+.
  def assert_synchronized(mutex = collector.instance_variable_get(:@mutex))
    mutex.lock
    thread = Thread.new { yield }

    assert_nil thread.join(0.2), "expected the collector to wait for its lock"
  ensure
    mutex.unlock
    thread&.join
  end

  def stripes = collector.instance_variable_get(:@stripes)

  def test_each_thread_records_into_a_stripe_of_its_own
    collector.record("A", 4.0, true)
    Array.new(3) { |i| Thread.new { collector.record("A", 4.0, i.zero?) } }.each(&:join)

    assert_equal 4, stripes.size
    assert_equal [Thread.current], stripes.map(&:thread) & [Thread.current]
    jobs, processed, failed = collector.drain

    assert_equal({"A" => {s: 2, f: 2, ms: 8.0, hist: {0 => 2}}}, jobs)
    assert_equal [4, 2], [processed, failed]
  end

  def test_stripes_of_finished_threads_go_once_drained
    Thread.new { collector.record("A", 1, true) }.join
    collector.record("B", 1, true)

    assert_equal %w[A B], collector.drain[0].keys.sort
    assert_equal [Thread.current], stripes.map(&:thread)
    assert_equal [{}, 0, 0], collector.drain
  end

  def test_new_stripes_and_drains_take_the_collector_lock
    assert_synchronized { collector.record("A", 1, true) }
    assert_synchronized { collector.drain }
    assert_synchronized { collector.restore([{}, 0, 0]) }
  end

  def test_a_stripe_takes_its_own_lock
    collector.record("A", 1, true)
    stripe = stripes.first
    lock = stripe.instance_variable_get(:@mutex)

    assert_synchronized(lock) { stripe.record("A", 1, true) }
    assert_synchronized(lock) { stripe.drain }
    assert_synchronized(lock) { stripe.add([{}, 0, 0]) }
  end

  def test_restore_merges
    collector.record("A", 4.0, true)
    collector.restore([{"A" => {s: 2, f: 1, ms: 3.0, hist: {0 => 2, 5 => 1}}, "C" => {s: 0, f: 1, ms: 1.0, hist: {0 => 1}}}, 5, 2])
    jobs, processed, failed = collector.drain

    assert_equal({"A" => {s: 3, f: 1, ms: 7.0, hist: {0 => 3, 5 => 1}}, "C" => {s: 0, f: 1, ms: 1.0, hist: {0 => 1}}}, jobs)
    assert_equal [6, 2], [processed, failed]
  end

  # Runs the block with a connection that records every command.
  def recorded
    alt_config.redis do |real|
      rec = RuntimeTestHelpers::RecordingConnection.new(real)
      yield rec
      rec.calls
    end
  end

  def test_flush_with_nothing_recorded_writes_nothing
    alt_config.statsd = StatsdSpy.new

    assert_roundtrips(0) { flush }
    assert_empty alt("KEYS", "#{alt_config.key_prefix}*")
    assert_empty alt_config.statsd.calls
  end

  def test_flush_takes_one_round_trip
    collector.record("Ok", 1, true)
    collector.record("Bad", 1, false)

    alt_config.redis { |c| assert_roundtrips(1) { collector.flush(alt_config, c, NOW) } }
    assert_equal %w[2 1], [alt("GET", alt_key("stat", "processed")), alt("GET", alt_key("stat", "failed"))]
  end

  # The heartbeat sends the metrics in its own transaction.
  def test_queued_metrics_go_with_other_commands
    alt_config.statsd = StatsdSpy.new
    collector.record("Ok", 1, true)
    queued = nil
    replies = alt_config.redis do |c|
      c.multi do |tx|
        tx.call("SET", alt_key("x"), "1")
        queued = collector.queue(alt_config, tx, NOW)
      end
    end

    assert_equal ["OK", 1], replies.first(2)
    assert_equal [{"Ok" => {s: 1, f: 0, ms: 1.0, hist: {0 => 1}}}, 1, 0], queued
    assert_empty alt_config.statsd.calls, "reported once they're written"
    collector.flushed(alt_config, queued)

    assert_equal 1, alt_config.statsd.calls.size
    collector.flushed(alt_config, [{}, 0, 0])

    assert_equal 1, alt_config.statsd.calls.size, "nothing to report"
    assert_equal [{}, 0, 0], alt_config.redis { |c| c.multi { |tx| queued = collector.queue(alt_config, tx, NOW) } } && queued
  end

  def test_flush_writes_counters_rollups_and_histograms
    alt_config.metrics_retention_days = 2
    collector.record("Ok", 12.345, true)
    collector.record("Bad", 30, false)
    collector.record("Bad", 30, false)
    flush

    assert_equal "3", alt("GET", alt_key("stat", "processed"))
    assert_equal "2", alt("GET", alt_key("stat", "failed"))
    assert_equal "3", alt("GET", alt_key("stat", "processed", "2026-03-04"))
    assert_equal "2", alt("GET", alt_key("stat", "failed", "2026-03-04"))
    # Failed runs count, but their time doesn't.
    expected = {"Ok|s" => 1.0, "Ok|ms" => 12.3, "Bad|f" => 2.0}

    assert_equal expected, hash("m", "202603040506").transform_values(&:to_f)
    assert_equal expected, hash("mh", "2026030405").transform_values(&:to_f)
    assert_equal({"2" => "1"}, hash("h", "Ok", "202603040506"))
    assert_empty hash("h", "Bad", "202603040506")
    ttl = ->(*parts) { alt("TTL", alt_key(*parts)) }

    assert_equal Robin::Metrics::MINUTE_TTL, ttl.call("m", "202603040506")
    assert_equal Robin::Metrics::MINUTE_TTL, ttl.call("h", "Ok", "202603040506")
    assert_equal 2 * 86_400, ttl.call("mh", "2026030405")
    # Daily totals outlive the rollups.
    assert_equal 5 * 365 * 86_400, Robin::Metrics::DAILY_TOTALS_TTL
    assert_equal Robin::Metrics::DAILY_TOTALS_TTL, ttl.call("stat", "processed", "2026-03-04")
    assert_equal Robin::Metrics::DAILY_TOTALS_TTL, ttl.call("stat", "failed", "2026-03-04")
  end

  def test_flush_uses_the_utc_day
    collector.record("Bad", 1, false)
    flush(Time.new(2026, 3, 5, 2, 0, 0, "+05:00")) # 2026-03-04 21:00 UTC

    assert_equal "1", alt("GET", alt_key("stat", "failed"))
    assert_equal "1", alt("GET", alt_key("stat", "failed", "2026-03-04"))
    assert_equal "1", alt("GET", alt_key("stat", "processed", "2026-03-04"))
    assert_equal({"Bad|f" => 1.0}, hash("m", "202603042100").transform_values(&:to_f))
  end

  def test_flush_without_failures_leaves_failure_counters_alone
    collector.record("Ok", 1, true)
    flush

    assert_nil alt("GET", alt_key("stat", "failed"))
    assert_nil alt("GET", alt_key("stat", "failed", "2026-03-04"))
  end

  def test_flush_reports_to_statsd
    alt_config.statsd = StatsdSpy.new
    collector.record("Ok", 1, true)
    flush

    assert_equal [[:jobs, {"Ok" => {s: 1, f: 0, ms: 1.0, hist: {0 => 1}}}]], alt_config.statsd.calls
  end

  def test_flush_defaults_to_now
    collector.record("Ok", 1, true)
    alt_config.redis { |c| collector.flush(alt_config, c) }

    assert_equal({"Ok|s" => "1", "Ok|ms" => "1"}, hash("m", Robin::Metrics.minute_stamp(Time.now)))
  end

  def test_a_flush_that_fails_before_it_takes_the_data_raises_its_own_error
    collector.record("Ok", 1, true)

    error = assert_raises(Robin::Redis::ConnectionError) { collector.flush(alt_config, UnreachableConn.new, NOW) }
    assert_equal "unreachable", error.message
    assert_equal 1, collector.drain[1], "still there"
  end

  def test_queue_writes_the_current_minute_by_default
    collector.record("Ok", 1, true)
    before = Robin::Metrics.minute_stamp(Time.now)
    alt_config.redis { |c| c.pipelined { |p| collector.queue(alt_config, p) } }
    minutes = [before, Robin::Metrics.minute_stamp(Time.now)].uniq # the minute may have turned meanwhile

    assert_equal 1, minutes.sum { |minute| hash("m", minute)["Ok|s"].to_i }
  end

  def test_failed_flush_restores_data
    collector.record("Ok", 1, true)

    assert_raises(Robin::Redis::ConnectionError) { collector.flush(alt_config, FailingConn.new, NOW) }
    assert_equal [{"Ok" => {s: 1, f: 0, ms: 1.0, hist: {0 => 1}}}, 1, 0], collector.drain
  end

  def test_sample_queues_without_queues
    alt_config.statsd = StatsdSpy.new

    assert_nil(alt_config.redis { |c| assert_roundtrips(1) { Robin::Metrics.sample_queues(alt_config, c, NOW) } })
    assert_empty alt_config.statsd.calls
  end

  def test_sample_queues_keeps_maxima
    alt_config.statsd = StatsdSpy.new
    alt_config.metrics_retention_days = 3
    now = Robin.now_ms
    push("a", job("1", enqueued_at: now - 9_000), job("2", enqueued_at: now - 5_000), job("3", enqueued_at: now))
    push("b", job("3", enqueued_at: now))
    alt("HSET", alt_key("qm", "202603040506"), "b|size", "10")
    calls = assert_roundtrips(2) { recorded { |c| Robin::Metrics.sample_queues(alt_config, c, NOW) } }
    minute = hash("qm", "202603040506")

    assert_equal [:evalsha, :pipelined], calls.map(&:first) - [:pipe], "the maxima share a round trip"

    assert_equal %w[3 10], minute.values_at("a|size", "b|size")
    assert_equal "1", hash("qh", "2026030405")["b|size"]
    assert_in_delta 9.0, minute["a|latency"].to_f, 1.0
    assert_equal Robin::Metrics::MINUTE_TTL, alt("TTL", alt_key("qm", "202603040506"))
    assert_equal 3 * 86_400, alt("TTL", alt_key("qh", "2026030405"))
    (kind, samples), = alt_config.statsd.calls

    assert_equal :queues, kind
    assert_equal %w[a b], samples.keys.sort
    assert_equal 3, samples["a"][:size]
    assert_in_delta 9.0, samples["a"][:latency], 1.0
  end

  def test_sample_queues_defaults_to_now
    push("a", job("1"))
    alt_config.redis { |c| Robin::Metrics.sample_queues(alt_config, c) }

    assert_equal "1", hash("qm", Robin::Metrics.minute_stamp(Time.now))["a|size"]
  end

  def query = Robin::Metrics::Query.new(alt_config)

  def test_recent_summarizes_minutes
    alt("HSET", alt_key("m", "202603040506"), "A|s", "2", "A|f", "1", "A|ms", "30.5", "Odd|Name|s", "1", "Odd|Name|ms", "4")
    alt("HSET", alt_key("m", "202603040505"), "A|s", "1", "A|ms", "2")
    alt("HSET", alt_key("m", "202603040504"), "Only|ms", "9")
    result = query.recent(minutes: 2, now: NOW)

    assert_equal({"A" => {"s" => 3, "f" => 1, "ms" => 32.5, "avg_ms" => 10.8},
                  "Odd|Name" => {"s" => 1, "f" => 0, "ms" => 4.0, "avg_ms" => 4.0}}, result["classes"])
    assert_equal [{"t" => "202603040505", "s" => 1, "f" => 0, "ms" => 2.0},
      {"t" => "202603040506", "s" => 3, "f" => 1, "ms" => 34.5}], result["series"]
    assert_equal({"s" => 0, "f" => 0, "ms" => 9.0, "avg_ms" => 0}, query.recent(minutes: 3, now: NOW)["classes"]["Only"])
    assert_instance_of Integer, result["classes"]["A"]["s"]
  end

  def test_windows_step_by_exact_minutes_and_hours
    on_the_minute = Time.utc(2026, 3, 4, 5, 6, 0)
    end_of_minute = Time.utc(2026, 3, 4, 5, 6, 59)
    on_the_hour = Time.utc(2026, 3, 4, 5, 0, 0)
    end_of_hour = Time.utc(2026, 3, 4, 5, 59, 59)
    minutes = ->(series) { series.map { |p| p["t"] } }

    assert_equal %w[202603040505 202603040506], minutes.call(query.recent(minutes: 2, now: on_the_minute)["series"])
    assert_equal %w[202603040505 202603040506], minutes.call(query.recent(minutes: 2, now: end_of_minute)["series"])
    assert_equal %w[202603040505 202603040506], minutes.call(query.queue_history(points: 2, now: on_the_minute))
    assert_equal %w[202603040505 202603040506], minutes.call(query.queue_history(points: 2, now: end_of_minute))
    assert_equal %w[2026030404 2026030405], minutes.call(query.queue_history(granularity: :hour, points: 2, now: on_the_hour))
    assert_equal %w[2026030404 2026030405], minutes.call(query.queue_history(granularity: :hour, points: 2, now: end_of_hour))
    alt("HSET", alt_key("h", "A", "202603040505"), "0", "1")
    alt("HSET", alt_key("h", "A", "202603040507"), "0", "100")

    assert_equal 1, query.histogram("A", minutes: 2, now: on_the_minute).first["count"]
    assert_equal 1, query.histogram("A", minutes: 2, now: end_of_minute).first["count"]
  end

  def test_recent_defaults
    result = query.recent

    assert_equal 60, result["series"].size
    assert_equal Robin::Metrics.minute_stamp(Time.now), result["series"].last["t"]
  end

  def test_history_summarizes_hours
    alt("HSET", alt_key("mh", "2026030405"), "A|s", "5", "A|ms", "10")
    alt("HSET", alt_key("mh", "2026030404"), "A|f", "1", "A|ms", "2")
    result = query.history(hours: 2, now: NOW)

    assert_equal %w[2026030404 2026030405], result["series"].map { |p| p["t"] }
    assert_equal({"s" => 5, "f" => 1, "ms" => 12.0, "avg_ms" => 2.4}, result["classes"]["A"])
    assert_equal 168, query.history["series"].size
    hours = ->(now) { query.history(hours: 2, now: now)["series"].map { |p| p["t"] } }

    assert_equal %w[2026030404 2026030405], hours.call(Time.utc(2026, 3, 4, 5, 0, 0))
    assert_equal %w[2026030404 2026030405], hours.call(Time.utc(2026, 3, 4, 5, 59, 59))
  end

  def test_queue_history
    alt("HSET", alt_key("qm", "202603040506"), "a|size", "3", "a|latency", "1.5", "x|y|size", "2")
    alt("HSET", alt_key("qh", "2026030405"), "b|size", "7")
    minutes = query.queue_history(points: 2, now: NOW)

    assert_equal [{"t" => "202603040505", "queues" => {}},
      {"t" => "202603040506", "queues" => {"a" => {"size" => 3, "latency" => 1}, "x|y" => {"size" => 2}}}], minutes
    hours = query.queue_history(granularity: :hour, points: 2, now: NOW)

    assert_equal [{"t" => "2026030404", "queues" => {}}, {"t" => "2026030405", "queues" => {"b" => {"size" => 7}}}], hours
    assert_equal 60, query.queue_history.size
    assert_equal Robin::Metrics.minute_stamp(Time.now), query.queue_history.last["t"]
    assert_raises(KeyError) { query.queue_history(granularity: :day) }
  end

  def test_histogram
    alt("HSET", alt_key("h", "A", "202603040506"), "0", "2", "24", "1")
    alt("HSET", alt_key("h", "A", "202603040505"), "0", "1")
    alt("HSET", alt_key("h", "A", "202603040504"), "3", "9")
    buckets = query.histogram("A", minutes: 2, now: NOW)

    assert_equal Robin::Metrics::BUCKETS.size, buckets.size
    assert_equal({"le" => 5, "count" => 3}, buckets.first)
    assert_equal({"le" => nil, "count" => 1}, buckets.last)
    assert_equal 0, buckets[3]["count"]
    assert_equal 13, query.histogram("A", now: NOW).sum { |b| b["count"] }
    assert_equal 0, query.histogram("A").sum { |b| b["count"] }
    now = Time.now
    alt("HSET", alt_key("h", "B", Robin::Metrics.minute_stamp(now - 59 * 60)), "0", "1")
    alt("HSET", alt_key("h", "B", Robin::Metrics.minute_stamp(now - 60 * 60)), "0", "10")

    assert_equal 1, query.histogram("B", now: now).first["count"]
  end

  def test_query_defaults_to_global_config
    redis("HSET", config.key("m", Robin::Metrics.minute_stamp(Time.now)), "G|s", "1")

    assert_equal 1, Robin::Metrics::Query.new.recent(minutes: 1)["classes"]["G"]["s"]
  end
end
