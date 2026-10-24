# frozen_string_literal: true

require_relative "test_helper"

class Recorder
  @mutex = Mutex.new
  @calls = []
  class << self
    attr_reader :calls

    def record(*args) = @mutex.synchronize { @calls << args }

    def reset! = @mutex.synchronize { @calls.clear }
  end
end

class EchoJob
  include Robin::Job

  def perform(*) = Recorder.record(:echo, *)
end

class FlakyJob
  include Robin::Job

  robin_options retry: 2, backtrace: 5
  # The first retry waits a moment so the test can inspect it before the
  # job fails again.
  robin_retry_in { |count, _ex, _payload| (count == 1) ? 1 : 0 }
  def perform(id) = raise(ArgumentError, "boom #{id}")
end

class NoRetryJob
  include Robin::Job

  robin_options retry: false
  def perform = raise("nope")
end

class SlowJob
  include Robin::Job

  def perform(seconds)
    Recorder.record(:slow_start)
    sleep seconds
    Recorder.record(:slow_done)
  end
end

# Runs on the "bulk" queue until let through its gate.
class GatedJob
  include Robin::Job

  robin_options queue: "bulk"

  GATES = Array.new(4) { Thread::Queue.new }

  def perform(id)
    Recorder.record(:gated, id, Thread.current.name)
    GATES.fetch(id).pop
  end
end

class CoreTest < RobinTest
  def setup
    super
    Recorder.reset!
    config.poll_interval = 0.2
    config.heartbeat_interval = 0.2
    config.timeout = 1
  end

  def run_server(concurrency: 2, queues: ["default"])
    Robin.server!
    config.concurrency = concurrency
    config.queues = queues
    launcher = Robin::Launcher.new(config)
    launcher.run
    yield launcher
  ensure
    launcher&.stop
  end

  def test_push_creates_payload
    jid = EchoJob.perform_async(1, "two", {"three" => 3})
    raw = redis("LINDEX", "#{key_prefix_for_test}queue:default", 0)
    item = JSON.parse(raw)

    assert_equal jid, item["jid"]
    assert_equal "EchoJob", item["class"]
    assert_equal [1, "two", {"three" => 3}], item["args"]
    assert item["enqueued_at"]
    assert_equal ["default"], redis("SMEMBERS", "#{key_prefix_for_test}queues")
  end

  def test_strict_args
    assert_raises(Robin::Client::ArgumentError) { EchoJob.perform_async(:sym) }
    assert_raises(Robin::Client::ArgumentError) { EchoJob.perform_async({a: 1}) }
    config.strict_args = false

    assert EchoJob.perform_async(:sym)
  end

  def test_set_and_scheduling
    EchoJob.set(queue: "critical").perform_async(1)

    assert_equal 1, Robin::Queue.new("critical").size
    jid = EchoJob.perform_in(60, 2)
    entry = Robin::ScheduledSet.new.first

    assert_equal jid, entry.jid
    assert_in_delta Time.now + 60, entry.at, 2
    EchoJob.set(wait: 30).perform_async(3)

    assert_equal 2, Robin::ScheduledSet.new.size
  end

  def test_bulk_push
    jids = EchoJob.perform_bulk([[1], [2], [3]])

    assert_equal 3, jids.compact.uniq.size
    assert_equal 3, Robin::Queue.new("default").size
  end

  def test_processes_jobs
    run_server do
      10.times { |i| EchoJob.perform_async(i) }
      eventually { Recorder.calls.size == 10 }
    end

    assert_equal (0..9).to_a, Recorder.calls.map(&:last).sort
    assert_empty redis("KEYS", "#{key_prefix_for_test}inflight*"), "nothing left in flight, nothing registered"
    assert_equal "10", redis("GET", "#{key_prefix_for_test}stat:processed")
  end

  def test_queue_priority_strict
    Robin::Queue.new("low")
    3.times { |i| EchoJob.set(queue: "low").perform_async("low#{i}") }
    3.times { |i| EchoJob.set(queue: "high").perform_async("high#{i}") }
    run_server(concurrency: 1, queues: %w[high low]) do
      eventually { Recorder.calls.size == 6 }
    end

    assert_equal %w[high0 high1 high2 low0 low1 low2], Recorder.calls.map(&:last)
  end

  def test_retry_then_dead
    run_server do
      FlakyJob.perform_async(7)
      eventually { Robin::RetrySet.new.size == 1 }
      entry = Robin::RetrySet.new.first

      assert_equal "ArgumentError", entry.error_class
      assert_equal "boom 7", entry.error_message
      assert_equal 1, entry.failures
      assert_operator entry.error_backtrace.size, :<=, 5
      eventually(timeout: 8) { Robin::DeadSet.new.size == 1 }
    end
    dead = Robin::DeadSet.new.first

    assert_equal 3, dead.failures
    assert_equal 0, Robin::RetrySet.new.size
  end

  def test_retry_false_discards
    run_server do
      NoRetryJob.perform_async
      eventually { redis("GET", "#{key_prefix_for_test}stat:failed") == "1" }
    end

    assert_equal 0, Robin::RetrySet.new.size
    assert_equal 0, Robin::DeadSet.new.size
  end

  def test_profiled_jobs
    skip "vernier needs CRuby" unless RUBY_ENGINE == "ruby"

    jid = EchoJob.set(profile: "slow one").perform_async("p")
    run_server do
      eventually { Robin::Profiler.list.any? }
    end
    entry = Robin::Profiler.list.first

    assert_equal [jid, "EchoJob", "slow one", true], entry.values_at("jid", "class", "label", "ok")
    assert JSON.parse(Robin::Profiler.data(jid)).key?("threads")
  end

  def test_scheduled_jobs_run
    run_server do
      EchoJob.perform_in(0.3, "later")
      eventually { Recorder.calls.any? }
    end

    assert_equal [[:echo, "later"]], Recorder.calls
  end

  def test_paused_queue_is_skipped
    Robin::Queue.new("default").pause!
    EchoJob.perform_async(1)
    run_server do
      sleep 0.6

      assert_empty Recorder.calls
      Robin::Queue.new("default").unpause!
      eventually { Recorder.calls.size == 1 }
    end
  end

  def test_shutdown_requeues_running_jobs
    config.timeout = 0.3
    run_server(concurrency: 1) do
      SlowJob.perform_async(5)
      eventually { Recorder.calls.include?([:slow_start]) }
    end

    assert_equal 1, Robin::Queue.new("default").size
    refute_includes Recorder.calls, [:slow_done]
  end

  def test_recovers_jobs_from_dead_processes
    payload = {"class" => "EchoJob", "args" => ["orphan"], "jid" => "abc", "queue" => "default"}
    set = "#{key_prefix_for_test}inflight:ghost:1:aa"
    redis("RPUSH", "#{set}:7", JSON.generate(payload))
    redis("SADD", set, "#{set}:7")
    redis("SADD", "#{key_prefix_for_test}inflights", set)
    # A process of a version before in-flight sets kept its jobs in a list.
    redis("RPUSH", "#{key_prefix_for_test}inflight:ghost:1:ab", JSON.generate(payload.merge("args" => ["older"], "jid" => "abd")))
    redis("SADD", "#{key_prefix_for_test}inflights", "#{key_prefix_for_test}inflight:ghost:1:ab")

    assert_equal 2, Robin::Recovery.run(config)
    assert_equal 2, Robin::Queue.new("default").size
    run_server { eventually { Recorder.calls.sort == [[:echo, "older"], [:echo, "orphan"]] } }
  end

  def test_poison_pills_go_to_dead_set
    config.max_recoveries = 1
    raw = JSON.generate({"class" => "EchoJob", "args" => [], "jid" => "poison", "queue" => "default"})
    2.times do
      redis("RPUSH", "#{key_prefix_for_test}inflight:ghost:1:bb", raw)
      redis("SADD", "#{key_prefix_for_test}inflights", "#{key_prefix_for_test}inflight:ghost:1:bb")
      Robin::Recovery.run(config)
      redis("DEL", "#{key_prefix_for_test}queue:default")
    end

    assert_equal "Robin::PoisonPill", Robin::DeadSet.new.first.error_class
  end

  def test_middleware
    seen = []
    client_mw = Class.new do
      define_method(:call) do |_klass, payload, _queue, _redis, &blk|
        payload["tenant"] = "acme"
        blk.call
      end
    end
    server_mw = Class.new do
      define_method(:call) do |_job, payload, _queue, &blk|
        seen << payload["tenant"]
        blk.call
      end
    end
    config.client_middleware { |c| c.add client_mw }
    config.server_middleware { |c| c.add server_mw }
    run_server do
      EchoJob.perform_async(1)
      eventually { Recorder.calls.size == 1 }
    end

    assert_equal ["acme"], seen
  end

  def test_heartbeat_and_process_api
    run_server do |launcher|
      eventually { Robin::ProcessSet.new.size == 1 }
      process = Robin::ProcessSet.new.first

      assert_equal launcher.identity, process.identity
      assert_equal 2, process["concurrency"]
      eventually { Robin::ProcessSet.new.first.leader? }

      assert_equal launcher.identity, Robin::Leader.current(config)
      jid = SlowJob.perform_async(0.5)
      eventually { Robin::WorkSet.new.size == 1 }
      _, _, work = Robin::WorkSet.new.first

      assert_equal ["default", jid, [0.5]], [work["queue"], work["payload"]["jid"], work["payload"]["args"]]
      Robin::ProcessSet.new.first.quiet!
      eventually { Robin::ProcessSet.new.first.quiet? }
    end

    assert_equal 0, Robin::ProcessSet.new.size
  end

  def test_resizing_a_running_process
    config.capsule("bulk") do |c|
      c.queues = ["bulk"]
      c.concurrency = 1
    end
    started = -> { Recorder.calls.select { |c| c.first == :gated } }
    run_server(concurrency: 1) do |launcher|
      bulk = launcher.managers.last
      eventually { Robin::ProcessSet.new.size == 1 }
      4.times { |i| GatedJob.perform_async(i) }
      eventually { started.call.size == 1 }
      sleep 0.3

      assert_equal 1, started.call.size, "one bulk worker"
      Robin::ProcessSet.new.first.resize!(3, capsule: "bulk")
      eventually { started.call.size == 3 }

      assert_equal %w[robin.bulk.0 robin.bulk.1 robin.bulk.2], started.call.map(&:last).sort
      eventually { Robin::ProcessSet.new.first["capsules"]["bulk"]["concurrency"] == 3 }

      assert_equal 4, Robin::ProcessSet.new.first["concurrency"]

      Robin::ProcessSet.new.first.resize!(1, capsule: "bulk")
      eventually { bulk.concurrency == 1 }
      retired = bulk.processors.select(&:retired?)

      assert_equal %w[robin.bulk.1 robin.bulk.2], retired.map { |p| p.thread.name }
      assert(retired.all?(&:alive?), "retired workers finish their jobs first")
      started.call.each { |_, id, _thread| GatedJob::GATES.fetch(id) << true }
      eventually { retired.none?(&:alive?) && bulk.processors.size == 1 }
      eventually { started.call.size == 4 }
      sleep 0.3

      assert_equal 4, started.call.size
      assert_equal ["robin.bulk.0"], bulk.processors.map { |p| p.thread.name }
      eventually { Robin::ProcessSet.new.first["capsules"]["bulk"]["concurrency"] == 1 }
      GatedJob::GATES.each { |gate| gate << true }
      eventually { Robin::Queue.new("bulk").size.zero? && launcher.busy.zero? }
    end
  ensure
    GatedJob::GATES.each(&:clear)
  end

  def test_metrics_are_recorded
    run_server do
      3.times { EchoJob.perform_async(1) }
      eventually { Recorder.calls.size == 3 }
      eventually { Robin::Metrics::Query.new(config).recent(minutes: 2)["classes"]["EchoJob"]&.fetch("s") == 3 }
    end
    hist = Robin::Metrics::Query.new(config).histogram("EchoJob", minutes: 2)

    assert_equal 3, hist.sum { |b| b["count"] }
  end

  def test_sorted_set_api
    jid = EchoJob.perform_in(3600, 1)
    entry = Robin::ScheduledSet.new.find_job(jid)

    assert entry
    assert_equal entry.jid, Robin::ScheduledSet.new.find_by_id(entry.id).jid
    entry.add_to_queue

    assert_equal 0, Robin::ScheduledSet.new.size
    assert_equal 1, Robin::Queue.new("default").size
    job = Robin::Queue.new("default").first

    assert_equal jid, job.jid
    assert job.delete
    assert_equal 0, Robin::Queue.new("default").size
  end

  def test_stats
    EchoJob.perform_async(1)
    EchoJob.set(queue: "other").perform_async(1)
    EchoJob.perform_in(100, 1)
    stats = Robin::Stats.new

    assert_equal 2, stats.enqueued
    assert_equal 1, stats.scheduled_size
    assert_equal({"default" => 1, "other" => 1}, stats.queues)
  end

  def test_cancellation_skips_pending_jobs
    jid = EchoJob.perform_async("cancel me")
    Robin.cancel!(jid)

    assert Robin::Cancellation.cancelled?(jid)
    EchoJob.perform_async("keep me")
    run_server { eventually { Recorder.calls.size == 1 } }

    assert_equal [[:echo, "keep me"]], Recorder.calls
  end

  def test_weighted_queue_order
    cap = Robin::Capsule.new("x", config)
    cap.queues = ["a,3", "b,1"]

    refute_predicate cap, :strict?
    firsts = Array.new(400) { cap.queue_order.first }

    assert_in_delta 0.75, firsts.count("a") / 400.0, 0.1
  end
end
