# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"
require_relative "support/statsd_recorder"

class RecoveryTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Recovery*"

  def job(jid, queue: "default", **extra) = JSON.generate({"class" => "X", "args" => [], "jid" => jid, "queue" => queue}.merge(extra))

  def recovered(raw) = raw.sub("{", '{"recovered":true,')

  # A process of a version before in-flight sets, which kept its jobs in
  # one list (still recovered after an upgrade).
  def orphan(identity, *raws)
    list = config.key("inflight", identity)
    redis("RPUSH", list, *raws) unless raws.empty?
    redis("SADD", config.key("inflights"), list)
    redis("SADD", config.key("processes"), identity)
    list
  end

  # A process with each of +raws+ in an in-flight key of its own (nil: an
  # empty one, registered), as Robin::Fetcher leaves them. Returns the
  # in-flight set and the keys.
  def orphan_keys(identity, *raws)
    set = config.key("inflight", identity)
    keys = raws.map do |raw|
      key = "#{set}:#{Robin::Fetcher.mint}"
      redis("SADD", set, key)
      redis("RPUSH", key, raw) if raw
      key
    end
    redis("SADD", config.key("inflights"), set)
    redis("SADD", config.key("processes"), identity)
    [set, keys]
  end

  def test_recovers_dead_processes_and_skips_live_ones
    dead = orphan("ghost:1", job("a"), job("b", queue: "low"))
    live = orphan("alive:2", job("c"))
    redis("SET", config.process_key("alive:2"), "1")
    redis("RPUSH", config.key("queue", "default"), job("existing"))
    logs = capture_logs

    assert_equal 2, Robin::Recovery.run(config)
    # recovered jobs go to the front (the fetch end) of their queues
    assert_equal [job("existing"), recovered(job("a"))], redis("LRANGE", config.key("queue", "default"), 0, -1)
    assert_equal [recovered(job("b", queue: "low"))], redis("LRANGE", config.key("queue", "low"), 0, -1)
    assert_equal %w[default low], redis("SMEMBERS", config.key("queues")).sort
    assert_equal [live], redis("SMEMBERS", config.key("inflights"))
    assert_equal ["alive:2"], redis("SMEMBERS", config.key("processes"))
    assert_equal 0, redis("EXISTS", dead)
    assert_equal "WARN: recovered 2 in-flight job(s) from dead process ghost:1\n", logs.string
  end

  def test_recoveries_are_counted_in_statsd
    config.statsd = StatsdRecorder.new
    orphan("ghost:1", job("a"), job("b"))
    orphan("ghost:2", job("c"))
    orphan("ghost:3")
    Robin::Recovery.run(config)

    # One count per dead process, in whatever order Redis lists them.
    assert_equal [[:increment, "jobs.recovered", 1, {}], [:increment, "jobs.recovered", 2, {}]],
      config.statsd.calls.sort_by { |call| call[2] }
  ensure
    config.statsd = nil
  end

  def test_poison_pills_are_counted_in_statsd
    config.max_recoveries = 0
    config.statsd = StatsdRecorder.new
    orphan("ghost:5", job("p"), JSON.generate({"jid" => "r", "queue" => "default"}))
    Robin::Recovery.run(config)

    # The list drains from its end.
    assert_equal [[:increment, "jobs.poison", 1, {class: nil}], [:increment, "jobs.poison", 1, {class: "X"}],
      [:increment, "jobs.recovered", 2, {}]], config.statsd.calls
  ensure
    config.statsd = nil
  end

  def test_single_recovered_job_is_logged
    orphan("ghost:9", job("a"))
    logs = capture_logs

    assert_equal 1, Robin::Recovery.run(config)
    assert_equal "WARN: recovered 1 in-flight job(s) from dead process ghost:9\n", logs.string
  end

  def test_dead_process_with_nothing_in_flight
    orphan("ghost:3")
    logs = capture_logs

    assert_equal 0, Robin::Recovery.run(config)
    assert_empty redis("SMEMBERS", config.key("inflights"))
    assert_empty redis("SMEMBERS", config.key("processes"))
    assert_empty logs.string
  end

  def test_nothing_registered
    assert_equal 0, Robin::Recovery.run(config)
  end

  def forget(set, identity)
    keys = [set, config.key("inflights"), config.key("stopping", identity), config.key("processes")]
    config.redis { |c| c.evalsha(Robin::Scripts::FORGET, keys, [identity]) }
  end

  # A process whose heartbeat only lapsed may fill its in-flight set again
  # while it's being recovered: the set stays tracked, and so does its
  # stopping marker.
  def test_forgetting_a_process_keeps_a_set_refilled_meanwhile
    set, = orphan_keys("ghost:4", job("a"))
    redis("SET", config.key("stopping", "ghost:4"), "1")
    forget(set, "ghost:4")

    assert_equal [set], redis("SMEMBERS", config.key("inflights"))
    assert_equal 1, redis("EXISTS", config.key("stopping", "ghost:4"))
    assert_empty redis("SMEMBERS", config.key("processes"))
    redis("DEL", set)
    forget(set, "ghost:4")

    assert_empty redis("SMEMBERS", config.key("inflights"))
    assert_equal 0, redis("EXISTS", config.key("stopping", "ghost:4"))
  end

  def test_recovering_any_number_of_dead_processes_takes_three_round_trips
    orphan("ghost:1", job("a"), job("b"))
    orphan_keys("ghost:2", job("c"), nil)
    orphan_keys("ghost:3")
    orphan_keys("alive:4", job("d"))
    redis("SET", config.process_key("alive:4"), "1")

    assert_equal 3, assert_roundtrips(3) { Robin::Recovery.run(config) }
    assert_equal 0, assert_roundtrips(2) { Robin::Recovery.run(config) }, "the live process's job stays"
  end

  def test_poison_pills_take_one_more_round_trip
    config.max_recoveries = 0
    orphan("ghost:1", job("a"), job("b"))
    orphan_keys("ghost:2", job("c"))

    assert_equal 3, assert_roundtrips(4) { Robin::Recovery.run(config) }
    assert_equal 3, redis("ZCARD", config.key("dead"))
  end

  def test_checking_on_no_processes_takes_one_round_trip
    assert_equal 0, assert_roundtrips(1) { Robin::Recovery.run(config) }
  end

  def test_drain_returns_count
    list = orphan("me", job("a"), job("b"), job("c"))
    count = config.redis { |c| assert_roundtrips(1) { Robin::Recovery.drain(config, c, list, count: true) } }

    assert_equal 3, count
    assert_equal 3, redis("LLEN", config.key("queue", "default"))
    assert_equal 0, config.redis { |c| Robin::Recovery.drain(config, c, list, count: true) }
  end

  def test_poison_pills_are_marked_and_killed
    config.max_recoveries = 1
    raw = job("p", "failed_at" => 123, "enqueued_at" => 5)
    fresh = job("q")
    classless = JSON.generate({"jid" => "r", "queue" => "default"})
    orphan("ghost:5", raw, fresh, classless)
    Robin::Recovery.run(config)
    redis("DEL", config.key("queue", "default"))
    logs = capture_logs
    orphan("ghost:5", raw, fresh, classless)
    # The script moves the raw payloads into the (prefixed) dead set
    # before Ruby swaps them for annotated copies, all in one transaction.
    staged = []
    responder = lambda do |kind, _args|
      staged << redis("ZRANGE", config.key("dead"), 0, -1, "WITHSCORES").each_slice(2).map { |_, score| Float(score) } if kind == :multi
      :forward
    end
    count = nil
    recording_pool(responder) { count = Robin::Recovery.run(config) }

    assert_equal 3, count
    assert_equal [3], staged.map(&:size)
    # Scored in epoch seconds, like the rest of the dead set.
    assert_in_delta Robin.epoch_seconds(Robin.now_ms), staged.first.first, 5
    redis("ZREM", config.key("dead"), redis("ZRANGE", config.key("dead"), 0, -1).find { |v| v.include?('"r"') })
    dead = redis("ZRANGE", config.key("dead"), 0, -1, "WITHSCORES").each_slice(2).map { |v, s| [JSON.parse(v), Float(s)] }

    assert_equal 2, dead.size
    by_jid = dead.to_h { |item, score| [item["jid"], [item, score]] }
    item, score = by_jid.fetch("p")

    assert_equal "Robin::PoisonPill", item["error_class"]
    assert_equal "job was running when its process died 2 times", item["error_message"]
    assert_equal 123, item["failed_at"]
    refute item.key?("enqueued_at")
    assert_in_delta Robin.epoch_seconds(Robin.now_ms), score, 5
    q_item, = by_jid.fetch("q")

    assert_in_delta Robin.now_ms, q_item["failed_at"], 5_000
    assert_includes logs.string, "ERROR: moved poison-pill job X jid=p to the dead set\n"
    assert_includes logs.string, "ERROR: moved poison-pill job X jid=q to the dead set\n"
    assert_includes logs.string, "ERROR: moved poison-pill job  jid=r to the dead set\n"
    refute_includes redis("ZRANGE", config.key("dead"), 0, -1), raw
    assert_equal 0, redis("LLEN", config.key("queue", "default"))
  end

  def orphan_count(jid) = redis("GET", config.key("orphan", jid))

  def test_shutdown_drain_does_not_count_toward_poison_pills
    config.max_recoveries = 0
    list = orphan("me", job("a"))
    count = config.redis { |c| Robin::Recovery.drain(config, c, list, count: false) }

    assert_equal 1, count
    # Not counted, not marked as recovered: the job goes back untouched.
    assert_equal [job("a")], redis("LRANGE", config.key("queue", "default"), 0, -1)
    assert_nil orphan_count("a")
    assert_equal 0, redis("ZCARD", config.key("dead"))
  end

  def test_crash_recovery_counts_and_marks_the_payload
    orphan("ghost:6", job("a"), job("b", "recovered" => true), JSON.generate({"queue" => "default"}))

    assert_equal 3, Robin::Recovery.run(config)
    requeued = redis("LRANGE", config.key("queue", "default"), 0, -1)

    assert_equal [JSON.generate({"queue" => "default"}), job("b", "recovered" => true), recovered(job("a"))], requeued
    assert_equal "1", orphan_count("a")
    assert_equal "1", orphan_count("b")
    assert_operator redis("TTL", config.key("orphan", "a")), :>, 604_000
  end

  def test_recovery_handlers_see_each_job_recovered_after_a_crash
    config.max_recoveries = 1
    seen = []
    config.recovery_handlers << ->(job, poison) { seen << [job["jid"], poison] }
    config.recovery_handlers << ->(*) { raise "handler bug" }
    errors = capture_errors
    raw = job("p")
    orphan("ghost:6", raw, job("q"))
    Robin::Recovery.run(config)
    orphan("ghost:6", raw, "not json")
    Robin::Recovery.run(config)

    assert_equal [["q", false], ["p", false], ["p", true]], seen
    assert_equal [["q", true], ["p", true], ["p", nil]], errors.map { |_e, ctx| ctx.fetch(:job).values_at("jid", "recovered") }
    assert_equal [["handler bug", "recovery handler"]] * 3, errors.map { |e, ctx| [e.message, ctx.fetch(:context)] }
    seen.clear
    list = orphan("me", job("s"))
    config.redis { |c| Robin::Recovery.drain(config, c, list, count: false) }

    assert_empty seen, "a graceful shutdown's jobs weren't recovered from a crash"
  end

  def test_recovered_jobs_are_events_even_without_recovery_handlers
    config.max_recoveries = 1
    events = capture_events
    raw = job("p")
    orphan("ghost:6", raw, job("q"))
    Robin::Recovery.run(config)
    orphan("ghost:6", raw, "not json")
    Robin::Recovery.run(config)

    assert_equal [["job.recovered", {job: JSON.parse(recovered(job("q"))), poison: false}],
      ["job.recovered", {job: JSON.parse(recovered(raw)), poison: false}],
      ["job.recovered", {job: JSON.parse(raw), poison: true}]], events
    events.clear
    list = orphan("me", job("s"))
    config.redis { |c| Robin::Recovery.drain(config, c, list, count: false) }

    assert_empty events, "a graceful shutdown's jobs weren't recovered from a crash"
  end

  def test_without_recovery_or_event_handlers_recovered_jobs_are_not_parsed
    assert_empty config.recovery_handlers
    assert_empty config.event_handlers
    orphan("ghost:6", job("a"))

    stub_method(Robin, :load_json, ->(*) { raise "parsed" }) do
      assert_equal 1, Robin::Recovery.run(config)
    end
  end

  def test_jobs_of_a_process_that_was_stopping_are_not_recovered_jobs
    seen = []
    config.recovery_handlers << ->(job, _poison) { seen << job["jid"] }
    orphan("ghost:7", job("a"))
    orphan("ghost:8", job("b"))
    redis("SET", config.key("stopping", "ghost:7"), "1")

    assert_equal 2, Robin::Recovery.run(config)
    assert_equal ["b"], seen
  end

  # Processes are handled in order: one with nothing to recover doesn't
  # stop the ones after it being logged.
  def test_every_dead_process_with_jobs_is_logged_in_order
    logs = capture_logs
    # Registered out of order (a small set lists its members as added).
    orphan("ghost:3", job("b"))
    orphan("ghost:1")
    orphan("ghost:2", job("a"))

    assert_equal 2, Robin::Recovery.run(config)
    assert_equal ["WARN: recovered 1 in-flight job(s) from dead process ghost:2", "WARN: recovered 1 in-flight job(s) from dead process ghost:3"],
      logs.string.lines(chomp: true)
  end

  def test_a_counted_drain_marks_poison_pills_and_runs_the_handlers
    config.max_recoveries = 0
    seen = []
    config.recovery_handlers << ->(job, poison) { seen << [job["jid"], poison] }
    list = orphan("me", job("a"))

    assert_equal 1, config.redis { |c| Robin::Recovery.drain(config, c, list, count: true) }
    assert_equal [["a", true]], seen
    assert_equal ["Robin::PoisonPill"], redis("ZRANGE", config.key("dead"), 0, -1).map { |raw| JSON.parse(raw).fetch("error_class") }
  end

  def test_recovering_a_process_that_was_stopping_does_not_count
    config.max_recoveries = 0
    orphan("ghost:7", job("a"))
    redis("SET", config.key("stopping", "ghost:7"), "1")

    assert_equal 1, Robin::Recovery.run(config)
    assert_equal [job("a")], redis("LRANGE", config.key("queue", "default"), 0, -1)
    assert_nil orphan_count("a")
    assert_equal 0, redis("EXISTS", config.key("stopping", "ghost:7"))
  end

  def test_run_uses_the_given_pool
    orphan("ghost:9", job("a"))
    used = []
    pool = Robin::Redis::Pool.new(size: 1) { Robin::Redis::Connection.new(url: REDIS_URL) }
    real = pool.method(:with)
    pool.define_singleton_method(:with) { |&b| used << :given && real.call(&b) }

    assert_equal 1, Robin::Recovery.run(config, pool: pool)
    assert_equal [:given], used
  ensure
    pool&.shutdown
  end
  # -- in-flight sets: a key per job ------------------------------------------

  def test_recovers_the_in_flight_keys_of_dead_processes
    set, keys = orphan_keys("ghost:1", job("a"), job("b", queue: "low"), nil)
    live, = orphan_keys("alive:2", job("c"))
    redis("SET", config.process_key("alive:2"), "1")
    logs = capture_logs

    assert_equal 2, Robin::Recovery.run(config)
    assert_equal [recovered(job("a"))], redis("LRANGE", config.key("queue", "default"), 0, -1)
    assert_equal [recovered(job("b", queue: "low"))], redis("LRANGE", config.key("queue", "low"), 0, -1)
    assert_equal [0, 0, 0, 0], [set, *keys].map { |key| redis("EXISTS", key) }, "every key unregistered, then the set"
    assert_equal [live], redis("SMEMBERS", config.key("inflights"))
    assert_equal ["alive:2"], redis("SMEMBERS", config.key("processes"))
    assert_equal "WARN: recovered 2 in-flight job(s) from dead process ghost:1\n", logs.string
  end

  def test_drain_counts_and_unregisters_each_key_once_empty
    set, keys = orphan_keys("me", job("a"), job("b"))
    redis("RPUSH", keys.first, job("c")) # never two in one key, but all would go back
    pool = recording_pool do
      assert_equal 3, config.redis { |c| assert_roundtrips(1) { Robin::Recovery.drain(config, c, set, count: false) } }
    end

    assert_equal [job("a"), job("b"), job("c")].sort, redis("LRANGE", config.key("queue", "default"), 0, -1).sort
    assert_equal 0, redis("EXISTS", set)
    (call,) = pool.calls

    assert_equal [:evalsha, Robin::Scripts::RECOVER, [set, config.key("queues"), config.key("dead")]], call.first(3)
    assert_equal ["#{config.key("queue")}:", 3, false, "#{config.key("orphan")}:"], call.last.values_at(0, 1, 3, 4)
    assert_equal 0, config.redis { |c| Robin::Recovery.drain(config, c, set, count: true) }
  end

  def test_recover_says_what_it_did_with_each_job
    config.max_recoveries = 0
    set, keys = orphan_keys("me", job("a"), nil, job("b", queue: "low"))
    redis("SET", config.key("orphan", "a"), "-1") # one more recovery to go
    args = ["#{config.key("queue")}:", 0, 1_700_000_000, true, "#{config.key("orphan")}:"]
    done = config.redis { |c| c.evalsha(Robin::Scripts::RECOVER, [set, config.key("queues"), config.key("dead")], args) }

    assert_equal [["dead", job("b", queue: "low")], ["requeued", recovered(job("a"))]], done.each_slice(2).sort
    assert_equal [0] * 4, [set, *keys].map { |key| redis("EXISTS", key) }
    assert_equal [job("b", queue: "low"), "1700000000"], redis("ZRANGE", config.key("dead"), 0, -1, "WITHSCORES")
  end

  def test_graceful_shutdown_drain_of_keys_does_not_count
    config.max_recoveries = 0
    set, = orphan_keys("me", job("a"))

    assert_equal 1, config.redis { |c| Robin::Recovery.drain(config, c, set, count: false) }
    assert_equal [job("a")], redis("LRANGE", config.key("queue", "default"), 0, -1)
    assert_nil orphan_count("a")
  end

  def test_poison_pills_in_keys_go_to_the_dead_set
    config.max_recoveries = 0
    orphan_keys("ghost:5", job("p"))

    assert_equal 1, Robin::Recovery.run(config)
    assert_equal ["Robin::PoisonPill"], redis("ZRANGE", config.key("dead"), 0, -1).map { |raw| JSON.parse(raw).fetch("error_class") }
    assert_equal 0, redis("LLEN", config.key("queue", "default"))
  end

  # -- crash windows: a process dying between any two steps loses nothing ---

  def fetcher_for(identity) = Robin::Fetcher.new(config.default_capsule, identity)

  def recover_dead(identity)
    redis("DEL", config.process_key(identity))
    redis("SADD", config.key("inflights"), config.key("inflight", identity))
    Robin::Recovery.run(config)
  end

  def queued = redis("LRANGE", config.key("queue", "default"), 0, -1)

  # Registered, but the fetch that would fill the key never ran.
  def test_crash_after_registering_a_key_before_filling_it
    set = config.key("inflight", "ghost:a")
    redis("SADD", set, "#{set}:1") # the round trip's first command ran...
    redis("LPUSH", config.key("queue", "default"), job("a")) # ...its LMOVE didn't

    assert_equal 0, recover_dead("ghost:a")
    assert_equal [job("a")], queued
    assert_equal 0, redis("EXISTS", set)
    assert_empty redis("SMEMBERS", config.key("inflights"))
  end

  # Fetched (the reply may never have arrived): the job is in its key.
  def test_crash_after_a_fetch
    config.default_capsule.queues = %w[default]
    fetcher = fetcher_for("ghost:b")
    redis("LPUSH", config.key("queue", "default"), job("a"), job("b"))
    fetcher.instance_variable_set(:@wanting, 1)
    unit = fetcher.fetch

    assert_equal 1, fetcher.held.size, "one fetched for another worker"
    assert_equal 2, recover_dead("ghost:b")
    assert_equal [recovered(job("b")), recovered(job("a"))].sort, queued.sort
    assert_equal 0, redis("EXISTS", unit.key)
    assert_equal 0, redis("EXISTS", fetcher.inflight_key)
  end

  # Finished, with the acknowledgement waiting for the next fetch: the job
  # runs again (at least once).
  def test_crash_before_a_deferred_acknowledgement
    fetcher = fetcher_for("ghost:c")
    redis("LPUSH", config.key("queue", "high"), job("a", queue: "high"))
    config.default_capsule.queues = %w[high]
    unit = fetcher.fetch

    assert_equal 1, recover_dead("ghost:c")
    assert_equal [recovered(job("a", queue: "high"))], redis("LRANGE", config.key("queue", "high"), 0, -1)
    config.redis { |c| fetcher.acknowledge(c, [unit.key]) } # a late acknowledgement is harmless

    assert_equal 1, redis("LLEN", config.key("queue", "high"))
  end

  # Acknowledged (or retried, or killed: the same transaction) before the
  # crash: nothing comes back.
  def test_crash_after_an_acknowledgement
    fetcher = fetcher_for("ghost:d")
    unit = unit_in_flight(fetcher, job("a"))
    unit.acknowledge

    assert_equal 0, recover_dead("ghost:d")
    assert_empty queued
  end

  # Handed back (a pause, a stale buffered job, a stop): the job is either
  # still in its key or back on its queue, never both or neither.
  def test_crash_around_a_hand_back
    fetcher = fetcher_for("ghost:e")
    unit_in_flight(fetcher, job("a"))

    assert_equal 1, recover_dead("ghost:e")
    assert_equal [recovered(job("a"))], queued
    redis("DEL", config.key("queue", "default"))
    unit = unit_in_flight(fetcher, job("b"))
    unit.requeue

    assert_equal 0, recover_dead("ghost:e")
    assert_equal [job("b")], queued
  end
end
