# frozen_string_literal: true

require_relative "test_helper"

module JobTestJobs
  class Plain
    include Robin::Job

    def perform(*args) = [:performed, args, jid, payload]
  end

  class Configured
    include Robin::Job

    robin_options queue: :critical, retry: 3, tags: ["x"]
    robin_retry_in { |count, _ex, _payload| count * 10 }
    robin_retries_exhausted { |_payload, _ex| :exhausted }

    def perform(*) = nil
  end

  class Child < Configured
    robin_options retry: 1
  end

  class OtherConfig
    include Robin::Job

    def self.robin_config = Thread.current[:job_test_config]

    def perform = nil
  end
end

class JobTest < RobinTest
  cover "Robin::Job*"

  include JobTestJobs

  def queue_items(queue = "default")
    redis("LRANGE", config.key("queue", queue), 0, -1).reverse.map { |raw| JSON.parse(raw) }
  end

  def scheduled_items
    redis("ZRANGE", config.key("schedule"), 0, -1).map { |raw| JSON.parse(raw) }
  end

  # -- including ------------------------------------------------------------

  def test_capsule_is_the_one_whose_worker_runs_the_job
    capsule = config.default_capsule
    seen = Thread.new do
      Thread.current[:robin_capsule] = capsule
      JobTestJobs::Plain.new.capsule
    end.value

    assert_same capsule, seen
    assert_nil JobTestJobs::Plain.new.capsule
  end

  def test_include
    assert_kind_of Robin::Job::ClassMethods, Plain
    assert_includes Plain.ancestors, Robin::Job
  end

  def test_inclusion_checks_can_reject_a_class
    rejected = Class.new
    seen = []
    check = lambda do |base|
      seen << base
      raise ArgumentError, "nope" if base.equal?(rejected)
    end
    Robin::Job.inclusion_checks << check
    error = assert_raises(ArgumentError) { rejected.include(Robin::Job) }

    assert_equal "nope", error.message
    refute_includes rejected.ancestors, Robin::Job
    refute_kind_of Robin::Job::ClassMethods, rejected
    accepted = Class.new { include Robin::Job }

    assert_includes accepted.ancestors, Robin::Job
    assert_equal [rejected, accepted], seen
  ensure
    Robin::Job.inclusion_checks.delete(check)
  end

  # Robin adds none itself; its ActiveJob support adds one, once loaded
  # (as it is when every test runs in one process).
  def test_inclusion_checks_default_to_none
    active_job = Robin.const_defined?(:ActiveJob, false) && !Robin.autoload?(:ActiveJob)

    assert_equal (active_job ? [Robin::ActiveJob::REJECT_ACTIVE_JOB_CLASSES] : []), Robin::Job.inclusion_checks
    assert_same Robin::Job.inclusion_checks, Robin::Job.inclusion_checks
  end

  def test_stringify
    assert_equal({"a" => "sym", "b" => 1, "c" => "str", "d" => nil}, Robin::Job.stringify(:a => :sym, "b" => 1, :c => "str", :d => nil))
  end

  # -- instance API -----------------------------------------------------------

  def test_instance_readers_without_payload
    job = Plain.new

    assert_nil job.queue
    assert_nil job.bid
    assert_nil job.batch
    assert_equal 0, job.failures
    assert_false job.interrupted?
    assert_same Robin.logger, job.logger
  end

  def test_instance_readers_with_payload
    job = Plain.new
    job.payload = {"queue" => "q", "retry_count" => 2}

    assert_equal "q", job.queue
    assert_equal 3, job.failures
    assert_nil job.batch
    assert_nil job.bid
    job.payload = {}

    assert_nil job.queue
    assert_nil job.bid
    assert_equal 0, job.failures
    job.payload = {"retry_count" => 0}

    assert_equal 1, job.failures
    job.payload = {"retry_count" => "4"} # as another tool might store it

    assert_equal 5, job.failures
    job.interrupt_requested = :yes

    assert_true job.interrupted?
  end

  def test_batch
    batch = Robin::Batch.new
    bid = batch.jobs { Plain.perform_async(1) }
    job = Plain.new
    job.payload = {"bid" => bid}

    assert_equal bid, job.bid
    assert_instance_of Robin::Batch, job.batch
    assert_equal bid, job.batch.bid
  end

  def test_cancelled_and_progress
    job = Plain.new
    job.jid = "j1"

    refute_predicate job, :cancelled?
    Robin.cancel!("j1")

    assert_predicate job, :cancelled?
    in_batch = Plain.new.tap { |j| j.payload = {"jid" => "j2", "bid" => "b1"} }
    in_batch.jid = "j2"

    refute_predicate in_batch, :cancelled?
    Robin::Cancellation.cancel!("batch:b1")

    assert_predicate in_batch, :cancelled?
    data = job.progress!(150, "almost", step: 3)

    assert_equal({"pct" => 100.0, "msg" => "almost", "at" => data["at"], "meta" => {step: 3}}, data)
    assert_equal({"pct" => 100.0, "msg" => "almost", "at" => data["at"], "meta" => {"step" => 3}}, Robin::Progress.fetch("j1"))
    job.progress!(5)

    assert_nil Robin::Progress.fetch("j1")["msg"]
  end

  # -- options --------------------------------------------------------------

  def test_robin_options
    assert_equal({"queue" => "default", "retry" => true}, Plain.robin_options)
    assert_equal({"queue" => "critical", "retry" => 3, "tags" => ["x"]}, Configured.robin_options)
    assert_equal({"queue" => "critical", "retry" => 1, "tags" => ["x"]}, Child.robin_options)
    assert_equal({"queue" => "critical", "retry" => 3, "tags" => ["x"]}, Configured.robin_options)
    assert_same Robin::Job::DEFAULT_OPTIONS, Plain.robin_options
    assert_predicate Robin::Job::DEFAULT_OPTIONS, :frozen?
  end

  def test_robin_options_set_at_runtime
    klass = Class.new { include Robin::Job }
    klass.robin_options(:queue => :fast, "retry" => 2)

    assert_equal({"queue" => "fast", "retry" => 2}, klass.robin_options)
    assert_equal({"queue" => "critical", "retry" => 3, "tags" => ["x"]}, Class.new(Configured).robin_options)
  end

  def test_retry_hooks_set_at_runtime
    klass = Class.new { include Robin::Job }
    retry_in = proc { 1 }
    exhausted = proc { 2 }

    assert_same retry_in, klass.robin_retry_in(&retry_in)
    assert_same exhausted, klass.robin_retries_exhausted(&exhausted)
    assert_same retry_in, klass.robin_retry_in_block
    assert_same exhausted, klass.robin_retries_exhausted_block
    sub = Class.new(klass)

    assert_same retry_in, sub.robin_retry_in_block
    assert_same exhausted, sub.robin_retries_exhausted_block
  end

  def test_robin_options_inherit_from_plain_superclasses
    klass = Class.new(Plain)

    assert_same Robin::Job::DEFAULT_OPTIONS, klass.robin_options
    klass.robin_options(retry: false)

    assert_equal({"queue" => "default", "retry" => false}, klass.robin_options)
  end

  def test_reserved_options
    klass = Class.new { include Robin::Job }
    error = assert_raises(ArgumentError) { klass.robin_options(jid: 1, class: 2, queue: "ok") }
    assert_equal "reserved robin_options: jid, class", error.message
    %w[class args jid created_at enqueued_at at bid].each do |key|
      assert_raises(ArgumentError) { Class.new { include Robin::Job }.robin_options(key => 1) }
    end
  end

  def test_retry_hooks_inherit
    assert_equal 30, Configured.robin_retry_in_block.call(3, nil, nil)
    assert_same Configured.robin_retry_in_block, Child.robin_retry_in_block
    assert_equal :exhausted, Child.robin_retries_exhausted_block.call(nil, nil)
    assert_nil Plain.robin_retry_in_block
    assert_nil Plain.robin_retries_exhausted_block
    plain_child = Class.new(Plain)

    assert_nil plain_child.robin_retry_in_block
    assert_nil plain_child.robin_retries_exhausted_block
    standalone = Class.new { extend Robin::Job::ClassMethods }

    assert_nil standalone.robin_retry_in_block
    assert_nil standalone.robin_retries_exhausted_block
    assert_same Robin::Job::DEFAULT_OPTIONS, standalone.robin_options
  end

  # -- pushing --------------------------------------------------------------

  def test_perform_async
    jid = Configured.perform_async(1, "two")
    item = queue_items("critical").first

    assert_equal jid, item["jid"]
    assert_equal "JobTestJobs::Configured", item["class"]
    assert_equal [1, "two"], item["args"]
    assert_equal 3, item["retry"]
    assert_equal ["x"], item["tags"]
  end

  def test_perform_in_and_at
    now = Robin.now_ms
    jid = Plain.perform_in(60, :a.to_s)
    raw, at = redis("ZRANGE", config.key("schedule"), 0, -1, "WITHSCORES")
    item = JSON.parse(raw)

    assert_equal jid, item["jid"]
    refute item.key?("at")
    assert_in_delta Robin.epoch_seconds(now + 60_000), Float(at), 2
    Plain.perform_at(Time.now + 120, 1)

    assert_equal 2, scheduled_items.size
    Plain.perform_in(0, "now")
    Plain.perform_at(Time.now - 10, "past")

    assert_equal [["now"], ["past"]], queue_items.map { |i| i["args"] }
    refute(queue_items.any? { |i| i.key?("at") })
  end

  def test_set_stringifies_options
    seen = []
    mw = Class.new do
      define_method(:call) do |_klass, payload, _queue, _redis, &blk|
        seen << payload.slice("mode", "kind")
        blk.call
      end
    end
    config.client_middleware.add(mw)
    Plain.set(mode: :fast).set(kind: :big).perform_async

    assert_equal [{"mode" => "fast", "kind" => "big"}], seen
  end

  def test_set
    setter = Plain.set(:queue => :urgent, "tags" => ["t"])

    assert_instance_of Robin::Job::Setter, setter
    assert_same setter, setter.set(retry: :never_mind, priority: 5)
    setter.perform_async(1)
    item = queue_items("urgent").first

    assert_equal ["t"], item["tags"]
    assert_equal "never_mind", item["retry"]
    assert_equal 5, item["priority"]
  end

  def test_set_pool_pushes_to_another_redis
    with_shard { |shard| check_set_pool(shard) }
  end

  def check_set_pool(shard)
    seen = []
    mw = Class.new do
      define_method(:call) do |_klass, payload, _queue, redis, &blk|
        seen << [payload.key?("pool"), redis]
        blk.call
      end
    end
    config.client_middleware.add(mw)
    Plain.set(pool: shard).perform_async(1)
    Plain.set(queue: "q").set("pool" => shard).perform_in(30, 2)
    Plain.set(pool: shard).perform_bulk([[3]])
    Plain.set(pool: shard).set(queue: "other").perform_async(4)
    Plain.perform_async(5)

    assert_equal [1, 3, 4].map { [false, shard] } << [false, config.redis_pool], seen.values_at(0, 2, 3, 4)
    assert_equal [false, shard], seen[1]
    assert_equal [[1], [3]], shard.call("LRANGE", config.key("queue", "default"), 0, -1).reverse.map { |r| JSON.parse(r)["args"] }
    assert_equal ["q"], shard.call("ZRANGE", config.key("schedule"), 0, -1).map { |r| JSON.parse(r)["queue"] }
    assert_equal 1, shard.call("LLEN", config.key("queue", "other"))
    assert_equal [[5]], queue_items.map { |i| i["args"] }
    assert_nil Robin::Client.current_pool
  end

  def test_set_wait_and_wait_until
    Plain.set(wait: 30).perform_async(1)
    Plain.set(wait_until: Time.now + 30).perform_async(2)

    assert_equal [[1], [2]], scheduled_items.map { |i| i["args"] }.sort
    refute(scheduled_items.any? { |i| i.key?("wait") || i.key?("wait_until") })
    assert_empty queue_items
  end

  def test_set_sync_runs_inline
    result = Plain.set(sync: true).perform_async(1, {"a" => [2]})

    assert_equal :performed, result[0]
    assert_equal [1, {"a" => [2]}], result[1]
    assert_empty queue_items
  end

  def test_perform_inline_round_trips_through_json
    result = Plain.perform_inline(1, "x", {"k" => 1.5})
    _, args, jid, payload = result

    assert_equal [1, "x", {"k" => 1.5}], args
    assert_equal 24, jid.size
    assert_equal jid, payload["jid"]
    assert_equal "JobTestJobs::Plain", payload["class"]
    assert(payload.keys.all?(String))
    assert_raises(Robin::Client::ArgumentError) { Plain.perform_inline(:sym) }
  end

  def test_perform_bulk
    jids = Configured.perform_bulk([[1], [2], [3]], batch_size: 2)

    assert_equal 3, jids.size
    assert_equal jids, queue_items("critical").map { |i| i["jid"] }
    assert_equal [[1], [2], [3]], queue_items("critical").map { |i| i["args"] }
    assert_equal 3, Plain.perform_bulk([[1], [2], [3]]).compact.size
    assert_empty Plain.perform_bulk([])
  end

  def bulk_batches
    original = Robin::Client.instance_method(:push_bulk)
    sizes = []
    Robin::Client.define_method(:push_bulk) do |item|
      sizes << item["args"].size
      original.bind_call(self, item)
    end
    yield
    sizes
  ensure
    Robin::Client.define_method(:push_bulk, original)
  end

  def test_perform_bulk_batches
    assert_equal [1000, 1], bulk_batches { Plain.perform_bulk(Array.new(1001) { |i| [i] }) }
    assert_equal [2, 1], bulk_batches { Plain.perform_bulk([[1], [2], [3]], batch_size: 2) }
    assert_equal [1000, 5], bulk_batches { Plain.set(queue: "b").perform_bulk(Array.new(1005) { [] }) }
    assert_equal 2009, queue_items.size + queue_items("b").size
  end

  def test_perform_bulk_spreads_jobs_across_batches
    original = Robin.method(:now_ms)
    Robin.define_singleton_method(:now_ms) { 1_700_000_000_000 }
    sizes = bulk_batches { Plain.perform_bulk([[1], [2], [3], [4]], batch_size: 3, spread_interval: 40) }

    assert_equal [3, 1], sizes
    assert_equal [[1]], queue_items.map { |i| i["args"] }
    scores = redis("ZRANGE", config.key("schedule"), 0, -1, "WITHSCORES").each_slice(2).map { |raw, at| [JSON.parse(raw)["args"], Float(at)] }

    assert_equal [[[2], 1_700_000_010.0], [[3], 1_700_000_020.0], [[4], 1_700_000_030.0]], scores
  ensure
    Robin.define_singleton_method(:now_ms, original)
  end

  def test_setter_bulk_uses_set_options
    Plain.set(queue: "bulkq").perform_bulk([[1]])

    assert_equal 1, queue_items("bulkq").size
  end

  def test_perform_inline_uses_the_class_config
    lenient = Robin::Config.new
    lenient.strict_args = false
    klass = Class.new do
      include Robin::Job

      define_singleton_method(:robin_config) { lenient }
      def self.name = "LenientJob"

      def perform(*args) = args
    end

    assert_equal ["sym"], klass.perform_inline(:sym)
  end

  def test_robin_config_override
    other = Robin::Config.new
    other.redis = {url: REDIS_URL}
    other.key_prefix = "#{key_prefix_for_test}other:"
    Thread.current[:job_test_config] = other
    OtherConfig.perform_async
    OtherConfig.perform_bulk([[]])
    OtherConfig.perform_inline

    assert_equal 2, redis("LLEN", "#{key_prefix_for_test}other:queue:default")
    assert_equal 0, redis("LLEN", config.key("queue", "default"))
  ensure
    Thread.current[:job_test_config] = nil
    other&.redis_pool&.shutdown
  end

  def test_default_robin_config
    assert_same Robin.config, Plain.robin_config
  end
end
