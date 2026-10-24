# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class PeriodicJob
  include Robin::Job

  robin_options queue: "cron", retry: 3
  def perform(*) = nil
end

class PeriodicUnitTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Periodic*"

  def periodic = Robin::Periodic

  def key(*parts) = config.key("periodic", *parts)

  def setup_entries(*registrations)
    registry = Robin::Periodic::Registry.new
    ids = registrations.map do |registration|
      args, opts = registration
      registry.register(*args, **(opts || {}))
    end
    entries = registry.entries
    crons = entries.to_h { |id, e| [id, Robin::Cron.new(e["cron"], tz: e["tz"])] }
    [ids, entries, crons]
  end

  def store(entries, armed_at)
    entries.each do |id, e|
      redis("HSET", key, id, JSON.generate(e))
      redis("HSET", key("armed"), id, armed_at)
    end
  end

  # -- registry ----------------------------------------------------------------

  def test_register
    registry = Robin::Periodic::Registry.new
    id = registry.register("*/5 * * * *", PeriodicJob, queue: :low, args: [1, "a"], tz: "UTC",
      description: "every five", retry: false, tags: ["x"])

    assert_equal Digest::SHA1.hexdigest(JSON.generate(["*/5 * * * *", "PeriodicJob", "low", [1, "a"], "UTC"]))[0, 12], id
    assert_equal({id => {"cron" => "*/5 * * * *", "class" => "PeriodicJob", "queue" => "low", "args" => [1, "a"],
                         "tz" => "UTC", "description" => "every five", "options" => {"retry" => false, "tags" => ["x"]}}},
      registry.entries)
  end

  def test_register_defaults_and_ids
    registry = Robin::Periodic::Registry.new
    a = registry.register("@hourly", "SomeJob")
    b = registry.register("@hourly", "SomeJob", queue: "q")
    c = registry.register("@hourly", "SomeJob", args: [2])
    d = registry.register("@hourly", "SomeJob", tz: "UTC")
    e = registry.register("@daily", "SomeJob")

    assert_equal 5, [a, b, c, d, e].uniq.size
    assert_equal({"cron" => "@hourly", "class" => "SomeJob", "queue" => nil, "args" => [], "tz" => nil,
                  "description" => nil, "options" => {}}, registry.entries[a])
    assert_equal a, registry.register("@hourly", :SomeJob)
  end

  def test_register_validates
    registry = Robin::Periodic::Registry.new
    assert_raises(Robin::Cron::ParseError) { registry.register("bogus", "X") }
    assert_raises(Robin::Cron::ParseError) { registry.register("* * * * *", "X", tz: "Nowhere/Land") }
    assert_empty registry.entries
    problems = []
    lenient = Robin::Periodic::Registry.new(problems)

    assert_nil lenient.register("bogus", "X")
    assert_empty lenient.entries
    assert_equal ['X: cron expression must have 5 or 6 fields: "bogus"'], problems
  end

  # -- tick --------------------------------------------------------------------

  # -- verify! -------------------------------------------------------------------

  class NotAJob; end

  module Performs
    def self.perform_later = nil
  end

  class LaterJob
    def self.perform_later = nil
  end

  def test_verify_returns_good_entries
    entries = periodic.verify! do |cron|
      cron.register "*/5 * * * *", "PeriodicJob", args: [1, "a", {"k" => [nil, true, 1.5]}]
      cron.register "0 3 * * *", PeriodicUnitTest::LaterJob, tz: "UTC"
    end

    assert_equal [["PeriodicJob", [1, "a", {"k" => [nil, true, 1.5]}]], ["PeriodicUnitTest::LaterJob", []]],
      entries.values.map { |e| e.values_at("class", "args") }
  end

  def test_verify_lists_every_problem
    error = assert_raises(Robin::Periodic::Invalid) do
      periodic.verify! do |cron|
        cron.register "nope", "PeriodicJob"
        cron.register "0 3 * * *", "PeriodicJob", tz: "Mars/Olympus"
        cron.register "0 4 * * *", "MissingJob"
        cron.register "0 5 * * *", "lowercase"
        cron.register "0 6 * * *", "PeriodicUnitTest::NotAJob"
        cron.register "0 7 * * *", "PeriodicUnitTest::Performs"
        cron.register "0 8 * * *", "PeriodicJob", args: "x"
        cron.register "0 9 * * *", "PeriodicJob", args: [:sym, {a: 1}]
      end
    end

    assert_equal <<~MSG.chomp, error.message
      periodic jobs have problems:
        PeriodicJob: cron expression must have 5 or 6 fields: "nope"
        PeriodicJob: unknown time zone "Mars/Olympus"
        MissingJob: no such class
        lowercase: no such class
        PeriodicUnitTest::NotAJob: not a job class
        PeriodicUnitTest::Performs: not a job class
        PeriodicJob: args must be an Array
        PeriodicJob: args [:sym, {a: 1}] change in JSON
    MSG
    assert_kind_of Robin::Error, error
  end

  def test_verify_checks_a_configs_blocks
    alt = Robin::Config.new
    alt.periodic { |cron| cron.register "0 3 * * *", "PeriodicJob" }
    alt.periodic { |cron| cron.register "0 4 * * *", "MissingJob" }
    error = assert_raises(Robin::Periodic::Invalid) { periodic.verify!(alt) }

    assert_equal "periodic jobs have problems:\n  MissingJob: no such class", error.message
    config.periodic { |cron| cron.register "0 3 * * *", "PeriodicJob" }

    assert_equal ["PeriodicJob"], periodic.verify!.values.map { |e| e["class"] }
    assert_empty periodic.verify!(Robin::Config.new)
  end

  def test_tick_enqueues_the_latest_due_tick_once
    ids, entries, crons = setup_entries([["*/10 * * * * *", PeriodicJob], {args: [7]}])
    store(entries, 0)
    now = Time.at(1_800_000_005, 500, :millisecond)
    jids = periodic.tick(config, entries, crons, now)

    assert_equal 1, jids.size
    job = Robin::Queue.new("cron").first

    assert_equal [jids.first, "PeriodicJob", [7], ids.first, 3], [job.jid, job.klass, job.args, job["periodic"], job["retry"]]
    assert_equal [{"at" => 1_800_000_000_000, "jid" => jids.first}], periodic.history(ids.first, config: config)
    claim = key(ids.first, "t", 1_800_000_000_000)

    assert_equal "1", redis("GET", claim)
    # A week past the next tick (4.5s away; TTLs count whole seconds).
    assert_includes 604_804..604_805, redis("TTL", claim)
    assert_empty periodic.tick(config, entries, crons, now)
    assert_empty periodic.tick(config, entries, crons, now + 4)
    assert_equal 1, periodic.tick(config, entries, crons, now + 5).size
  end

  def test_a_claim_outlives_its_tick_being_the_latest
    ids, entries, crons = setup_entries([["0 0 1 * *", PeriodicJob], {tz: "UTC"}])
    store(entries, 0)
    now = Time.utc(2027, 1, 3, 12) # the latest tick was 2.5 days ago; the next is 28.5 days away

    assert_equal 1, periodic.tick(config, entries, crons, now).size
    claim = key(ids.first, "t", Time.utc(2027, 1, 1).to_i * 1000)

    assert_includes 3_067_199..3_067_200, redis("TTL", claim) # 28.5 days + a week
    redis("EXPIRE", claim, 1) # as it would be, a week on, with a week's TTL
    sleep 1.1

    assert_equal 1, periodic.tick(config, entries, crons, now + 8 * 86_400).size, "without the claim it runs again"
  end

  def test_a_claim_keeps_the_minimum_ttl_without_a_next_tick
    ids, entries, crons = setup_entries([["*/10 * * * * *", PeriodicJob]])
    store(entries, 0)
    crons.each_value { |cron| cron.define_singleton_method(:next_time) { |_from| nil } }
    periodic.tick(config, entries, crons, Time.at(1_800_000_005))

    assert_includes 604_799..604_800, redis("TTL", key(ids.first, "t", 1_800_000_000_000))
  end

  def test_list_shows_the_latest_run_or_with_history_the_latest_runs_and_options
    ids, entries, = setup_entries([["0 0 1 1 *", PeriodicJob], {args: [1], retry: 2}], [["0 0 1 1 *", PeriodicJob]])
    store(entries, 0)
    first = periodic.enqueue_now(ids[0])
    second = periodic.enqueue_now(ids[0])
    plain = assert_roundtrips(2) { periodic.list(config: config) }.to_h { |job| [job["id"], job] }

    assert_equal [second, nil], ids.map { |id| plain.fetch(id)["last_jid"] }
    refute plain.fetch(ids[0]).key?("history")
    detailed = periodic.list(config: config, history: 2).to_h { |job| [job["id"], job] }

    assert_equal [second, first], detailed.fetch(ids[0])["history"].map { |run| run["jid"] }
    assert_equal({"retry" => 2}, detailed.fetch(ids[0])["options"])
    assert_equal [second], periodic.list(config: config, history: 1).find { |job| job["id"] == ids[0] }["history"].map { |run| run["jid"] }
    assert_empty detailed.fetch(ids[1])["history"]
  end

  def test_enqueue_now_pushes_the_job_with_its_options_and_records_it
    ids, entries, = setup_entries([["0 0 1 1 *", PeriodicJob], {args: [7], retry: 2}])
    store(entries, 0)
    jid = assert_roundtrips(3) { periodic.enqueue_now(ids[0], config: config) } # the definition, the push, the history
    job = Robin::Queue.new("cron", config: config).first

    assert_equal [jid, [7], 2, ids[0]], [job.jid, job.args, job["retry"], job["periodic"]]
    assert_equal [[jid, true]], periodic.history(ids[0], config: config).map { |run| run.values_at("jid", "manual") }
  end

  def test_remembered_claims_spare_round_trips
    ids, entries, crons = setup_entries([["*/10 * * * * *", PeriodicJob]], [["*/10 * * * * *", PeriodicJob], {args: [1]}])
    store(entries, 0)
    redis("SET", key(ids[1], "t", 1_800_000_000_000), "1") # claimed by someone else
    claimed = {}
    commands = recorded { assert_equal 1, assert_roundtrips(3) { periodic.tick(config, entries, crons, Time.at(1_800_000_005), claimed) }.size }

    assert_equal({ids[0] => 1_800_000_000_000, ids[1] => 1_800_000_000_000}, claimed)
    # Both entries' claims, the first one's push, its history.
    assert_equal [Robin::Periodic::CLAIM, "SADD", "LPUSH", "LPUSH", "LTRIM"], commands
    commands = recorded { assert_empty assert_roundtrips(0) { periodic.tick(config, entries, crons, Time.at(1_800_000_009), claimed) } }

    assert_empty commands, "both tried already: no round trip"
    claimed.delete(ids[1])

    assert_equal [Robin::Periodic::CLAIM], recorded { assert_empty periodic.tick(config, entries, crons, Time.at(1_800_000_009), claimed) }
    assert_equal 2, assert_roundtrips(3) { periodic.tick(config, entries, crons, Time.at(1_800_000_010), claimed) }.size
  end

  def test_unclaimed_ticks_are_not_remembered
    ids, entries, crons = setup_entries([["*/10 * * * * *", PeriodicJob]], [["*/10 * * * * *", PeriodicJob], {args: [1]}])
    store(entries, 0)
    redis("HSET", key("armed"), ids[0], 1_800_000_000_001)
    redis("SADD", key("paused"), ids[1])
    claimed = {}

    assert_empty periodic.tick(config, entries, crons, Time.at(1_800_000_005), claimed)
    assert_empty claimed
    redis("SREM", key("paused"), ids[1])

    assert_equal 1, periodic.tick(config, entries, crons, Time.at(1_800_000_005), claimed).size
    assert_equal({ids[1] => 1_800_000_000_000}, claimed)
  end

  def test_a_failed_claim_is_not_remembered
    _, entries, crons = setup_entries([["*/10 * * * * *", PeriodicJob]])
    store(entries, 0)
    claimed = {}
    failing = ->(kind, args) { (kind == :evalsha && args.first.equal?(Robin::Periodic::CLAIM)) ? raise(Robin::Redis::ConnectionError, "down") : :forward }

    assert_raises(Robin::Redis::ConnectionError) do
      recording_pool(failing) { periodic.tick(config, entries, crons, Time.at(1_800_000_005), claimed) }
    end
    assert_empty claimed
    assert_equal 1, periodic.tick(config, entries, crons, Time.at(1_800_000_005), claimed).size
  end

  # The commands sent to Redis (alone or in pipelines) while the block runs.
  def recorded(&) = recording_pool(&).calls.filter_map { |kind, command| (kind == :pipelined) ? nil : command }

  def test_tick_counts_a_tick_due_exactly_now
    ids, entries, crons = setup_entries([["*/10 * * * * *", PeriodicJob]])
    store(entries, 0)
    periodic.tick(config, entries, crons, Time.at(1_800_000_010))

    assert_equal 1_800_000_010_000, periodic.history(ids.first, config: config).first["at"]
  end

  def test_tick_skips_ticks_before_arming_paused_and_impossible
    ids, entries, crons = setup_entries([["*/10 * * * * *", PeriodicJob]], [["0 0 30 2 *", PeriodicJob], {args: [1]}],
      [["*/10 * * * * *", PeriodicJob], {args: [2]}])
    store(entries, 1_800_000_000_000)
    redis("HSET", key("armed"), ids[0], 1_800_000_000_001)
    redis("SADD", key("paused"), ids[2])

    assert_empty periodic.tick(config, entries, crons, Time.at(1_800_000_005))
    redis("HSET", key("armed"), ids[0], 1_800_000_000_000)

    assert_equal 1, periodic.tick(config, entries, crons, Time.at(1_800_000_005)).size
  end

  def test_skipped_entries_do_not_stop_the_others
    _, entries, crons = setup_entries([["*/10 * * * * *", PeriodicJob], {args: [1]}], [["0 0 30 2 *", PeriodicJob]],
      [["*/10 * * * * *", PeriodicJob], {args: [2]}], [["*/10 * * * * *", PeriodicJob], {args: [3]}],
      [["*/10 * * * * *", PeriodicJob], {args: [4]}])
    store(entries, 0)
    ids = entries.keys
    redis("HSET", key("armed"), ids[0], 1_800_000_000_001) # armed after the tick
    redis("SADD", key("paused"), ids[2])
    redis("SET", key(ids[3], "t", 1_800_000_000_000), "1") # claimed by someone else
    # the impossible schedule (ids[1]) never has a due tick, even armed at 0
    jids = periodic.tick(config, entries, crons, Time.at(1_800_000_005))

    assert_equal 1, jids.size
    assert_equal [[4]], Robin::Queue.new("cron").map(&:args)
  end

  def test_tick_without_arming_record
    ids, entries, crons = setup_entries([["*/10 * * * * *", PeriodicJob]])
    redis("HSET", key, ids.first, JSON.generate(entries.values.first))

    assert_equal 1, periodic.tick(config, entries, crons, Time.at(1_800_000_005)).size
  end

  def test_tick_defaults_to_now
    _, entries, crons = setup_entries([["* * * * * *", PeriodicJob]])
    store(entries, 0)

    assert_equal 1, periodic.tick(config, entries, crons).size
  end

  def test_unknown_classes_are_pushed_by_name
    ids, entries, crons = setup_entries([["* * * * * *", "Not::Loaded"], {queue: "elsewhere"}], [["* * * * * *", "lowercase"]])
    store(entries, 0)
    periodic.tick(config, entries, crons, Time.at(1_800_000_000))
    job = Robin::Queue.new("elsewhere").first

    assert_equal ["Not::Loaded", ids.first], [job.klass, job["periodic"]]
    assert_equal "lowercase", Robin::Queue.new("default").first.klass
  end

  def test_queue_option_overrides_class_queue
    _, entries, crons = setup_entries([["* * * * * *", PeriodicJob], {queue: "special"}])
    store(entries, 0)
    periodic.tick(config, entries, crons, Time.at(1_800_000_000))

    assert_equal 1, Robin::Queue.new("special").size
    assert_equal 0, Robin::Queue.new("cron").size
  end

  def test_history_is_trimmed_and_limited
    ids, entries, = setup_entries([["* * * * * *", PeriodicJob]])
    store(entries, 0)
    (Robin::Periodic::HISTORY + 3).times { periodic.enqueue_now(ids.first, config: config) }

    assert_equal Robin::Periodic::HISTORY, redis("LLEN", key(ids.first, "h"))
    assert_equal 25, periodic.history(ids.first, config: config).size
    assert_equal 2, periodic.history(ids.first, config: config, limit: 2).size
  end

  # -- enqueue now / pause -----------------------------------------------------

  def test_enqueue_now
    ids, entries, = setup_entries([["0 0 1 1 *", PeriodicJob], {args: [1]}])
    store(entries, 0)
    before = Robin.now_ms
    jid = periodic.enqueue_now(ids.first, config: config)
    record = periodic.history(ids.first, config: config).first

    assert_equal jid, Robin::Queue.new("cron").first.jid
    assert_equal [jid, true], [record["jid"], record["manual"]]
    assert_includes before..Robin.now_ms, record["at"]
    e = assert_raises(ArgumentError) { periodic.enqueue_now("nope", config: config) }
    assert_equal 'no periodic job "nope"', e.message
  end

  def test_pause_and_unpause
    assert_true periodic.pause!("x", config: config)
    assert_equal ["x"], redis("SMEMBERS", key("paused"))
    assert_true periodic.unpause!("x", config: config)
    assert_empty redis("SMEMBERS", key("paused"))
  end

  def test_default_config
    Robin.config = config
    ids, entries, = setup_entries([["0 0 1 1 *", PeriodicJob]])
    store(entries, 0)
    jid = periodic.enqueue_now(ids.first)

    assert_equal jid, periodic.history(ids.first).first["jid"]
    assert periodic.pause!(ids.first)
    assert periodic.list.first["paused"]
    assert periodic.unpause!(ids.first)
  end

  # -- list --------------------------------------------------------------------

  def test_list
    ids, entries, = setup_entries([["0 3 * * *", PeriodicJob], {description: "nightly", args: [1], tz: "UTC"}],
      [["*/5 * * * *", "Other"], {queue: "q"}])
    store(entries, 123)
    periodic.pause!(ids[1], config: config)
    jid = periodic.enqueue_now(ids[0], config: config)
    last_at = periodic.history(ids[0], config: config).first["at"]
    rows = periodic.list(config: config)

    assert_equal ids.sort, rows.map { |r| r["id"] }
    nightly = rows.find { |r| r["id"] == ids[0] }
    other = rows.find { |r| r["id"] == ids[1] }
    next_at = Robin::Cron.new("0 3 * * *", tz: "UTC").next_time

    assert_equal({"id" => ids[0], "cron" => "0 3 * * *", "class" => "PeriodicJob", "queue" => "default", "args" => [1],
                  "tz" => "UTC", "description" => "nightly", "next_at" => next_at.to_i * 1000, "last_at" => last_at,
                  "last_jid" => jid, "paused" => false, "armed_at" => 123}, nightly)
    assert_equal ["q", "every 5 minutes", nil, nil, true], other.values_at("queue", "description", "last_at", "last_jid", "paused")
  end

  def test_list_handles_unparseable_and_unarmed_entries
    redis("HSET", key, "broken", JSON.generate({"cron" => "nonsense", "class" => "X", "args" => []}))
    row = periodic.list(config: config).first

    assert_equal ["broken", nil, "nonsense", nil], row.values_at("id", "next_at", "description", "armed_at")
  end

  def test_list_is_sorted_by_id
    entry = JSON.generate({"cron" => "* * * * *", "class" => "X", "args" => []})
    %w[zeta alpha mid].each { |id| redis("HSET", key, id, entry) }

    assert_equal %w[alpha mid zeta], periodic.list(config: config).map { |row| row.fetch("id") }
  end

  def test_list_shows_the_newest_run
    ids, entries, = setup_entries([["0 0 1 1 *", PeriodicJob]])
    store(entries, 0)
    periodic.enqueue_now(ids.first, config: config)
    newest = periodic.enqueue_now(ids.first, config: config)

    assert_equal newest, periodic.list(config: config).first["last_jid"]
  end

  def test_explicit_config_for_pushes
    other = Robin::Config.new
    other.redis = {url: REDIS_URL}
    other.key_prefix = "#{key_prefix_for_test}other:"
    ids, entries, = setup_entries([["0 0 1 1 *", PeriodicJob]])
    entries.each { |id, e| other.redis { |c| c.call("HSET", other.key("periodic"), id, JSON.generate(e)) } }
    periodic.enqueue_now(ids.first, config: other)

    assert_equal 1, Robin::Queue.new("cron", config: other).size
    assert_equal 0, Robin::Queue.new("cron").size
  ensure
    other&.redis_pool&.shutdown
  end

  def test_list_with_a_schedule_that_never_runs
    _, entries, = setup_entries([["0 0 30 2 *", PeriodicJob]])
    store(entries, 0)

    assert_nil periodic.list(config: config).first["next_at"]
  end

  def test_list_when_empty
    assert_empty periodic.list(config: config)
  end

  # -- attach / loop -----------------------------------------------------------

  FakeLeader = Struct.new(:leader) do
    def leader? = leader
  end

  class FakeLauncher
    attr_reader :config, :leader

    def initialize(config, leader, beats)
      @config = config
      @leader = FakeLeader.new(leader)
      @beats = beats
    end

    def stopping?
      @beats -= 1
      @beats.negative?
    end
  end

  def with_fake_sleep
    sleeps = []
    periodic.define_singleton_method(:sleep) { |s| sleeps << s }
    yield sleeps
  ensure
    periodic.singleton_class.remove_method(:sleep)
  end

  def test_the_loop_remembers_its_claims
    config.periodic { |r| r.register("0 0 1 1 *", "Yearly", tz: "UTC") }
    redis("HSET", key("armed"), Robin::Periodic::Registry.new.register("0 0 1 1 *", "Yearly", tz: "UTC"), 0)
    pool = nil
    with_fake_sleep { pool = recording_pool { periodic.attach(FakeLauncher.new(config, true, 3)).join } }
    claims = pool.calls.select { |kind, script| kind == :evalsha && script.equal?(Robin::Periodic::CLAIM) }

    assert_equal 1, claims.size, "the second and third wakes find this year's tick tried"
    assert_equal 1, Robin::Queue.new("default").size
  end

  def test_attach_writes_registry_and_runs_loop_as_leader
    config.periodic { |r| r.register("* * * * * *", PeriodicJob, args: [1]) }
    config.periodic { |r| r.register("0 0 1 1 *", "Yearly") }
    config.periodic { |r| r.register("0 * * * *", PeriodicJob, args: [2], tz: "+00:30") }
    redis("HSET", key, "stale", "{}")
    every_second = Robin::Periodic::Registry.new.register("* * * * * *", PeriodicJob, args: [1])
    half_hourly = Robin::Periodic::Registry.new.register("0 * * * *", PeriodicJob, args: [2], tz: "+00:30")
    redis("HSET", key("armed"), every_second, 0) # armed long ago
    redis("HSET", key("armed"), half_hourly, 0)
    before = Robin.now_ms
    with_fake_sleep do |sleeps|
      thread = periodic.attach(FakeLauncher.new(config, true, 1))
      thread.join

      assert_equal "robin.periodic", thread.name

      assert_equal 1, sleeps.size
      assert_operator sleeps.first, :<=, 1
    end
    stored = redis("HGETALL", key).each_slice(2).to_h

    assert_equal 3, stored.size
    refute stored.key?("stale")
    assert_equal stored.keys.sort, redis("HKEYS", key("armed")).sort
    assert_equal "0", redis("HGET", key("armed"), every_second)
    yearly = (stored.keys - [every_second, half_hourly]).first

    assert_includes before..Robin.now_ms, redis("HGET", key("armed"), yearly).to_i
    assert_equal({"cron" => "0 0 1 1 *", "class" => "Yearly", "queue" => nil, "args" => [],
                                              "tz" => nil, "description" => nil, "options" => {}}, JSON.parse(stored[yearly]))
    assert_equal 2, Robin::Queue.new("cron").size
    assert_equal 1_800_000, periodic.history(half_hourly, config: config).first["at"] % 3_600_000
  end

  def test_arming_time_is_kept_across_restarts
    config.periodic { |r| r.register("0 0 1 1 *", "Yearly") }
    with_fake_sleep do
      periodic.attach(FakeLauncher.new(config, false, 0)).join
      first = redis("HGETALL", key("armed"))
      redis("HSET", key("armed"), first[0], 1)
      periodic.attach(FakeLauncher.new(config, false, 0)).join

      assert_equal "1", redis("HGET", key("armed"), first[0])
    end
  end

  def test_followers_do_not_enqueue
    config.periodic { |r| r.register("* * * * * *", PeriodicJob) }
    redis("HSET", key("armed"), Robin::Periodic::Registry.new.register("* * * * * *", PeriodicJob), 0)
    with_fake_sleep { periodic.attach(FakeLauncher.new(config, false, 2)).join }

    assert_equal 0, Robin::Queue.new("cron").size
  end

  def test_loop_reports_errors_and_keeps_going
    errors = []
    config.error_handlers.replace([->(e, ctx, _) { errors << [e.message, ctx] }])
    config.periodic { |r| r.register("* * * * * *", PeriodicJob) }
    original = periodic.method(:tick)
    periodic.define_singleton_method(:tick) { |*| raise "boom" }
    with_fake_sleep do |sleeps|
      periodic.attach(FakeLauncher.new(config, true, 2)).join

      assert_equal 2, sleeps.size
    end

    assert_equal [["boom", {context: "periodic jobs"}]] * 2, errors
  ensure
    periodic.define_singleton_method(:tick, original)
  end

  def test_attach_without_entries
    config.periodic { |_r| nil }

    assert_nil periodic.attach(FakeLauncher.new(config, true, 0))
    assert_equal 0, redis("EXISTS", key)
  end

  def test_seconds_until_next
    _, _, crons = setup_entries([["*/10 * * * * *", PeriodicJob]])
    now = Time.at(1_800_000_003, 250, :millisecond)

    assert_equal 5, periodic.send(:seconds_until_next, crons, now)
    assert_in_delta 0.5, periodic.send(:seconds_until_next, crons, Time.at(1_800_000_009, 500, :millisecond))
    assert_in_delta 0.05, periodic.send(:seconds_until_next, crons, Time.at(1_800_000_009, 999, :millisecond))
    _, _, never = setup_entries([["0 0 30 2 *", PeriodicJob]])

    assert_equal 5, periodic.send(:seconds_until_next, never, now)
    assert_equal 5, periodic.send(:seconds_until_next, {}, now)
    _, _, mixed = setup_entries([["0 0 30 2 *", PeriodicJob]], [["0 * * * * *", PeriodicJob]], [["*/10 * * * * *", PeriodicJob]])

    assert_in_delta 0.5, periodic.send(:seconds_until_next, mixed, Time.at(1_800_000_009, 500, :millisecond))
  end
end
