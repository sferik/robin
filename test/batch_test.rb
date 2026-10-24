# frozen_string_literal: true

require_relative "test_helper"

module BatchTest
  class Log
    @mutex = Mutex.new
    @events = []
    class << self
      def add(*e) = @mutex.synchronize { @events << e }

      def events = @mutex.synchronize { @events.dup }

      def reset! = @mutex.synchronize { @events.clear }
    end
  end

  class Work
    include Robin::Job

    def perform(n) = Log.add(:work, n)
  end

  class FailOnce
    include Robin::Job

    robin_options retry: 3
    robin_retry_in { 1 }
    def perform(key)
      raise "first try fails" if Robin.redis { |c| c.call("INCR", Robin.config.key("failonce", key)) } == 1

      Log.add(:failonce, key)
    end
  end

  class AlwaysFails
    include Robin::Job

    robin_options retry: 1
    robin_retry_in { 0 }
    def perform = raise("nope")
  end

  class Spawner
    include Robin::Job

    def perform
      child = Robin::Batch.new
      child.on(:success, Callbacks, "who" => "child")
      child.jobs { 3.times { |i| Work.perform_async(100 + i) } }
      Log.add(:spawned, child.bid)
    end
  end

  class Callbacks
    def on_complete(status, opts) = Log.add(:complete, opts["who"], status.bid)

    def on_success(status, opts) = Log.add(:success, opts["who"], status.bid)

    def on_death(status, opts) = Log.add(:death, opts["who"], status.bid)

    def custom(status, _opts) = Log.add(:custom, status.bid)
  end
end

class BatchUnitTest < RobinTest
  include BatchTest

  def setup
    super
    Log.reset!
    config.poll_interval = 0.1
    config.heartbeat_interval = 0.2
    config.timeout = 1
  end

  def run_server(concurrency: 5)
    Robin.server!
    config.concurrency = concurrency
    launcher = Robin::Launcher.new(config)
    launcher.run
    yield launcher
  ensure
    launcher&.stop
  end

  def test_jobs_are_tagged_and_counted
    b = Robin::Batch.new
    b.description = "three"
    bid = b.jobs { 3.times { |i| Work.perform_async(i) } }

    assert_equal b.bid, bid
    status = Robin::Batch::Status.new(bid)

    assert_predicate status, :exists?
    assert_equal 3, status.total
    assert_equal 3, status.pending
    assert_equal 3, status.jids.size
    assert(Robin::Queue.new("default").all? { |j| j.bid == bid })
    listed = Robin::Batch.list

    assert_equal [bid], listed.map { |h| h["bid"] }
    assert_equal "three", listed.first["description"]
    assert_equal %w[bid callbacks cancelled_at complete_at created_at death_at description failures parent_bid pending success_at tags total].sort,
      listed.first.keys.sort
  end

  def test_success_and_complete_fire_once
    b = Robin::Batch.new
    b.on(:complete, Callbacks, "who" => "a")
    b.on(:success, Callbacks, "who" => "a")
    b.on(:success, "BatchTest::Callbacks#custom")
    b.jobs { 20.times { |i| Work.perform_async(i) } }
    run_server(concurrency: 8) do
      eventually { Log.events.one? { |e| e[0] == :custom } }
      sleep 0.3
    end
    events = Log.events

    assert_equal 20, events.count { |e| e[0] == :work }
    assert_equal 1, events.count { |e| e[0] == :complete }
    assert_equal 1, events.count { |e| e[0] == :success }
    assert_operator events.index { |e| e[0] == :complete }, :<, events.index { |e| e[0] == :success }
    status = b.status

    assert_predicate status, :complete?
    assert_predicate status, :success?
    assert_equal 0, status.pending
  end

  def test_retry_then_success
    b = Robin::Batch.new
    b.on(:complete, Callbacks, "who" => "r")
    b.on(:success, Callbacks, "who" => "r")
    b.jobs { FailOnce.perform_async("x") }
    run_server do
      eventually { Log.events.any? { |e| e[0] == :complete } }

      assert_equal 1, b.status.failures
      refute_predicate b.status, :success?
      eventually(timeout: 8) { Log.events.any? { |e| e[0] == :success } }
    end

    assert_equal 0, b.status.failures
    assert_empty b.status.failed_jobs
  end

  def test_death_callback
    b = Robin::Batch.new
    b.on(:death, Callbacks, "who" => "d")
    b.on(:complete, Callbacks, "who" => "d")
    b.jobs { AlwaysFails.perform_async }
    run_server do
      eventually(timeout: 8) { Log.events.any? { |e| e[0] == :death } }
    end

    assert_predicate b.status, :dead?
    refute_predicate b.status, :success?
    assert_equal "RuntimeError", b.status.failed_jobs.first["error_class"]
    assert_equal 1, Log.events.count { |e| e[0] == :complete }
  end

  def test_nested_batches_from_jobs_block
    parent = Robin::Batch.new
    parent.on(:success, Callbacks, "who" => "parent")
    child = nil
    parent.jobs do
      Work.perform_async(1)
      child = Robin::Batch.new
      child.on(:success, Callbacks, "who" => "child")
      child.jobs { Work.perform_async(2) }
    end

    assert_equal parent.bid, child.parent_bid
    assert_equal [child.bid], parent.status.children
    assert_equal 2, parent.status.total
    run_server do
      eventually { Log.events.any? { |e| e[0..1] == [:success, "parent"] } }
    end
    whos = Log.events.select { |e| e[0] == :success }.map { |e| e[1] }

    assert_equal %w[child parent], whos
  end

  def test_child_batch_created_inside_running_job
    parent = Robin::Batch.new
    parent.on(:success, Callbacks, "who" => "parent")
    parent.jobs { Spawner.perform_async }
    run_server do
      eventually { Log.events.any? { |e| e[0..1] == [:success, "parent"] } }
    end
    events = Log.events

    assert_equal 3, events.count { |e| e[0] == :work }
    child_success = events.index { |e| e[0..1] == [:success, "child"] }
    parent_success = events.index { |e| e[0..1] == [:success, "parent"] }

    assert_operator child_success, :<, parent_success
  end

  def test_reopen_adds_jobs
    b = Robin::Batch.new
    b.jobs { Work.perform_async(1) }
    Robin::Batch.new(b.bid).jobs { Work.perform_async(2) }

    assert_equal 2, b.status.total
    assert_raises(Robin::Batch::NoSuchBatch) { Robin::Batch.new("nope") }
  end

  def test_empty_batch_succeeds_immediately
    b = Robin::Batch.new
    b.on(:success, Callbacks, "who" => "empty")
    b.jobs {}

    assert_predicate b.status, :success?
    assert_equal 1, Robin::Queue.new("default").size # the callback job
  end

  def test_concurrent_updates_fire_exactly_once
    b = Robin::Batch.new
    b.jobs { 50.times { |i| Work.perform_async(i) } }
    jids = b.status.jids
    threads = jids.each_slice(5).map do |slice|
      Thread.new { slice.each { |jid| Robin::Batch.job_succeeded(config, b.bid, jid) } }
    end
    threads.each(&:join)
    callbacks = Robin::Queue.new("default").select { |j| j.klass == "Robin::Batch::Callback" }

    assert_equal 1, callbacks.size
    assert_equal [b.bid, "complete", "success"], callbacks.first.args
  end

  def test_delete
    b = Robin::Batch.new
    b.jobs { Work.perform_async(1) }
    status = b.status

    assert status.delete!
    refute_predicate Robin::Batch::Status.new(b.bid), :exists?
    assert_empty Robin::Batch.list
    h = Robin::Batch::Status.new(b.bid).to_h

    assert_equal [], h["jids"]
  end
end
