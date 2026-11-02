# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class SchedulerTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Scheduler*"

  def setup
    super
    @scheduler = Robin::Scheduler.new(config)
    @errors = []
    config.error_handlers.replace([->(ex, ctx, _cfg) { @errors << [ex, ctx] }])
  end

  def teardown
    @scheduler.stop
    Robin::Leader.unregister(config)
    super
  end

  # Makes this process the cluster's leader, or not.
  def lead(leading = true) = Robin::Leader.register(config, Struct.new(:leader?).new(leading))

  def job(jid, queue = "default") = JSON.generate({"class" => "X", "args" => [], "jid" => jid, "queue" => queue})

  def add(set, score, *raws) = redis("ZADD", config.key(set), *raws.flat_map { |r| [score, r] })

  def moved(raw, now) = raw.sub(/}\z/, %(,"enqueued_at":#{now}}))

  def test_enqueue_due_moves_due_jobs_from_both_sets
    now = 1_700_000_000_123
    add("schedule", 1_700_000_000.113, job("s1"))
    add("schedule", 1_700_000_000.124, job("later"))
    add("retry", 1_700_000_000.123, job("r1", "low"))

    assert_equal 2, assert_roundtrips(1) { @scheduler.enqueue_due(now) }
    assert_equal %w[default low], redis("SMEMBERS", config.key("queues")).sort
    assert_equal [moved(job("s1"), now)], redis("LRANGE", config.key("queue", "default"), 0, -1)
    assert_equal [moved(job("r1", "low"), now)], redis("LRANGE", config.key("queue", "low"), 0, -1)
    assert_equal({"class" => "X", "args" => [], "jid" => "s1", "queue" => "default", "enqueued_at" => now},
      JSON.parse(redis("LINDEX", config.key("queue", "default"), 0)))
    assert_equal [job("later")], redis("ZRANGE", config.key("schedule"), 0, -1)
    assert_equal 0, redis("ZCARD", config.key("retry"))
    assert_equal 0, @scheduler.enqueue_due(now)
  end

  def test_enqueue_due_honors_the_given_time
    add("schedule", Robin.epoch_seconds(Robin.now_ms + 60_000), job("soon"))

    assert_equal 0, @scheduler.enqueue_due
    assert_equal 1, @scheduler.enqueue_due(Robin.now_ms + 120_000)
  end

  def test_enqueue_due_defaults_to_now
    add("schedule", Robin.epoch_seconds(Robin.now_ms - 1), job("a"))
    add("schedule", Robin.epoch_seconds(Robin.now_ms + 60_000), job("b"))

    assert_equal 1, @scheduler.enqueue_due
    assert_equal [job("b")], redis("ZRANGE", config.key("schedule"), 0, -1)
  end

  def test_enqueue_due_leaves_empty_or_unparseable_payloads_unchanged
    add("schedule", 1, "{}", "not json", %({"queue":7}))

    assert_equal 3, @scheduler.enqueue_due(5_000)
    assert_equal ["{}", "not json", %({"queue":7,"enqueued_at":5000})].sort, redis("LRANGE", config.key("queue", "default"), 0, -1).sort
    assert_equal ["default"], redis("SMEMBERS", config.key("queues"))
  end

  def test_enqueue_due_drains_in_batches
    raws = Array.new(Robin::Scheduler::BATCH * 2 + 1) { |i| job("j#{i}") }
    add("schedule", 1, *raws)
    add("retry", 1, *raws.first(3))

    # The schedule's three batches of 500, the last two alone.
    assert_equal raws.size + 3, assert_roundtrips(3) { @scheduler.enqueue_due }
    assert_equal 0, redis("ZCARD", config.key("schedule"))
  end

  def test_enqueue_due_stops_early_when_stopping
    add("schedule", 1, *Array.new(Robin::Scheduler::BATCH + 5) { |i| job("j#{i}") })
    add("retry", 1, job("r"))
    @scheduler.stop

    assert_equal Robin::Scheduler::BATCH + 1, @scheduler.enqueue_due
  end

  def test_interval_scales_with_the_live_processes_last_counted
    config.poll_interval = 4
    @scheduler.define_singleton_method(:rand) { 0.25 }

    assert_in_delta 3.0, @scheduler.interval, 1e-9, "never counted: as if alone"
    @scheduler.enqueue_due

    assert_in_delta 3.0, @scheduler.interval, 1e-9, "no live processes: as if alone"
    redis("SADD", config.key("processes"), "a", "b", "c")

    assert_in_delta 3.0, @scheduler.interval, 1e-9, "counted with the next poll"
    @scheduler.enqueue_due

    assert_in_delta 9.0, @scheduler.interval, 1e-9
  end

  def test_enqueue_due_learns_when_the_next_job_is_due
    assert_nil @scheduler.next_due, "never polled"
    add("schedule", 300.5, job("s"))
    add("retry", 200.25, job("r"))
    add("retry", 1, job("due"))

    assert_equal 1, @scheduler.enqueue_due(100_000)
    assert_in_delta 200.25, @scheduler.next_due, 1e-9
    assert_equal 1, @scheduler.enqueue_due(250_000)
    assert_in_delta 300.5, @scheduler.next_due, 1e-9, "the retry set is empty now"
    assert_equal 1, @scheduler.enqueue_due(400_000)
    assert_nil @scheduler.next_due
    add("schedule", 500, job("first"))
    add("retry", 600, job("second"))
    @scheduler.enqueue_due(400_000)

    assert_in_delta 500.0, @scheduler.next_due, 1e-9, "whichever set it's in"
  end

  # A set drained in more than one round trip keeps the score its last
  # one found; the set polled once keeps its own.
  def test_next_due_after_draining_in_batches
    add("schedule", 1, *Array.new(Robin::Scheduler::BATCH + 1) { |i| job("j#{i}") })
    add("schedule", 900, job("later"))
    add("retry", 800, job("r"))

    assert_equal Robin::Scheduler::BATCH + 1, @scheduler.enqueue_due(500_000)
    assert_in_delta 800.0, @scheduler.next_due, 1e-9
    redis("DEL", config.key("retry"))
    @scheduler.enqueue_due(500_000)

    assert_in_delta 900.0, @scheduler.next_due, 1e-9
  end

  def test_the_leader_wakes_for_the_next_due_job
    config.poll_interval = 4
    @scheduler.define_singleton_method(:rand) { 0.5 }
    now_ms = Robin.now_ms
    add("schedule", Robin.epoch_seconds(now_ms) + 1.5, job("soon"))
    @scheduler.enqueue_due(now_ms)

    assert_in_delta 4.0, @scheduler.interval, 1e-9, "not the leader: polls"
    lead(false)

    assert_in_delta 4.0, @scheduler.interval, 1e-9, "a follower polls"
    lead
    # (The clock stopped where the job was added: a slow runner's time
    # since then would shorten the wait.)
    interval = nil
    stub_method(Robin, :now_ms, -> { now_ms }) { interval = @scheduler.interval }

    assert_in_delta 1.5, interval, 1e-9
  end

  # Leadership of the scheduler's own cluster counts, whatever Robin.config
  # leads.
  def test_leadership_is_the_schedulers_own_configs
    other = Robin::Config.new
    other.poll_interval = 4
    scheduler = Robin::Scheduler.new(other)
    scheduler.define_singleton_method(:rand) { 0.5 }
    scheduler.instance_variable_get(:@next)["schedule"] = Robin.epoch_seconds(Robin.now_ms) + 1.5
    Robin::Leader.register(other, Struct.new(:leader?).new(true))
    lead(false)

    assert_in_delta 1.5, scheduler.interval, 0.1
  ensure
    Robin::Leader.unregister(other)
  end

  def test_the_leader_polls_when_the_next_job_is_later_than_that
    config.poll_interval = 4
    @scheduler.define_singleton_method(:rand) { 0.5 }
    lead

    assert_in_delta 4.0, @scheduler.interval, 1e-9, "nothing scheduled"
    add("retry", Robin.epoch_seconds(Robin.now_ms) + 60, job("later"))
    @scheduler.enqueue_due

    assert_in_delta 4.0, @scheduler.interval, 1e-9
  end

  def test_the_leader_waits_a_little_for_a_job_already_due
    config.poll_interval = 4
    lead
    add("schedule", Robin.epoch_seconds(Robin.now_ms) + 3600, job("x"))
    @scheduler.enqueue_due
    @scheduler.instance_variable_get(:@next)["schedule"] = 1.0

    assert_in_delta Robin::Scheduler::MIN_WAIT, @scheduler.interval, 1e-9
    assert_in_delta 0.01, Robin::Scheduler::MIN_WAIT, 1e-9
    config.poll_interval = 0.001

    assert_operator @scheduler.interval, :<, Robin::Scheduler::MIN_WAIT, "never longer than a poll"
  end

  def test_one_round_trip_polls_both_sets_and_counts_processes
    now = 1_700_000_000_123
    add("schedule", 1, job("s1"))
    pool = recording_pool { assert_equal 1, @scheduler.enqueue_due(now) }
    args = ->(set) { [Robin::Scripts::ENQUEUE_DUE, [config.key(set), config.key("queues")], [1_700_000_000.123, "#{config.key("queue")}:", 500, now]] }

    assert_equal [[:pipelined], [:pipe, :evalsha, *args.call("schedule")], [:pipe, :evalsha, *args.call("retry")],
      [:pipe, "SCARD", config.key("processes")]], pool.calls
  end

  def test_only_a_set_that_filled_a_batch_is_polled_again
    add("schedule", 1, *Array.new(Robin::Scheduler::BATCH) { |i| job("j#{i}") })
    add("retry", 1, job("r"))
    pool = recording_pool { assert_equal Robin::Scheduler::BATCH + 1, @scheduler.enqueue_due }
    polled = pool.calls.filter_map { |kind, *rest| [kind, rest[2]&.first] if kind == :pipelined || rest[0] == :evalsha }

    assert_equal [[:pipelined, nil], [:pipe, config.key("schedule")], [:pipe, config.key("retry")],
      [:pipelined, nil], [:pipe, config.key("schedule")]], polled
  end

  def test_background_thread_enqueues_and_reports_errors
    config.poll_interval = 0.01
    calls = 0
    sched = @scheduler
    sched.define_singleton_method(:enqueue_due) do
      calls += 1
      raise "boom" if calls == 1

      super()
    end
    add("schedule", 1, job("a"))

    assert_same sched, sched.start
    eventually { redis("LLEN", config.key("queue", "default")) == 1 }
    sched.stop

    assert_equal "robin.scheduler", sched.instance_variable_get(:@thread).name
    refute_predicate sched.instance_variable_get(:@thread), :alive?
    assert_equal "boom", @errors.first[0].message
    assert_equal({context: "scheduler"}, @errors.first[1])
  end

  def test_thread_sleeps_a_random_stagger_then_the_interval
    config.poll_interval = 4
    sleeps = []
    enqueued = 0
    sched = @scheduler
    sched.define_singleton_method(:rand) { 0.5 }
    sched.define_singleton_method(:enqueue_due) { enqueued += 1 }
    sched.define_singleton_method(:sleep_for) do |seconds|
      sleeps << seconds
      @done = true if sleeps.size == 2
    end
    sched.start.instance_variable_get(:@thread).join(2)

    assert_equal [2.0, 4.0], sleeps
    assert_equal 1, enqueued
  end

  def test_stop_waits_at_most_two_seconds_for_the_thread
    release = Queue.new
    @scheduler.define_singleton_method(:sleep_for) { |_s| release.pop }
    @scheduler.start
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @scheduler.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    release << true

    assert_in_delta 2.0, elapsed, 0.4
  end

  def test_stop_wakes_a_sleeping_thread
    config.poll_interval = 30
    @scheduler.start
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep 0.05
    @scheduler.stop

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.5
    refute_predicate @scheduler.instance_variable_get(:@thread), :alive?
  end

  def test_sleep_for_waits
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @scheduler.send(:sleep_for, 0.1)

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.1
  end

  # stop must signal while holding the mutex: a scheduler thread that has
  # checked @done but not yet started waiting would otherwise miss it.
  def test_stop_cannot_lose_the_wakeup
    mutex = @scheduler.instance_variable_get(:@mutex)
    cond = @scheduler.instance_variable_get(:@cond)
    mutex.lock
    stopper = Thread.new { @scheduler.stop }
    sleep 0.05
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    cond.wait(mutex, 3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    mutex.unlock
    stopper.join

    assert_operator elapsed, :<, 1
  end

  def test_sleep_for_returns_immediately_when_done
    @scheduler.stop
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @scheduler.send(:sleep_for, 5)

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  end

  def test_stop_without_start
    assert_nil Robin::Scheduler.new(config).stop
  end
end
