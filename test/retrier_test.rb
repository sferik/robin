# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class RetrierTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Retrier*"

  class Plain; end

  class Hooked
    class << self
      attr_accessor :retry_in, :exhausted

      def robin_retry_in_block = retry_in

      def robin_retries_exhausted_block = exhausted
    end
  end

  def setup
    super
    @fetcher = Robin::Fetcher.new(config.default_capsule, "me")
    @retrier = Robin::Retrier.new(config)
    @errors = capture_errors
    Hooked.retry_in = nil
    Hooked.exhausted = nil
  end

  def inflight = in_flight(@fetcher.inflight_key)

  def unit_for(payload) = unit_in_flight(@fetcher, JSON.generate(payload))

  def payload(**extra) = {"class" => "Plain", "args" => [1], "jid" => "j1", "queue" => "default"}.merge(extra.transform_keys(&:to_s))

  def backtrace(item) = Robin::Retrier.unpack_backtrace(item.fetch("error_backtrace"))

  def error(message = "boom", backtrace: %w[a:1 b:2 c:3])
    RuntimeError.new(message).tap { |e| e.set_backtrace(backtrace) }
  end

  def retries = redis("ZRANGE", config.key("retry"), 0, -1, "WITHSCORES").each_slice(2).map { |v, s| [JSON.parse(v), Float(s)] }

  def dead = redis("ZRANGE", config.key("dead"), 0, -1).map { |v| JSON.parse(v) }

  def with_rand(value, &) = stub_method(Robin::Retrier, :rand, ->(*) { value }, &)

  def test_accessor
    assert_same config, @retrier.config
  end

  def test_default_delay_grows_with_jitter_and_caps
    with_rand(0.5) do
      assert_equal 15, Robin::Retrier.default_delay(1)
      assert_equal 26, Robin::Retrier.default_delay(2) # 25.5 rounds up
      assert_equal 43, Robin::Retrier.default_delay(3) # 43.35
      assert_equal 604_800, Robin::Retrier.default_delay(40)
    end
    with_rand(0.0) { assert_equal 12, Robin::Retrier.default_delay(1) }
    with_rand(1.0) { assert_equal 18, Robin::Retrier.default_delay(1) }
    with_rand(0.999) { assert_equal 725_518, Robin::Retrier.default_delay(60) } # 1.1996 * MAX_DELAY
    assert_equal 604_800, Robin::Retrier::MAX_DELAY
  end

  def test_max_retries
    config.max_retries = 7

    assert_equal 7, @retrier.max_retries({"retry" => true})
    assert_equal 7, @retrier.max_retries({})
    assert_equal 0, @retrier.max_retries({"retry" => false})
    assert_equal 3, @retrier.max_retries({"retry" => 3})
    assert_equal 4, @retrier.max_retries({"retry" => "4"})
    assert_raises(ArgumentError) { @retrier.max_retries({"retry" => "x"}) }
    assert_equal Float::INFINITY, @retrier.max_retries({"retry_for" => 60})
    assert_equal 7, @retrier.max_retries({"retry_for" => nil})
    assert_equal Float::INFINITY, @retrier.max_retries({"retry" => true, "retry_for" => 60})
    assert_equal 3, @retrier.max_retries({"retry" => 3, "retry_for" => 60})
    assert_equal 0, @retrier.max_retries({"retry" => false, "retry_for" => 60})
  end

  def test_retry_for_retries_past_max_retries_until_time_is_up
    config.max_retries = 2
    now = Robin.now_ms
    item = payload(retry_for: 3600, retry_count: 4, failed_at: now - 3_000_000)

    # 1.7**5 * 15 = ~213s from now: inside the hour.
    assert_equal :retry, with_rand(0.5) { @retrier.handle(unit_for(item), item, Plain, error) }
    item = payload(jid: "j2", retry_for: 3600, retry_count: 4, failed_at: now - 3_500_000)

    assert_equal :dead, with_rand(0.5) { @retrier.handle(unit_for(item), item, Plain, error) }
    assert_equal ["j2"], dead.map { |d| d["jid"] }
  end

  def test_retry_for_counts_from_the_first_failure_to_the_retry
    stub_method(Robin, :now_ms, -> { 1_000_000 }) do
      at_limit = payload(retry_for: 15.5)
      # The first retry comes 15s (with rand 0.5) after the first failure.
      assert_equal :retry, with_rand(0.5) { @retrier.handle(unit_for(at_limit), at_limit, Plain, error) }
      assert_in_delta 1_015.0, at_limit["at"], 0.0
      exact = payload(jid: "j2", retry_for: 15)

      assert_equal :retry, with_rand(0.5) { @retrier.handle(unit_for(exact), exact, Plain, error) }
      over = payload(jid: "j3", retry_for: 14.999)

      assert_equal :dead, with_rand(0.5) { @retrier.handle(unit_for(over), over, Plain, error) }
    end
  end

  def test_retry_for_also_limits_a_custom_delay_but_not_kill_or_discard
    Hooked.retry_in = ->(*) { 120 }
    item = payload(class: "Hooked", retry_for: 60)

    assert_equal :dead, with_rand(0) { @retrier.handle(unit_for(item), item, Hooked, error) }
    Hooked.retry_in = ->(*) { :discard }
    item = payload(jid: "j2", class: "Hooked", retry_for: 60)

    assert_equal :discard, @retrier.handle(unit_for(item), item, Hooked, error)
  end

  def test_retry_for_reads_a_failed_at_in_epoch_seconds
    stub_method(Robin, :now_ms, -> { 1_700_000_000_000 }) do
      # A second failure retries 26s later (with rand 0.5): 60s after failed_at.
      inside = payload(retry_count: 0, retry_for: 60, failed_at: 1_699_999_966.0)

      assert_equal :retry, with_rand(0.5) { @retrier.handle(unit_for(inside), inside, Plain, error) }
      assert_in_delta 1_699_999_966.0, inside["failed_at"], 0.0
      over = payload(jid: "j2", retry_count: 0, retry_for: 60, failed_at: 1_699_999_965.999)

      assert_equal :dead, with_rand(0.5) { @retrier.handle(unit_for(over), over, Plain, error) }
    end
  end

  def test_retry_count_still_applies_with_retry_for
    item = payload(retry: 1, retry_for: 86_400, retry_count: 0)

    assert_equal :dead, @retrier.handle(unit_for(item), item, Plain, error)
  end

  def test_retry_queue
    item = payload(retry_queue: "slow")
    unit = unit_for(item)

    assert_equal :retry, @retrier.handle(unit, item, Plain, error)
    (stored, _), = retries

    assert_equal "slow", stored["queue"]
    assert_equal "slow", item["queue"]
    item = payload(jid: "j2", retry_queue: nil)
    @retrier.handle(unit_for(item), item, Plain, error)

    assert_equal %w[slow default], retries.map { |(stored, _)| stored["queue"] }.sort.reverse
  end

  def test_jobs_that_die_or_are_discarded_release_their_unique_lock
    lock = config.key("unique", "d1")
    [payload(unique_digest: "d1", retry: 0), payload(unique_digest: "d1", retry: false)].each do |item|
      redis("SET", lock, "j1")
      @retrier.handle(unit_for(item), item, Plain, error)

      assert_equal 0, redis("EXISTS", lock)
    end
    redis("SET", lock, "j1")
    item = payload(unique_digest: "d1")
    @retrier.handle(unit_for(item), item, Plain, error)

    assert_equal 1, redis("EXISTS", lock)
  end

  def test_first_failure_schedules_a_retry
    item = payload
    unit = unit_for(item)
    before = Robin.now_ms
    outcome = with_rand(0.5) { assert_roundtrips(1) { @retrier.handle(unit, item, Plain, error) } }
    after = Robin.now_ms

    assert_equal :retry, outcome
    assert_empty inflight
    (stored, score), = retries

    assert_in_delta score, item["at"], 0.0
    assert_operator score, :>=, Robin.epoch_seconds(before + 15_000)
    assert_operator score, :<=, Robin.epoch_seconds(after + 15_000)
    assert_equal "RuntimeError", stored["error_class"]
    assert_equal "boom", stored["error_message"]
    assert_equal 0, stored["retry_count"]
    assert_operator stored["failed_at"], :>=, before
    assert_operator stored["failed_at"], :<=, after
    refute stored.key?("retried_at")
    refute stored.key?("error_backtrace")
    refute stored.key?("at")
    assert_equal stored, item.except("at")
  end

  def test_later_failures_record_retried_at_and_keep_failed_at
    counts = []
    Hooked.retry_in = ->(count, *) { (counts << count) && 10 }
    item = payload(class: "Hooked", retry_count: 1, failed_at: 123, retry: 5)
    before = Robin.now_ms
    @retrier.handle(unit_for(item), item, Hooked, error)

    assert_equal 2, item["retry_count"]
    assert_equal [3], counts # hooks get the 1-based failure count
    assert_equal 123, item["failed_at"]
    assert_operator item["retried_at"], :>=, before
    assert_operator item["retried_at"], :<=, Robin.now_ms
    assert_equal [2], retries.map { |(stored, _)| stored["retry_count"] }
  end

  def test_a_retry_count_stored_by_another_tool_as_a_string_is_incremented
    item = payload(retry_count: "3")
    @retrier.handle(unit_for(item), item, Plain, error)

    assert_equal 4, item["retry_count"]
    assert item.key?("retried_at")
  end

  def test_backtrace_option
    config.backtrace_lines = 2
    reported = []
    config.error_handlers.replace([->(ex, _ctx, _cfg) { reported << ex }])
    item = payload(backtrace: true)
    @retrier.handle(unit_for(item), item, Plain, error)

    assert_equal %w[a:1 b:2], backtrace(item)
    assert_empty reported # no cleaner, nothing to go wrong
    refute item["error_backtrace"].start_with?("deflate:")
    assert_equal %w[a:1 b:2], JSON.parse(Zlib.inflate(item["error_backtrace"].unpack1("m0")))
    item = payload(backtrace: 1)
    @retrier.handle(unit_for(item), item, Plain, error)

    assert_equal %w[a:1], backtrace(item)
    item = payload(backtrace: 5)
    @retrier.handle(unit_for(item), item, Plain, error(backtrace: nil))

    assert_empty item["error_backtrace"]
    item = payload(backtrace: false)
    @retrier.handle(unit_for(item), item, Plain, error)

    refute item.key?("error_backtrace")
  end

  def test_long_messages_are_truncated
    item = payload
    @retrier.handle(unit_for(item), item, Plain, error("é" * 6_000))

    assert_equal 10_000 + "…".bytesize, item["error_message"].bytesize
    assert item["error_message"].end_with?("é…")
    exact = "x" * 10_000
    item = payload
    @retrier.handle(unit_for(item), item, Plain, error(exact))

    assert_equal exact, item["error_message"]
    item = payload
    @retrier.handle(unit_for(item), item, Plain, error("x" * 10_001))

    assert_equal "#{exact}…", item["error_message"]
  end

  def test_a_character_split_by_the_limit_is_dropped
    item = payload
    @retrier.handle(unit_for(item), item, Plain, error("a#{"é" * 5_000}"))

    assert_predicate item["error_message"], :valid_encoding?
    assert_equal "a#{"é" * 4_999}…", item["error_message"]
  end

  def test_message_is_converted_to_a_string
    odd = Class.new(StandardError) do
      def message = nil

      def to_s = "from to_s"
    end
    item = payload
    @retrier.handle(unit_for(item), item, Plain, odd.new)

    assert_equal "", item["error_message"]
    custom = Class.new(StandardError) { def message = "custom message" }
    item = payload
    @retrier.handle(unit_for(item), item, Plain, custom.new("base"))

    assert_equal "custom message", item["error_message"]
  end

  def test_a_message_that_raises_is_recorded_without_it
    broken = Class.new(StandardError) { def message = raise(NoMethodError, "no message for you") }
    item = payload

    assert_equal :retry, @retrier.handle(unit_for(item), item, Plain, broken.new)
    assert_equal "(NoMethodError raised reading the error message)", item["error_message"]
    assert_equal [item.except("at")], retries.map(&:first)
  end

  def test_invalid_and_binary_messages_are_recorded_as_utf8
    {
      String.new("bad \xFF byte", encoding: "UTF-8") => "bad \uFFFD byte",
      "caf\xC3\xA9 \xFF".b => "café \uFFFD",
      String.new("caf\xE9", encoding: "ISO-8859-1") => "café"
    }.each do |message, expected|
      item = payload

      assert_equal :retry, @retrier.handle(unit_for(item), item, Plain, error(message))
      assert_equal expected, item["error_message"]
      assert_equal Encoding::UTF_8, item["error_message"].encoding
      assert_includes redis("ZRANGE", config.key("retry"), 0, -1), JSON.generate(item.except("at"))
    end
  end

  def test_long_binary_messages_are_truncated
    item = payload
    @retrier.handle(unit_for(item), item, Plain, error("\xFF".b * 20_000))

    assert_predicate item["error_message"], :valid_encoding?
    assert_equal "#{"\uFFFD" * 3_333}…", item["error_message"]
    assert_equal 1, retries.size
  end

  def test_pack_and_unpack_backtraces
    lines = ["app/a.rb:1:in 'x'", "app/b.rb:2:in 'y'"] * 50
    packed = Robin::Retrier.pack_backtrace(lines)

    assert_equal "deflate:", Robin::Retrier::BACKTRACE_PREFIX
    assert_equal [Zlib.deflate(JSON.generate(lines))].pack("m0"), packed
    assert_operator packed.bytesize, :<, JSON.generate(lines).bytesize / 4
    refute_includes packed, "\n"
    assert_equal lines, Robin::Retrier.unpack_backtrace(packed)
    # Older versions prefixed it.
    assert_equal lines, Robin::Retrier.unpack_backtrace("deflate:#{packed}")
    assert_equal [], Robin::Retrier.pack_backtrace([])
    # Backtraces stored uncompressed read as they are.
    assert_equal %w[a b], Robin::Retrier.unpack_backtrace(%w[a b])
    assert_nil Robin::Retrier.unpack_backtrace(nil)
    not_json = [Zlib.deflate("{nope")].pack("m0")

    ["plain", "!!!", "aGVsbG8=", "deflate:!!!", "deflate:aGVsbG8=", not_json, "deflate:#{not_json}"].each do |bad|
      assert_equal ["(unreadable backtrace)"], Robin::Retrier.unpack_backtrace(bad), bad
    end
  end

  def test_backtrace_cleaner
    config.backtrace_lines = 2
    seen = []
    config.backtrace_cleaner = ->(lines) { (seen << lines) && lines.reject { |l| l.start_with?("b") } }
    item = payload(backtrace: true)
    @retrier.handle(unit_for(item), item, Plain, error(backtrace: %w[a:1 b:2 c:3 d:4]))

    assert_equal [%w[a:1 b:2 c:3 d:4]], seen
    assert_equal %w[a:1 c:3], backtrace(item)
    item = payload(backtrace: true)
    @retrier.handle(unit_for(item), item, Plain, error(backtrace: nil))

    assert_equal [], item["error_backtrace"]
    assert_equal 1, seen.size
  end

  def test_a_failing_backtrace_cleaner_keeps_the_backtrace
    errors = []
    config.error_handlers.replace([->(ex, ctx, _cfg) { errors << [ex.message, ctx] }])
    config.backtrace_cleaner = ->(_) { raise "cleaner broke" }
    item = payload(backtrace: 2)
    @retrier.handle(unit_for(item), item, Plain, error(backtrace: %w[a:1 b:2 c:3]))

    assert_equal %w[a:1 b:2], backtrace(item)
    assert_equal [["cleaner broke", {context: "backtrace_cleaner"}]], errors.first(1)
  end

  def test_backtraces_are_recorded_as_utf8_or_dropped_when_unreadable
    item = payload(backtrace: true)
    @retrier.handle(unit_for(item), item, Plain, error(backtrace: ["ok:1", "bad\xFF:2".b]))

    assert_equal ["ok:1", "bad\uFFFD:2"], backtrace(item)
    broken = Class.new(StandardError) { def backtrace = raise("no backtrace") }
    item = payload(backtrace: true)

    assert_equal :retry, @retrier.handle(unit_for(item), item, Plain, broken.new("x"))
    assert_equal [], item["error_backtrace"]
  end

  def test_nil_retry_count_counts_as_first_failure
    item = payload(retry_count: nil)
    @retrier.handle(unit_for(item), item, Plain, error)

    assert_equal 0, item["retry_count"]
    refute item.key?("retried_at")
  end

  def test_retry_is_recorded_atomically_with_the_ack
    item = payload
    unit = unit_for(item)
    other = unit_for(item) # an identical copy, in flight in its own key
    pool = recording_pool { with_rand(0.5) { @retrier.handle(unit, item, Plain, error) } }
    zadd, del, srem = pool.calls.select { |c| c[0] == :tx }

    assert_equal [:tx, "ZADD", config.key("retry"), item["at"], JSON.generate(item.except("at"))], zadd
    assert_equal [[:tx, "DEL", unit.key], [:tx, "SREM", @fetcher.inflight_key, unit.key]], [del, srem]
    assert_equal [other.raw], inflight
    assert_equal [other.key], redis("SMEMBERS", @fetcher.inflight_key)
    assert_kind_of Float, item["at"]
  end

  def test_kill_passes_class_and_error_to_die
    seen = []
    Hooked.exhausted = ->(job, ex) { seen << [job["jid"], ex.message] }
    item = payload(retry: 0)
    @retrier.handle(unit_for(item), item, Hooked, error("final"))

    assert_equal [["j1", "final"]], seen
  end

  def test_no_hooks_means_no_errors
    item = payload
    @retrier.handle(unit_for(item), item, Plain, error)
    @retrier.die(nil, payload, Plain, error)

    assert_empty @errors
  end

  def test_string_subclass_from_retry_in_is_an_action
    Hooked.retry_in = ->(*) { Class.new(String).new("kill") }
    item = payload

    assert_equal :dead, @retrier.handle(unit_for(item), item, Hooked, error)
  end

  def test_dead_jobs_use_the_retriers_config
    other = Robin::Config.new
    other.redis = {url: REDIS_URL}
    other.key_prefix = "#{key_prefix_for_test}other:"
    original = Robin.config
    Robin.config = other
    @retrier.die(nil, payload, Plain, error)
    Robin.config = original

    assert_equal 1, redis("ZCARD", config.key("dead"))
    assert_equal 0, redis("ZCARD", other.key("dead"))
  ensure
    Robin.config = original
    other.redis_pool.shutdown
  end

  def test_retry_false_discards
    item = payload(retry: false)
    unit = unit_for(item)

    assert_equal :discard, assert_roundtrips(1) { @retrier.handle(unit, item, Plain, error) }
    assert_empty inflight
    assert_empty retries
    assert_empty dead
    assert_equal 0, item["retry_count"]
  end

  def test_exhausted_retries_die
    item = payload(retry: 2, retry_count: 1)
    unit = unit_for(item)

    assert_equal :dead, assert_roundtrips(1) { @retrier.handle(unit, item, Plain, error) }
    assert_empty inflight
    assert_equal [2], dead.map { |d| d["retry_count"] }
    assert_empty retries
  end

  def test_last_allowed_retry_still_retries
    item = payload(retry: 2, retry_count: 0)

    assert_equal :retry, @retrier.handle(unit_for(item), item, Plain, error)
  end

  def test_retry_zero_goes_straight_to_dead
    item = payload(retry: 0)

    assert_equal :dead, @retrier.handle(unit_for(item), item, Plain, error)
  end

  def test_retry_backoff_replaces_the_default_and_jitter
    seen = []
    config.retry_backoff = lambda do |failures, ex, job, custom|
      seen << [failures, ex.message, job["jid"], custom]
      custom ? custom * 2 : 50
    end
    before = Robin.now_ms
    @retrier.handle(unit_for(payload), payload, Plain, error)
    Hooked.retry_in = ->(*) { 30 }
    @retrier.handle(unit_for(payload(retry_count: 0)), payload(retry_count: 0), Hooked, error)
    Hooked.retry_in = ->(*) { :discard }
    @retrier.handle(unit_for(payload), payload, Hooked, error)

    assert_equal [[1, "boom", "j1", nil], [2, "boom", "j1", 30]], seen
    scores = retries.map(&:last).sort

    assert_in_delta Robin.epoch_seconds(before + 50_000), scores.first, 1
    assert_in_delta Robin.epoch_seconds(before + 60_000), scores.last, 1
  ensure
    config.retry_backoff = nil
  end

  def test_an_active_job_wrappers_hooks_come_from_the_class_it_wraps
    Hooked.retry_in = ->(*) { :discard }
    Hooked.exhausted = ->(*) { :discard }
    wrapping = payload(wrapped: "RetrierTest::Hooked")

    assert_equal :discard, @retrier.handle(unit_for(wrapping), wrapping, Plain, error)
    exhausted = payload(wrapped: "RetrierTest::Hooked", retry: 0)
    Hooked.retry_in = nil

    assert_equal :discard, @retrier.handle(unit_for(exhausted), exhausted, Plain, error)

    assert_empty dead, "the wrapped class's retries_exhausted hook discarded it"
    assert exhausted.key?("discarded_at")
    # Otherwise the job's own hooks apply.
    Hooked.retry_in = ->(*) { :discard }
    %w[RetrierTest::Plain NoSuchClassAnywhere not\ a\ name].each do |name|
      other = payload(wrapped: name)

      assert_equal :discard, @retrier.handle(unit_for(other), other, Hooked, error), name
    end
    assert_equal :discard, @retrier.handle(unit_for(payload(wrapped: true)), payload(wrapped: true), Hooked, error)
  end

  def test_custom_retry_in
    Hooked.retry_in = ->(count, ex, job) { (count == 1 && ex.message == "boom" && job["jid"] == "j1") ? 100 : 1 }
    item = payload
    before = Robin.now_ms
    with_rand(0) { @retrier.handle(unit_for(item), item, Hooked, error) }

    assert_operator retries.first[1], :>=, Robin.epoch_seconds(before + 100_000)
    assert_operator retries.first[1], :<=, Robin.epoch_seconds(Robin.now_ms + 100_000)
  end

  def test_custom_delays_get_up_to_ten_percent_jitter_capped_at_ten_seconds
    with_rand(0.5) do
      assert_in_delta 52.5, Robin::Retrier.jitter(50)
      assert_in_delta 1005, Robin::Retrier.jitter(1000)
      assert_equal 0, Robin::Retrier.jitter(0)
    end
    with_rand(1.0) { assert_in_delta 110, Robin::Retrier.jitter(100) }
  end

  def test_custom_retry_in_fractional_seconds
    Hooked.retry_in = ->(*) { 0.5 }
    item = payload
    before = Robin.now_ms
    @retrier.handle(unit_for(item), item, Hooked, error)

    assert_operator item["at"], :>=, Robin.epoch_seconds(before + 500)
    assert_operator item["at"], :<, Robin.epoch_seconds(before + 1_000)
    assert_kind_of Float, item["at"]
    Hooked.retry_in = ->(*) { 1r / 3 }
    item = payload
    @retrier.handle(unit_for(item), item, Hooked, error)

    assert_kind_of Float, item["at"]
    # Whole milliseconds.
    assert_in_delta Robin.epoch_seconds(Robin.epoch_ms(item["at"])), item["at"], 0.0
  end

  def test_custom_retry_in_kill_symbol
    Hooked.retry_in = ->(*) { :kill }
    item = payload

    assert_equal :dead, @retrier.handle(unit_for(item), item, Hooked, error)
    assert_equal 1, dead.size
    assert_empty @errors
  end

  def test_custom_retry_in_can_discard_or_kill
    Hooked.retry_in = ->(*) { :discard }
    item = payload
    unit = unit_for(item)

    assert_equal :discard, @retrier.handle(unit, item, Hooked, error)
    assert_empty inflight
    Hooked.retry_in = ->(*) { "kill" }
    item = payload

    assert_equal :dead, @retrier.handle(unit_for(item), item, Hooked, error)
    assert_equal 1, dead.size
    Hooked.retry_in = ->(*) { "discard" }
    item = payload

    assert_equal :discard, @retrier.handle(unit_for(item), item, Hooked, error)
  end

  def test_custom_retry_in_nil_or_raising_uses_default
    Hooked.retry_in = ->(*) {}
    item = payload
    with_rand(0.5) { @retrier.handle(unit_for(item), item, Hooked, error) }

    assert_in_delta Robin.epoch_seconds(Robin.now_ms + 15_000), item["at"], 2
    assert_empty @errors, "nil means 'use the default', not an error"
    Hooked.retry_in = ->(*) { raise ArgumentError, "bad block" }
    item = payload
    with_rand(0.5) { @retrier.handle(unit_for(item), item, Hooked, error) }

    assert_in_delta Robin.epoch_seconds(Robin.now_ms + 15_000), item["at"], 2
    ex, ctx = @errors.last

    assert_equal "bad block", ex.message
    assert_equal({context: "robin_retry_in block", job: item}, ctx)
  end

  def test_unusable_retry_in_values_fall_back_to_the_default_and_are_reported
    [" 60", "60", Time.now, :later, -1, -0.5, Float::NAN, Float::INFINITY, Complex(1, 1), [5]].each do |value|
      @errors.clear
      Hooked.retry_in = ->(*) { value }
      item = payload
      before = Robin.now_ms

      assert_equal :retry, with_rand(0.5) { @retrier.handle(unit_for(item), item, Hooked, error) }, value.inspect
      assert_includes Robin.epoch_seconds(before + 15_000)..Robin.epoch_seconds(Robin.now_ms + 15_000), item["at"]
      assert_equal 1, @errors.size
      ex, ctx = @errors.first

      assert_instance_of ArgumentError, ex
      assert_equal "robin_retry_in returned #{value.inspect}; expected seconds (>= 0), :discard, :kill or nil", ex.message
      assert_equal({context: "robin_retry_in block", job: item}, ctx)
    end
  end

  def test_retry_in_zero_and_false
    Hooked.retry_in = ->(*) { 0 }
    item = payload
    before = Robin.now_ms
    @retrier.handle(unit_for(item), item, Hooked, error)

    assert_includes Robin.epoch_seconds(before)..Robin.epoch_seconds(Robin.now_ms), item["at"]
    Hooked.retry_in = ->(*) { false }
    item = payload
    with_rand(0.5) { @retrier.handle(unit_for(item), item, Hooked, error) }

    assert_in_delta Robin.epoch_seconds(Robin.now_ms + 15_000), item["at"], 2
    assert_empty @errors
  end

  def test_die_runs_hooks_and_handlers
    seen = []
    Hooked.exhausted = ->(job, ex) { seen << [:exhausted, job["jid"], ex.message] }
    config.death_handlers << ->(job, ex) { seen << [:death, job["jid"], ex.message] }
    config.death_handlers << ->(_job, _ex) { raise "handler failed" }
    config.death_handlers << ->(job, _ex) { seen << [:after, job["jid"]] }
    item = payload(retry_count: 0)
    @retrier.die(unit_for(item), item, Hooked, error)

    assert_equal [[:exhausted, "j1", "boom"], [:death, "j1", "boom"], [:after, "j1"]], seen
    assert_equal ["j1"], dead.map { |d| d["jid"] }
    assert_empty inflight
    ex, ctx = @errors.last

    assert_equal "handler failed", ex.message
    assert_equal({context: "death handler", job: item}, ctx)
  end

  def test_failing_exhausted_hook_is_reported
    Hooked.exhausted = ->(*) { raise "hook failed" }
    item = payload
    @retrier.die(unit_for(item), item, Hooked, error)

    assert_equal 1, dead.size
    ex, ctx = @errors.last

    assert_equal "hook failed", ex.message
    assert_equal({context: "retries_exhausted hook", job: item}, ctx)
  end

  def test_dead_false_only_acknowledges
    item = payload(dead: false)
    unit = unit_for(item)
    @retrier.die(unit, item, Plain, error)

    assert_empty dead
    assert_empty inflight
    @retrier.die(nil, payload(dead: false), Plain, error)

    assert_empty dead
  end

  def test_die_without_unit_still_records
    @retrier.die(nil, payload, Plain, error)

    assert_equal ["j1"], dead.map { |d| d["jid"] }
  end

  # A batch with one pending job, "j1".
  def batch_of_one
    batch = Robin::Batch.new(config: config)
    batch.jobs { batch.register("j1") }
    batch
  end

  # The commands of +pool+'s transactions, scripts by name.
  def transactions(pool)
    names = {Robin::Scripts::RELEASE => :release, Robin::Batch::UPDATE => :update, Robin::Batch::MARK_DEATH => :mark_death}
    trips = pool.calls.slice_before { |c| c[0] != :tx }.select { |trip| trip.first == [:multi] }
    trips.map { |trip| trip.drop(1).map { |c| (c[1] == :evalsha) ? [names.fetch(c[2]), *c.drop(3)] : c.drop(1) } }
  end

  def callbacks = redis("LRANGE", config.key("queue", "default"), 0, -1).map { |raw| JSON.parse(raw).fetch("args") }.reverse

  def update_args(argv) = argv.values_at(0, 1, 3, 4)

  def test_batch_jobs_notify_their_batch
    pool = recording_pool { @retrier.die(nil, payload(bid: nil), Plain, error) }

    assert_equal [%w[ZADD ZREMRANGEBYSCORE ZREMRANGEBYRANK]], transactions(pool).map { |tx| tx.map(&:first) }
    item = payload(retry: 0)
    @retrier.handle(unit_for(item), item, Plain, error)

    assert_empty callbacks, "no batch, no callbacks"
    batch = batch_of_one
    item = payload(bid: batch.bid)
    pool = recording_pool { @retrier.die(nil, item, Plain, error) }
    (*, update, mark_death), = transactions(pool)

    assert_equal [:update, Robin::Batch.tracking_keys(config, batch.bid)], update.take(2)
    assert_equal ["failure", "j1", '{"error_class":"RuntimeError","error_message":"boom"}', Robin::Batch::TTL], update_args(update.last)
    assert_equal [:mark_death, [config.key("b", batch.bid)]], mark_death.take(2)
    assert_equal [[batch.bid, "complete"], [batch.bid, "death"]], callbacks
    assert_equal [1, 1], [batch.status.pending, batch.status.failures]
    assert_predicate batch.status, :dead?
  end

  # Into the dead set, acknowledged, the unique lock given up and the
  # batch told: one round trip.
  def test_a_dying_job_is_recorded_in_one_transaction
    batch = batch_of_one
    lock = config.key("unique", "d1")
    redis("SET", lock, "j1")
    item = payload(retry: 0, bid: batch.bid, unique_digest: "d1")
    unit = unit_for(item)
    pool = recording_pool { assert_equal :dead, @retrier.handle(unit, item, Plain, error) }
    tx, = transactions(pool)

    assert_equal ["ZADD", "ZREMRANGEBYSCORE", "ZREMRANGEBYRANK", ["DEL", unit.key], ["SREM", @fetcher.inflight_key, unit.key],
      [:release, [lock], ["j1"]], :update, :mark_death], tx.map { |c| (%w[DEL SREM].include?(c[0]) || c[0] == :release) ? c : c[0] }
    assert_equal 1, pool.calls.count { |c| c == [:multi] }
    assert_equal ["j1"], dead.map { |d| d["jid"] }
    assert_empty inflight
    assert_equal 0, redis("EXISTS", lock)
    assert_equal [[batch.bid, "complete"], [batch.bid, "death"]], callbacks
  end

  def test_a_discarded_job_is_recorded_in_one_transaction
    batch = batch_of_one
    item = payload(retry: false, bid: batch.bid)
    unit = unit_for(item)
    pool = recording_pool { assert_equal :discard, @retrier.handle(unit, item, Plain, error) }

    assert_equal [[["DEL", unit.key], ["SREM", @fetcher.inflight_key, unit.key], :update, :mark_death]],
      transactions(pool).map { |tx| tx.map { |c| %w[DEL SREM].include?(c[0]) ? c : c[0] } }
    assert_empty dead
    assert_empty inflight
    assert_equal [[batch.bid, "complete"], [batch.bid, "death"]], callbacks
  end

  # The failure the batch middleware held back goes with the retry.
  def test_a_retried_batch_job_records_its_failure_with_the_retry
    batch = batch_of_one
    item = payload(bid: batch.bid)
    unit = unit_for(item)
    held = {"error_class" => "E", "error_message" => "m"}
    pool = recording_pool { with_rand(0.5) { @retrier.handle(unit, item, Plain, error, batch_failure: held) } }
    (update, zadd, del, srem), = transactions(pool)

    assert_equal [:update, Robin::Batch.tracking_keys(config, batch.bid)], update.take(2)
    assert_equal ["failure", "j1", '{"error_class":"E","error_message":"m"}', Robin::Batch::TTL], update_args(update.last)
    assert_equal [["ZADD", config.key("retry")], ["DEL", unit.key], ["SREM", @fetcher.inflight_key, unit.key]], [zadd.take(2), del, srem]
    assert_equal [:multi], pool.calls.first
    assert_equal [[batch.bid, "complete"]], callbacks
    assert_equal({"j1" => '{"error_class":"E","error_message":"m"}'}, redis("HGETALL", Robin::Batch.tracking_keys(config, batch.bid).last).each_slice(2).to_h)
    assert_equal :retry, @retrier.handle(unit_for(item), item, Plain, error)
    assert_equal [[batch.bid, "complete"]], callbacks
  end

  # -- what gets written back ---------------------------------------------------

  def from_redis(item)
    unit = unit_for(item)
    [unit, Robin.remember_raw(JSON.parse(unit.raw), unit.raw)]
  end

  def test_retries_store_the_job_as_it_was_not_as_mutated
    unit, item = from_redis(payload(args: [{"token" => "secret"}], at: 1_700_000_000.0, enqueued_at: 1_700_000_000_000))
    item.fetch("args").first.delete("token") # the job changed its own arguments
    item["note"] = "set by middleware"
    @retrier.handle(unit, item, Plain, error)
    stored, score = retries.first

    assert_equal [{"token" => "secret"}], stored.fetch("args")
    refute stored.key?("note")
    assert_equal ["RuntimeError", "boom", 0], stored.values_at("error_class", "error_message", "retry_count")
    # The score says when; the stored job has neither time.
    assert_in_delta item.fetch("at"), score, 0.0
    refute stored.key?("at")
    refute stored.key?("enqueued_at")
  end

  def test_dead_jobs_store_the_job_as_it_was_not_as_mutated
    unit, item = from_redis(payload(args: ["original"], retry: 0, at: 1_700_000_000.0, enqueued_at: 1_700_000_000_000))
    item["args"] = ["changed"]
    @retrier.handle(unit, item, Plain, error)

    assert_equal [["original"]], dead.map { |d| d.fetch("args") }
    assert_equal [0], dead.map { |d| d.fetch("retry_count") }
    assert_equal [[nil, nil]], dead.map { |d| d.values_at("at", "enqueued_at") }
  end

  def test_failure_fields_are_the_only_ones_merged
    assert_equal %w[error_class error_message error_backtrace failed_at retried_at retry_count discarded_at],
      Robin::Retrier::FAILURE_FIELDS
  end

  # -- discarding ------------------------------------------------------------------

  def death_log
    seen = []
    config.death_handlers << ->(job, ex) { seen << [job.fetch("jid"), job["discarded_at"].is_a?(Integer), ex.message] }
    seen
  end

  def test_retry_false_runs_death_handlers_with_discarded_at
    seen = death_log
    item = payload(retry: false)

    assert_equal :discard, @retrier.handle(unit_for(item), item, Plain, error)
    assert_equal [["j1", true, "boom"]], seen
    assert_empty dead
  end

  def test_discard_from_retry_in_runs_death_handlers
    seen = death_log
    Hooked.retry_in = ->(*) { :discard }
    item = payload

    assert_equal :discard, @retrier.handle(unit_for(item), item, Hooked, error)
    assert_equal [["j1", true, "boom"]], seen
    assert_empty inflight
  end

  def test_exhausted_hook_may_discard_instead_of_killing
    seen = death_log
    Hooked.exhausted = ->(*) { :discard }
    item = payload(retry: 0)

    assert_equal :discard, @retrier.handle(unit_for(item), item, Hooked, error)
    assert_empty dead
    assert_empty inflight
    assert_equal [["j1", true, "boom"]], seen
  end

  def test_killed_jobs_have_no_discarded_at
    seen = death_log
    item = payload(retry: 0)
    @retrier.handle(unit_for(item), item, Plain, error)

    assert_equal [["j1", false, "boom"]], seen
    refute dead.first.key?("discarded_at")
  end

  def test_discarded_batch_jobs_tell_their_batch
    batch = batch_of_one
    item = payload(retry: false, bid: batch.bid)
    @retrier.handle(unit_for(item), item, Plain, error("gone"))

    assert_equal({"j1" => '{"error_class":"RuntimeError","error_message":"gone"}'},
      redis("HGETALL", Robin::Batch.tracking_keys(config, batch.bid).last).each_slice(2).to_h)
    assert_predicate batch.status, :dead?
    assert_kind_of Integer, item.fetch("discarded_at")
  end

  def test_custom_delays_are_jittered_when_scheduling
    Hooked.retry_in = ->(*) { 100 }
    item = payload
    before = Robin.now_ms
    with_rand(0.5) { @retrier.handle(unit_for(item), item, Hooked, error) }

    assert_in_delta Robin.epoch_seconds(before + 105_000), item.fetch("at"), 1
  end
end
