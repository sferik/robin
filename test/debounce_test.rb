# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class DebouncedJob
  include Robin::Job

  robin_options debounce: 30
  def perform(*) = nil
end

class DebounceTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Debounce*"

  def client_mw = Robin::Debounce::ClientMiddleware.new.tap { |m| m.config = config }

  def server_mw = Robin::Debounce::ServerMiddleware.new.tap { |m| m.config = config }

  def digest(args, klass: "DebouncedJob", queue: "default")
    Digest::SHA256.hexdigest(JSON.generate([klass, queue, Robin::Unique.canonical(args)]))
  end

  def key(name) = "#{key_prefix_for_test}#{name}"

  def claim_on(payload) = payload.instance_variable_get(Robin::Debounce::CLAIM_IVAR)

  # Makes the claim the push of +payload+ would.
  def claim(payload) = config.redis { |c| c.pipelined { |p| Robin::Debounce.queue_claims(p, [payload]) } }

  def schedule(payload)
    redis("ZADD", "#{key_prefix_for_test}schedule", payload["at"], JSON.generate(payload))
  end

  def test_passes_through_without_option
    payload = {"args" => [1], "jid" => "j"}

    assert_equal :pushed, client_mw.call("DebouncedJob", payload, "default", nil) { :pushed }
    assert_equal({"args" => [1], "jid" => "j"}, payload)
    redis("SET", "#{key_prefix_for_test}debounce:", "1|someone-else") # must not be consulted
    runs = 0

    assert_equal :ran, server_mw.call(nil, payload, "default") {
      runs += 1
      :ran
    }
    assert_equal 1, runs
  end

  def test_client_middleware_schedules_and_leaves_its_claim_to_the_push
    before = Robin.now_ms
    payload = {"args" => [1, {"b" => 1, "a" => 2}], "jid" => "j1", "debounce" => 1000.5004}

    assert_roundtrips(0) { assert_equal :pushed, client_mw.call("DebouncedJob", payload, "default", nil) { :pushed } }
    assert_kind_of Float, payload["at"]
    assert_equal payload["at"], Robin.epoch_seconds(Robin.epoch_ms(payload["at"])), "to the whole millisecond"
    assert_includes Robin.epoch_seconds(before + 1_000_500)..Robin.epoch_seconds(Robin.now_ms + 1_000_500), payload["at"]
    d = digest([1, {"a" => 2, "b" => 1}])

    assert_equal d, payload["debounce_key"]
    keys, (token, expiry) = claim_on(payload)

    assert_equal ["#{key_prefix_for_test}debounce:#{d}", "#{key_prefix_for_test}schedule"], keys
    assert_equal ["#{payload["at"]}|j1", Robin.epoch_ms(payload["at"]) + 600_000], [token, expiry]
    refute_includes JSON.generate(payload), token, "the claim isn't part of the job"
    pool = recording_pool { assert_roundtrips(1) { claim(payload) } }

    assert_equal [[:pipelined], [:pipe, :evalsha, Robin::Debounce::CLAIM, keys, [token, expiry]]], pool.calls
    assert_equal "#{payload["at"]}|j1", redis("GET", keys.first)
    # (PEXPIRETIME needs Redis 7.)
    assert_in_delta expiry - Robin.now_ms, redis("PTTL", keys.first), 1_000
  end

  def test_a_debounced_push_takes_one_round_trip
    jid = assert_roundtrips(1) { DebouncedJob.perform_async(1) }

    assert_equal jid, claim_of([1]).split("|").last
    assert_equal [jid], scheduled_jids
  end

  def test_a_push_a_later_middleware_stops_makes_no_claim
    earlier = DebouncedJob.perform_async(1)
    config.client_middleware.add(Class.new { def call(*) = nil })

    assert_nil DebouncedJob.perform_async(1)
    assert_equal [earlier], scheduled_jids, "the earlier job stays scheduled"
    assert_equal earlier, claim_of([1]).split("|").last
  end

  def test_the_claim_follows_a_payload_a_later_middleware_replaces
    config.client_middleware.add(Class.new { def call(_c, payload, *) = yield && {**payload, "tag" => 1} })
    earlier = DebouncedJob.perform_async(1)
    later = DebouncedJob.perform_async(1)

    assert_equal [later], scheduled_jids, "the earlier #{earlier} went"
    assert_equal later, claim_of([1]).split("|").last
  end

  def test_carry_moves_only_a_claim_there_is_to_another_payload
    claimed = {}
    claimed.instance_variable_set(Robin::Debounce::CLAIM_IVAR, [%w[k], %w[t]])
    other = {}
    Robin::Debounce.carry(claimed, nil)
    Robin::Debounce.carry(claimed, claimed)
    Robin::Debounce.carry({}, other)

    refute other.instance_variable_defined?(Robin::Debounce::CLAIM_IVAR)
    Robin::Debounce.carry(claimed, other)

    assert_equal [%w[k], %w[t]], claim_on(other)
  end

  def test_only_debounced_payloads_are_looked_at_for_claims
    marked = {"debounce_key" => "d"}
    unmarked = {}
    unmarked.instance_variable_set(Robin::Debounce::CLAIM_IVAR, [%w[k], %w[t]])

    assert_roundtrips(0) { claim(marked) && claim(unmarked) }
    assert_nil redis("GET", "k")
    debounced = {"debounce_key" => "d"}
    debounced.instance_variable_set(Robin::Debounce::CLAIM_IVAR, [[key("claimed"), key("schedule")], ["1|j", Robin.now_ms + 60_000]])
    config.redis { |c| c.pipelined { |p| Robin::Debounce.queue_claims(p, [{}, unmarked, debounced]) } }

    assert_equal "1|j", redis("GET", key("claimed")), "the ones after a job without a claim are made"
  end

  def test_digest_depends_on_class_queue_and_args
    a = {"args" => [1], "jid" => "a", "debounce" => 1}
    b = {"args" => [1], "jid" => "b", "debounce" => 1}
    c = {"args" => [2], "jid" => "c", "debounce" => 1}
    client_mw.call("DebouncedJob", a, "default", nil) { nil }
    client_mw.call("DebouncedJob", b, "other", nil) { nil }
    client_mw.call("OtherJob", c, "default", nil) { nil }

    assert_equal [digest([1]), digest([1], queue: "other"), digest([2], klass: "OtherJob")],
      [a, b, c].map { |p| p["debounce_key"] }
  end

  def test_an_earlier_explicit_schedule_is_pushed_back
    before = Robin.now_ms
    payload = {"args" => [1], "jid" => "j", "debounce" => 30, "at" => Robin.epoch_seconds(before + 1_000)}
    client_mw.call("DebouncedJob", payload, "default", nil) { nil }

    assert_includes Robin.epoch_seconds(before + 30_000)..Robin.epoch_seconds(Robin.now_ms + 30_000), payload["at"]
  end

  def test_keeps_a_later_explicit_schedule
    at = Robin.epoch_seconds(Robin.now_ms + 3_600_000)
    payload = {"args" => [1], "jid" => "j", "debounce" => 30, "at" => at}
    client_mw.call("DebouncedJob", payload, "default", nil) { nil }

    assert_equal at, payload["at"]
    assert_equal "#{at}|j", claim_on(payload).last.first
  end

  def test_later_push_removes_only_the_previous_scheduled_job
    first = {"class" => "DebouncedJob", "args" => [1], "jid" => "first", "debounce" => 30}
    client_mw.call("DebouncedJob", first, "default", nil) { nil }
    claim(first)
    schedule(first)
    same_score_other_jid = first.merge("jid" => "bystander")
    schedule(same_score_other_jid)
    elsewhere = first.merge("at" => first["at"] + 1)
    schedule(elsewhere)

    second = {"class" => "DebouncedJob", "args" => [1], "jid" => "second", "debounce" => 30}
    client_mw.call("DebouncedJob", second, "default", nil) { nil }
    claim(second)
    left = redis("ZRANGE", "#{key_prefix_for_test}schedule", 0, -1).map { |r| JSON.parse(r)["jid"] }.sort

    assert_equal %w[bystander first], left # "first" at a different score stays; same-score "first" removed
    assert_equal 1, redis("ZCARD", "#{key_prefix_for_test}schedule") - 1
    assert_equal "#{second["at"]}|second", redis("GET", "#{key_prefix_for_test}debounce:#{digest([1])}")
  end

  def test_server_middleware_skips_superseded_jobs
    log = StringIO.new
    config.logger = Logger.new(log)
    key = "#{key_prefix_for_test}debounce:dk"
    redis("SET", key, "123|latest")

    assert_equal :ran, server_mw.call(nil, {"debounce_key" => "dk", "jid" => "latest"}, "q") { :ran }
    ran = false

    assert_nil server_mw.call(nil, {"debounce_key" => "dk", "jid" => "old", "class" => "DebouncedJob"}, "q") { ran = true }
    refute ran
    assert_includes log.string, "skipping DebouncedJob jid=old: superseded by a later push"
    redis("DEL", key)

    assert_equal :ran, server_mw.call(nil, {"debounce_key" => "dk", "jid" => "old"}, "q") { :ran }
  end

  def test_superseded_jobs_are_events
    events = []
    config.event_handlers << ->(name, payload) { events << [name, payload] }
    redis("SET", "#{key_prefix_for_test}debounce:dk", "123|latest")
    server_mw.call(nil, {"debounce_key" => "dk", "jid" => "latest"}, "q") { :ran }
    old = {"debounce_key" => "dk", "jid" => "old", "class" => "DebouncedJob"}
    server_mw.call(nil, old, "q") { :ran }

    assert_equal [["job.skipped", {job: old, reason: "superseded"}]], events
  end

  def test_server_middleware_compares_the_whole_jid
    redis("SET", "#{key_prefix_for_test}debounce:dk", "1|a|b")

    assert_equal :ran, server_mw.call(nil, {"debounce_key" => "dk", "jid" => "a|b"}, "q") { :ran }
  end

  # -- push_bulk makes its jobs' claims with them -----------------------------------

  def claim_of(args) = redis("GET", "#{key_prefix_for_test}debounce:#{digest(args)}")

  def scheduled_jids = Robin::ScheduledSet.new.map(&:jid)

  def bulk(args) = Robin::Client.new.push_bulk("class" => DebouncedJob, "args" => args, "jids" => args.each_index.map { |i| "j#{i}" })

  def test_push_bulk_makes_its_claims_in_order_in_the_round_trip_that_pushes
    earlier = DebouncedJob.perform_async(1)
    jids = nil
    pool = recording_pool { jids = assert_roundtrips(1) { bulk([[1], [2], [1]]) } }

    assert_equal %w[j0 j1 j2], jids
    assert_equal [[:pipelined, [:evalsha, :evalsha, :evalsha, "ZADD"]]],
      pool.calls.slice_before { |c| c[0] != :pipe }.map { |trip| [trip.first.first, trip.drop(1).map { |c| c[1] }] }
    assert_equal %w[j0 j1 j2], scheduled_jids.sort, "the earlier #{earlier} went"
    assert_equal "j2", claim_of([1]).split("|").last
    assert_equal "j1", claim_of([2]).split("|").last
    runs = Robin::ScheduledSet.new.select { |e| server_mw.call(nil, e.item, "default") { :ran } == :ran }.map(&:jid)

    assert_equal %w[j1 j2], runs.sort
  end

  def test_push_bulk_that_raises_makes_no_claims
    config.client_middleware.add(Class.new { def call(_c, payload, *) = (payload["jid"] == "j1") ? raise("boom") : yield })

    assert_raises(RuntimeError) { bulk([[1], [2], [3]]) }
    assert_equal [nil] * 3, [[1], [2], [3]].map { |args| claim_of(args) }
    assert_empty scheduled_jids
  end

  def test_a_push_made_during_push_bulk_claims_right_away
    test = self
    seen = []
    config.client_middleware.add(Class.new do
      define_method(:call) do |_c, payload, *, &blk|
        if payload["jid"] == "j0"
          Robin::Client.new.push("class" => DebouncedJob, "args" => [9], "jid" => "nested")
          seen << test.claim_of([9])
        end
        blk.call
      end
    end)
    bulk([[1]])

    assert_match(/\|nested\z/, seen.first)
  end

  def test_burst_collapses_to_last_push
    jids = Array.new(5) { DebouncedJob.perform_async(1) }

    assert_predicate jids, :all?
    set = Robin::ScheduledSet.new

    assert_equal 1, set.size
    entry = set.first

    assert_equal jids.last, entry.jid
    assert_in_delta Time.now + 30, entry.at, 2
    DebouncedJob.perform_async(2)

    assert_equal 2, set.size
  end

  def test_concurrent_pushes_run_exactly_once
    pushers = Array.new(10) do
      Thread.new do
        Thread.current.report_on_exception = false
        5.times { DebouncedJob.perform_async("x") }
        nil
      rescue => e
        e
      end
    end
    errors = pushers.map(&:value)
    runs = Robin::ScheduledSet.new.count { |e| server_mw.call(nil, e.item, "default") { :ran } == :ran }

    assert_equal [nil] * 10, errors
    assert_equal 1, runs
  end

  def test_client_middleware_only_applies_to_debounced_jobs
    middleware = Robin::Debounce::ClientMiddleware

    assert_true middleware.applies?(nil, {"debounce" => 5}, "q", nil)
    assert_false middleware.applies?(nil, {"jid" => "j"}, "q", nil)
  end

  def test_server_middleware_only_applies_to_debounced_jobs
    middleware = Robin::Debounce::ServerMiddleware

    assert_true middleware.applies?(nil, {"debounce_key" => 1}, "q")
    assert_false middleware.applies?(nil, {"jid" => "j"}, "q")
  end
end

# End-to-end; left out of mutant's selection (needs a server).
class DebounceIntegrationTest < RobinTest
  def test_runs_end_to_end_once
    config.heartbeat_interval = 0.2
    config.poll_interval = 0.1
    DebouncedJob.robin_options(debounce: 0.3)
    ran = Queue.new
    DebouncedJob.define_method(:perform) { |*a| ran << a }
    Robin.server!
    launcher = Robin::Launcher.new(config).run
    Array.new(4) { Thread.new { 3.times { DebouncedJob.perform_async("y") } } }.each(&:join)

    assert_equal ["y"], Timeout.timeout(5) { ran.pop }
    sleep 1

    assert_equal 0, ran.size
  ensure
    DebouncedJob.robin_options(debounce: 30)
    DebouncedJob.define_method(:perform) { |*| nil }
    launcher&.stop
  end
end
