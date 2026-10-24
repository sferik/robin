# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"
require_relative "support/statsd_recorder"

module BatchUnit
  class Recorder
    @calls = []
    class << self
      attr_reader :calls

      def reset! = @calls.clear
    end

    def on_success(status, opts) = Recorder.calls << [:success, status.bid, opts]

    def on_complete(status, opts) = Recorder.calls << [:complete, status.bid, opts]

    def on_death(status, opts) = Recorder.calls << [:death, status.bid, opts]

    def custom(status, opts) = Recorder.calls << [:custom, status.bid, opts]
  end

  class << self
    attr_accessor :config
  end

  class Job
    include Robin::Job

    def self.robin_config = BatchUnit.config

    def perform(*) = nil
  end
end

# Fast, server-less tests that drive Robin::Batch directly.
class BatchUnitLevelTest < RobinTest
  include BatchUnit
  include RuntimeTestHelpers

  cover "Robin::Batch*"

  # Code under test must use the config it's given. The global config is a
  # decoy with a different key prefix, so anything that silently falls back
  # to Robin.config writes where these tests can't see it.
  def setup
    super
    require "robin/processor" # defines Robin::Shutdown, as in a real server
    Recorder.reset!
    @config = Robin.config
    BatchUnit.config = @config
    @decoy = Robin::Config.new
    @decoy.redis = {url: REDIS_URL}
    @decoy.key_prefix = "#{key_prefix_for_test}decoy:"
    Robin.config = @decoy
    callback_config = @config
    Robin::Batch::Callback.define_singleton_method(:robin_config) { callback_config }
  end

  def teardown
    Robin::Batch::Callback.singleton_class.remove_method(:robin_config)
    decoy_keys = redis("KEYS", "#{@decoy.key_prefix}*")
    @decoy.redis_pool.shutdown
    Robin.config = @config
    super
    raise "code under test fell back to Robin.config: #{decoy_keys}" unless decoy_keys.empty?
  end

  attr_reader :config

  def redis(*) = @config.redis { |c| c.call(*) }

  def bkey(bid, *rest) = config.key("b", bid, *rest)

  def hash(bid) = redis("HGETALL", bkey(bid)).each_slice(2).to_h

  def callback_jobs
    Robin::Queue.all(config: config).flat_map(&:to_a).select { |j| j.klass == "Robin::Batch::Callback" }
  end

  def callback_args = callback_jobs.map(&:args)

  def new_batch(**attrs)
    b = Robin::Batch.new(config: config)
    attrs.each { |k, v| b.public_send(:"#{k}=", v) }
    b
  end

  # -- class methods ---------------------------------------------------------

  def test_current_is_set_only_inside_jobs_and_restored
    assert_nil Robin::Batch.current
    outer = new_batch
    inner = new_batch
    seen = []
    outer.jobs do
      seen << Robin::Batch.current
      inner.jobs { seen << Robin::Batch.current }
      seen << Robin::Batch.current
    end

    assert_equal [outer, inner, outer], seen
    assert_nil Robin::Batch.current
  end

  def test_keys
    assert_equal [bkey("x"), "#{bkey("x")}:jids", "#{bkey("x")}:failed", "#{bkey("x")}:children"],
      Robin::Batch.keys(config, "x")
  end

  def test_list_empty
    assert_empty assert_roundtrips(1) { Robin::Batch.list(config: config) }
  end

  def test_list_newest_first_with_limit_and_pruning
    bids = 3.times.map do |i|
      b = new_batch(description: "b#{i}")
      b.jobs { nil }
      redis("ZADD", config.key("batches"), Robin.now_ms + i, b.bid) # force order
      b.bid
    end
    redis("ZADD", config.key("batches"), Robin.now_ms - Robin::Batch::TTL * 1000 - 5_000, "ancient")
    redis("ZADD", config.key("batches"), -5, "negative")
    redis("ZADD", config.key("batches"), Robin.now_ms - Robin::Batch::TTL * 1000 + 60_000, "missing-hash")

    listed = assert_roundtrips(2) { Robin::Batch.list(limit: 2, config: config) }

    assert_equal bids.last(2).reverse, listed.map { |h| h["bid"] }
    assert_equal "b2", listed.first["description"]
    assert_nil redis("ZSCORE", config.key("batches"), "ancient")
    assert_nil redis("ZSCORE", config.key("batches"), "negative")
    refute_nil redis("ZSCORE", config.key("batches"), "missing-hash")
    assert_equal bids.reverse, Robin::Batch.list(config: config).map { |h| h["bid"] }
  end

  def test_default_list_limit_is_100
    redis("ZADD", config.key("batches"), *101.times.flat_map { |i| [Robin.now_ms + i, "b#{i}"] })
    101.times { |i| redis("HSET", bkey("b#{i}"), "total", 1) }

    assert_equal 100, Robin::Batch.list(config: config).size
  end

  def test_success_fires_complete_then_chained_success
    b = new_batch
    b.on(:success, Recorder).on(:complete, Recorder)
    b.jobs { Job.perform_async }
    jid = b.status.jids.first

    assert_empty callback_args
    Robin::Batch.job_succeeded(config, b.bid, jid)

    assert_equal [[b.bid, "complete", "success"]], callback_args
    assert_predicate b.status, :complete?
    assert_predicate b.status, :success?
    assert_in_delta Robin.now_ms, b.status.to_h["complete_at"], 5_000
    assert_in_delta Robin.now_ms, b.status.to_h["success_at"], 5_000
    # a duplicate success report is ignored
    Robin::Batch.job_succeeded(config, b.bid, jid)

    assert_equal 1, callback_args.size
  end

  def test_failure_then_success
    b = new_batch
    b.jobs { 2.times { Job.perform_async } }
    j1, j2 = b.status.jids.sort
    Robin::Batch.job_failed(config, b.bid, j1, {"error_class" => "E", "error_message" => "m", "extra" => 1})

    assert_equal 1, b.status.failures
    assert_empty callback_args
    Robin::Batch.job_succeeded(config, b.bid, j2)

    assert_equal [[b.bid, "complete"]], callback_args
    refute_predicate b.status, :success?
    assert_equal [{"jid" => j1, "error_class" => "E", "error_message" => "m"}], b.status.failed_jobs
    ttl = redis("TTL", "#{bkey(b.bid)}:failed")

    assert_operator ttl, :>, Robin::Batch::TTL - 60
    assert_operator ttl, :<=, Robin::Batch::TTL
    Robin::Batch.job_succeeded(config, b.bid, j1)

    assert_equal [[b.bid, "complete"], [b.bid, "success"]], callback_args
    assert_equal 0, b.status.failures
    assert_empty b.status.failed_jobs
  end

  def test_failure_of_unknown_member_and_missing_batch_are_ignored
    b = new_batch
    b.jobs { Job.perform_async }
    Robin::Batch.job_failed(config, b.bid, "nope", {"error_class" => "E"})

    assert_equal 0, b.status.failures
    Robin::Batch.job_succeeded(config, "missing", "x")

    assert_empty callback_args
    refute_predicate Robin::Batch::Status.new("missing", config: config), :exists?
  end

  def test_job_died
    assert_nil Robin::Batch.job_died(config, {"jid" => "j"}, RuntimeError.new("x"))
    b = new_batch
    b.on(:death, Recorder)
    b.jobs { 2.times { Job.perform_async } }
    j1, j2 = b.status.jids.sort
    Robin::Batch.job_died(config, {"bid" => b.bid, "jid" => j1}, ArgumentError.new("bad"))

    assert_equal [{"jid" => j1, "error_class" => "ArgumentError", "error_message" => "bad"}], b.status.failed_jobs
    Robin::Batch.job_died(config, {"bid" => b.bid, "jid" => j2, "error_class" => "Poison", "error_message" => "pp"}, nil)

    assert_includes b.status.failed_jobs, {"jid" => j2, "error_class" => "Poison", "error_message" => "pp"}
    assert_equal({"error_class" => "Poison", "error_message" => "pp"}, Robin.load_json(redis("HGET", "#{bkey(b.bid)}:failed", j2)))
    assert_predicate b.status, :dead?
    assert_in_delta Robin.now_ms, b.status.to_h["death_at"], 5_000
    assert_equal [[b.bid, "death"], [b.bid, "complete"]].sort, callback_args.sort
  end

  # Its failure and the batch's first death: one round trip.
  def test_job_died_is_one_round_trip
    b = new_batch
    b.jobs { b.register("j1") }
    pool = recording_pool { Robin::Batch.job_died(config, {"bid" => b.bid, "jid" => "j1"}, RuntimeError.new("x")) }
    update, death = pool.calls.drop(1).first(2)

    assert_equal [:pipelined], pool.calls.first
    assert_equal [:pipe, :evalsha, Robin::Batch::UPDATE, Robin::Batch.tracking_keys(config, b.bid)], update.take(4)
    assert_equal ["failure", "j1", '{"error_class":"RuntimeError","error_message":"x"}', Robin::Batch::TTL], update.last.values_at(0, 1, 3, 4)
    assert_in_delta Robin.now_ms, update.last[2], 5_000
    assert_equal [:pipe, :evalsha, Robin::Batch::MARK_DEATH, [bkey(b.bid)]], death.take(4)
    assert_in_delta Robin.now_ms, death.last.first, 5_000
    assert_equal [b.bid, b.bid], callback_args.map(&:first)
  end

  def test_died_marks_the_first_death_only
    b = new_batch
    b.jobs { b.register("j1") }
    Robin::Batch.died(config, b.bid)
    Robin::Batch.died(config, b.bid)

    assert_equal [[b.bid, "death"]], callback_args
    assert_in_delta Robin.now_ms, b.status.to_h["death_at"], 5_000
  end

  def test_a_job_outside_any_batch_costs_no_redis_call
    pool = recording_pool { Robin::Batch.job_died(config, {"jid" => "j"}, RuntimeError.new("x")) }

    assert_empty pool.calls
  end

  def test_a_job_dying_in_a_missing_batch_does_not_create_it
    Robin::Batch.job_died(config, {"bid" => "gone", "jid" => "j"}, RuntimeError.new("x"))
    Robin::Batch.died(config, "gone")

    assert_equal 0, redis("EXISTS", bkey("gone"))
    refute_predicate Robin::Batch::Status.new("gone", config: config), :exists?
    assert_empty callback_args
  end

  def test_enqueue_callback_pushes_onto_the_callback_queue_in_one_round_trip
    assert_roundtrips(1) { Robin::Batch.enqueue_callback(config, "b1", "success", queue: "cb") }
    job = Robin::Queue.new("cb", config: config).first

    assert_equal ["b1", "success"], job.args
    assert job["batch_callback"]
    Robin::Batch.enqueue_callback(config, "unknown", "death", "x", queue: nil)

    assert_includes Robin::Queue.new("default", config: config).map(&:args), ["unknown", "death", "x"]
  end

  def test_a_job_completing_its_batch_pushes_the_callback_onto_its_queue_in_one_more_round_trip
    config.statsd = StatsdRecorder.new
    b = new_batch(callback_queue: "cb")
    b.jobs { Job.perform_async }
    jid = Robin::Queue.new("default", config: config).first.jid

    assert_roundtrips(2) { Robin::Batch.job_succeeded(config, b.bid, jid) }
    assert_equal [[b.bid, "complete", "success"]], Robin::Queue.new("cb", config: config).map(&:args)
    assert_equal %w[batch.created batch.complete batch.success batch.duration], config.statsd.calls.map { |c| c[1] }
  ensure
    config.statsd = nil
  end

  def test_a_batchs_first_death_pushes_the_callback_onto_its_queue_in_one_more_round_trip
    b = new_batch(callback_queue: "cb")
    b.jobs { Job.perform_async }

    assert_roundtrips(2) { Robin::Batch.died(config, b.bid) }
    assert_roundtrips(1) { Robin::Batch.died(config, b.bid) }
    assert_roundtrips(1) { Robin::Batch.died(config, "gone") }
    assert_equal [[b.bid, "death"]], Robin::Queue.new("cb", config: config).map(&:args)
  end

  # -- instances ---------------------------------------------------------------

  def test_new_batch_is_not_persisted_until_jobs
    b = new_batch

    assert_match(/\A\h{20}\z/, b.bid)
    assert_same config, b.config
    refute_predicate b.status, :exists?
    assert_nil b.parent_bid
    assert_nil b.parent
  end

  def test_reopen
    b = new_batch(description: "d", callback_queue: "q")
    b.on(:success, Recorder, "a" => 1)
    b.jobs { nil }
    again = Robin::Batch.new(b.bid, config: config)

    assert_equal "d", again.description
    assert_equal "q", again.callback_queue
    assert_equal({"success" => [["BatchUnit::Recorder", {"a" => 1}]]}, again.callbacks)
    error = assert_raises(Robin::Batch::NoSuchBatch) { Robin::Batch.new("nope", config: config) }
    assert_equal "no batch nope (expired or deleted?)", error.message
  end

  def test_reopened_batch_writes_callbacks_through_and_keeps_parent
    parent, child = build_family
    again = Robin::Batch.new(child.bid, config: config)

    assert_equal parent.bid, again.parent_bid
    again.on(:death, Recorder)

    assert_equal({"death" => [["BatchUnit::Recorder", {}]]}, child.status.callbacks)
    again.jobs { nil }

    assert_equal "1", hash(child.bid)["total"]
    assert_equal [child.bid], parent.status.children
  end

  def test_reopen_without_callbacks_field
    redis("HSET", bkey("raw"), "total", 0)

    assert_empty Robin::Batch.new("raw", config: config).callbacks
    assert_empty Robin::Batch::Status.new("raw", config: config).callbacks
  end

  def test_on_validates_and_normalizes
    b = new_batch
    error = assert_raises(ArgumentError) { b.on(:finish, Recorder) }
    assert_equal 'unknown batch event "finish"; expected complete, success, death', error.message
    assert_same b, b.on("complete", "BatchUnit::Recorder#custom", a: 1)
    b.on(:death, Recorder)
    b.on(:success, :Sym)

    assert_equal({"complete" => [["BatchUnit::Recorder#custom", {"a" => 1}]], "death" => [["BatchUnit::Recorder", {}]],
                  "success" => [["Sym", {}]]}, b.callbacks)
    b.callbacks["other"] = []

    refute b.callbacks.key?("other")
    assert_nil b.callbacks["missing"]
    refute_equal redis("EXISTS", bkey(b.bid)), 1
  end

  def test_on_after_persist_writes_through
    b = new_batch
    b.jobs { nil }
    b.on(:success, Recorder)

    assert_equal({"success" => [["BatchUnit::Recorder", {}]]}, Robin::Batch::Status.new(b.bid, config: config).callbacks)
  end

  def test_jobs_tags_registers_and_closes
    b = new_batch(description: "desc", callback_queue: "cbq")
    result = b.jobs { 2.times { Job.perform_async } }

    assert_equal b.bid, result
    data = hash(b.bid)

    assert_equal "2", data["pending"]
    assert_equal "2", data["total"]
    assert_equal "0", data["open"]
    assert_equal "desc", data["description"]
    assert_equal "cbq", data["callback_queue"]
    assert_nil data["parent_bid"]
    assert_in_delta Robin.now_ms, data["created_at"].to_i, 5_000
    assert_equal({}, Robin.load_json(data["callbacks"]))
    assert_equal b.bid, redis("ZRANGE", config.key("batches"), 0, -1).first
    assert_operator redis("TTL", bkey(b.bid)), :>, Robin::Batch::TTL - 60
    assert_operator redis("TTL", "#{bkey(b.bid)}:jids"), :>, Robin::Batch::TTL - 60
    assert(Robin::Queue.new("default", config: config).all? { |j| j.bid == b.bid })
    assert_equal 2, b.status.jids.size
  end

  def test_jobs_without_optional_fields
    b = new_batch
    b.jobs { nil }

    refute hash(b.bid).key?("description")
    refute hash(b.bid).key?("callback_queue")
    # a top-level batch creates nothing but its own hash and index entry
    # (plus the callback job for completing immediately)
    expected = [bkey(b.bid), config.key("batches"), config.key("queue", "default"), config.key("queues")]

    assert_equal expected.sort, redis("KEYS", "#{key_prefix_for_test}*").sort
  end

  def test_jobs_reopened_keeps_counting
    b = new_batch
    b.jobs { Job.perform_async }
    b.jobs { Job.perform_async }

    assert_equal "2", hash(b.bid)["total"]
    assert_equal "0", hash(b.bid)["open"]
  end

  def test_jobs_closes_on_exception
    b = new_batch
    assert_raises(RuntimeError) { b.jobs { raise "boom" } }

    assert_equal "0", hash(b.bid)["open"]
    assert_nil Robin::Batch.current
  end

  # -- atomic jobs blocks ------------------------------------------------------

  def queued = redis("LRANGE", config.key("queue", "default"), 0, -1).map { |raw| JSON.parse(raw) }

  def test_atomic_jobs_are_pushed_when_the_block_finishes
    b = new_batch
    inside = nil
    jids = nil
    b.jobs(atomic: true) do
      jids = [Job.perform_async(1), Job.perform_async(2)]
      inside = [queued, hash(b.bid)["total"], Robin::Batch.hold.members.size]
    end

    assert_equal [[], nil, 2], inside
    assert_equal jids, queued.reverse.map { |job| job.fetch("jid") }
    assert_equal [b.bid] * 2, queued.map { |job| job.fetch("bid") }
    assert_equal %w[2 2 0], hash(b.bid).values_at("total", "pending", "open")
    assert_equal jids.sort, b.status.jids.sort
    assert_nil Robin::Batch.hold
    assert_empty callback_args
  end

  def counting_registrations(batch)
    calls = []
    batch.define_singleton_method(:queue_register) do |tx, members|
      calls << members
      super(tx, members)
    end
    calls
  end

  def test_push_bulk_in_a_jobs_block_registers_its_jobs_together
    b = new_batch
    calls = counting_registrations(b)
    jids = nil
    inside = nil
    b.jobs do
      jids = Job.perform_bulk([[1], [2], [3]])
      inside = Robin::Batch.hold
      Job.perform_async(4)
    end

    assert_nil inside
    assert_equal [jids, [calls.last.first]], calls
    assert_equal 2, calls.size
    assert_equal %w[4 4], hash(b.bid).values_at("total", "pending")
    assert_equal [b.bid] * 4, queued.map { |job| job.fetch("bid") }
    assert_nil Robin::Batch.hold
  end

  # Registered, then pushed, in one transaction.
  def test_push_bulk_registers_before_it_pushes
    b = new_batch
    hash, jids = Robin::Batch.keys(@config, b.bid)
    pushed = nil
    pool = recording_pool { b.jobs { pushed = Job.perform_bulk([[1], [2]]) } }
    queue = config.key("queue", "default")

    assert_equal [[:multi], [:tx, "SADD", jids, *pushed], [:tx, "EXPIRE", jids, Robin::Batch::TTL],
      [:tx, "HINCRBY", hash, "pending", 2], [:tx, "HINCRBY", hash, "total", 2],
      [:tx, "SADD", config.key("queues"), "default"], [:tx, "LPUSH", queue, *redis("LRANGE", queue, 0, -1).reverse]],
      transactions(pool).fetch(1)
    assert_equal 2, queued.size
  end

  # The round trips in +pool+'s calls that are transactions, each with its
  # commands.
  def transactions(pool) = pool.calls.slice_before { |c| c[0] != :tx }.select { |trip| trip.first == [:multi] }

  # The kinds of round trips in +pool+'s calls.
  def round_trips(pool) = pool.calls.map(&:first).reject { |kind| kind == :tx || kind == :pipe }

  def test_jobs_for_another_redis_are_registered_first_then_sent
    b = new_batch
    b.jobs {}
    with_shard do |shard|
      pool = recording_pool { b.jobs { Robin::Client.via(shard) { Job.perform_bulk([[1]]) } } }

      assert_equal %i[call multi evalsha], round_trips(pool)
      assert_equal 1, shard.with { |c| c.call("LLEN", config.key("queue", "default")) }
    end
  end

  def test_jobs_of_a_batch_in_another_redis_are_registered_first_then_sent
    other = Robin::Config.new
    other.redis = {url: REDIS_URL}
    other.key_prefix = config.key_prefix
    b = Robin::Batch.new(config: other)
    b.jobs {}
    pool = recording_pool { b.jobs { Robin::Client.new(config: config).push("class" => "T", "args" => []) } }

    assert_equal %i[pipelined], round_trips(pool)
    assert_equal [1, 1], [b.status.pending, queued.count { |job| !job["batch_callback"] }]
  ensure
    other.redis_pool.shutdown
  end

  def test_jobs_that_may_be_buffered_are_registered_first_then_sent
    b = new_batch
    b.jobs {}
    config.reliable_push = true
    pool = recording_pool { b.jobs { Job.perform_async } }

    assert_equal %i[call multi pipelined evalsha], round_trips(pool)
  end

  def test_a_bulk_push_that_stops_every_job_sends_no_jobs
    b = new_batch
    b.jobs {}
    @config.client_middleware.add(Class.new { def call(*) = nil })
    pool = recording_pool { b.jobs { assert_equal [nil], Job.perform_bulk([[1]]) } }

    # (The pipeline is empty: nothing goes out.)
    assert_equal %i[call multi pipelined evalsha], round_trips(pool)
    assert_equal [1, 0], [b.status.pending, queued.count { |job| !job["batch_callback"] }]
  end

  def test_push_bulk_that_raises_registers_and_pushes_nothing
    b = new_batch
    calls = counting_registrations(b)
    @config.client_middleware.add(Class.new do
      def call(_job, payload, _queue, _redis)
        raise "boom" if payload.fetch("args") == [2]

        yield
      end
    end)
    b.jobs do
      assert_raises(RuntimeError) { Job.perform_bulk([[1], [2]]) }

      assert_nil Robin::Batch.hold
    end

    assert_empty calls
    assert_empty(queued.reject { |job| job["batch_callback"] })
    assert_equal [nil, nil], hash(b.bid).values_at("total", "pending")
  end

  def test_push_bulk_in_an_atomic_block_uses_its_hold
    b = new_batch
    calls = counting_registrations(b)
    b.jobs(atomic: true) do
      Job.perform_bulk([[1], [2]])
      Job.perform_async(3)

      assert_empty calls
    end

    assert_equal 1, calls.size
    assert_equal 3, calls.first.size
  end

  def test_holding_outside_a_batch_just_yields
    assert_equal :done, Robin::Batch.holding { Robin::Batch.hold || :done }
  end

  def test_an_atomic_block_that_raises_pushes_nothing_and_drops_new_batches
    parent = new_batch(tags: ["t"])
    child = nil
    assert_raises(RuntimeError) do
      parent.jobs(atomic: true) do
        Job.perform_async
        child = new_batch
        child.jobs { Job.perform_async }
        raise "boom"
      end
    end

    assert_empty queued
    assert_empty hash(parent.bid)
    assert_empty hash(child.bid)
    assert_empty redis("KEYS", "#{bkey(parent.bid)}*")
    assert_empty redis("ZRANGE", config.key("batches"), 0, -1)
    assert_empty redis("ZRANGE", Robin::Batch.tag_key(config, "t"), 0, -1)
    assert_nil Robin::Batch.hold
    assert_nil Robin::Batch.current
    assert_empty callback_args, "nothing completed"
  end

  def test_a_discarded_batch_is_not_touched_again
    b = new_batch
    pool = recording_pool do
      assert_raises(RuntimeError) { b.jobs(atomic: true) { raise "boom" } }
    end
    commands = pool.calls.map { |kind, *args| (kind == :evalsha) ? args.first : args.first(2) }

    refute_includes commands, Robin::Batch::UPDATE, "it isn't closed"
    refute(commands.any? { |c| c.include?("SREM") }, "nor dropped from a parent it doesn't have")
    assert_empty hash(b.bid)
  end

  def test_an_existing_batch_reopened_atomically_keeps_what_it_had
    b = new_batch
    b.jobs { Job.perform_async }
    assert_raises(RuntimeError) { b.jobs(atomic: true) { Job.perform_async && raise("boom") } }

    assert_equal %w[1 1 0], hash(b.bid).values_at("total", "pending", "open")
    assert_equal 1, queued.size
  end

  def test_a_child_dropped_from_an_existing_parent_leaves_its_children
    parent = new_batch
    parent.jobs { nil }
    child = nil
    assert_raises(RuntimeError) do
      parent.jobs(atomic: true) do
        (child = new_batch).jobs { Job.perform_async }
        raise "boom"
      end
    end

    assert_empty redis("SMEMBERS", "#{bkey(parent.bid)}:children")
    assert_nil hash(parent.bid)["total"]
    assert_equal "0", hash(parent.bid)["open"]
    assert_empty hash(child.bid)
  end

  def test_nested_atomic_blocks_share_the_outer_hold
    outer = new_batch
    inner = new_batch
    outer.jobs(atomic: true) do
      hold = Robin::Batch.hold
      inner.jobs(atomic: true) { Job.perform_async }

      assert_same hold, Robin::Batch.hold
      assert_empty queued
    end

    assert_equal 1, queued.size, "and no callback: the inner batch closed after its job was counted"
    assert_equal %w[1 1 0], hash(inner.bid).values_at("total", "pending", "open")
    assert_equal "1", hash(outer.bid)["total"], "the inner batch is the outer's child"
    assert_equal ["batch:#{inner.bid}"], redis("SMEMBERS", Robin::Batch.tracking_keys(config, outer.bid)[1])
  end

  def test_an_existing_inner_batch_still_closes_when_the_outer_block_raises
    inner = new_batch
    inner.jobs { nil }
    outer = new_batch
    assert_raises(RuntimeError) do
      outer.jobs(atomic: true) do
        inner.jobs { Job.perform_async }
        raise "boom"
      end
    end

    assert_equal "0", hash(inner.bid)["open"]
    assert_nil hash(inner.bid)["total"]
    assert_empty hash(outer.bid)
  end

  # Stand-ins for what a Hold holds: a client (its pool, and whether it
  # sends the payloads it's given straight to Redis), and a batch that
  # records what's done to it.
  HeldClient = Struct.new(:redis_pool, :direct) do
    def direct?(payloads) = direct && payloads.is_a?(Array)
  end
  HeldBatch = Struct.new(:config, :calls) do
    def close = calls << :close

    def discard! = calls << :discard!
  end

  def held_batch(pool) = HeldBatch.new(Struct.new(:redis_pool).new(pool), [])

  # Only when every job goes straight to the Redis every batch lives in
  # is there one pool to do it all in.
  def test_a_hold_shares_a_pool_only_when_everything_goes_to_one_redis
    shared = Object.new
    other = Object.new
    hold = ->(pushes, members = [[held_batch(shared), "j"]]) { Robin::Batch::Hold.new(members, pushes, [], []) }
    direct = HeldClient.new(shared, true)

    assert_same shared, hold.call([[direct, []], [direct, [{}]]]).send(:shared_pool)
    assert_nil hold.call([[direct, []]]).send(:shared_pool), "no jobs"
    assert_nil hold.call([[direct, [{}]], [HeldClient.new(other, true), [{}]]]).send(:shared_pool)
    assert_nil hold.call([[direct, [{}]], [HeldClient.new(shared, false), [{}]]]).send(:shared_pool)
    assert_nil hold.call([[direct, [{}]]], [[held_batch(shared), "j"], [held_batch(other), "k"]]).send(:shared_pool)
  end

  def test_a_discarded_hold_discards_the_batches_it_created_and_closes_the_rest
    created = held_batch(nil)
    existing = held_batch(nil)
    Robin::Batch::Hold.new([], [], [created], [created, existing]).discard

    assert_equal [[:discard!], [:close]], [created.calls, existing.calls]
  end

  def test_parent_for_new_batches
    b = new_batch

    assert_nil b.send(:parent_for_new)
    b.jobs { assert_equal b.bid, new_batch.send(:parent_for_new) }
    Thread.current[Robin::Batch::RUNNING] = "running"

    assert_equal "running", b.send(:parent_for_new)
  ensure
    Thread.current[Robin::Batch::RUNNING] = nil
  end

  class StatusKind < Robin::Batch::Status; end

  class KindRecorder
    def on_success(status, _opts) = BatchUnit::Recorder.calls << status.class
  end

  def test_callbacks_get_the_configured_status_class
    @config.batch_status_class = StatusKind
    b = new_batch
    b.on(:success, KindRecorder)
    b.jobs { nil }
    perform_callback(b.bid, "success")

    assert_equal [StatusKind], BatchUnit::Recorder.calls
    assert_same StatusKind, @config.batch_status_class
    refusing = Class.new(Robin::Batch::Status) { def initialize(*) = raise(Robin::Batch::NoSuchBatch, "gone") }
    @config.batch_status_class = refusing

    assert_nil perform_callback("missing", "success")
  ensure
    @config.batch_status_class = nil

    assert_same Robin::Batch::Status, @config.batch_status_class
  end

  def test_empty_batch_completes_and_succeeds_on_close
    b = new_batch
    b.on(:success, Recorder)
    b.jobs { nil }

    assert_equal [[b.bid, "complete", "success"]], callback_args
  end

  def test_jobs_inside_open_block_do_not_fire_early
    b = new_batch
    b.jobs do
      Job.perform_async
      Robin::Batch.job_succeeded(config, b.bid, b.status.jids.first)

      assert_empty callback_args
    end

    assert_equal 1, callback_args.size
  end

  def test_child_batch_from_context
    parent = new_batch
    child = nil
    parent.jobs do
      child = new_batch
      child.jobs { Job.perform_async }
      child.jobs { Job.perform_async } # reopening doesn't re-register
    end

    assert_equal 1, parent.status.total
    assert_equal parent.bid, child.parent_bid
    assert_equal parent.bid, child.parent.bid
    assert_equal [child.bid], parent.status.children
    assert_equal parent.bid, hash(child.bid)["parent_bid"]
    assert_equal ["batch:#{child.bid}"], redis("SMEMBERS", "#{bkey(parent.bid)}:jids")
    assert_empty parent.status.jids
    assert_operator redis("TTL", "#{bkey(parent.bid)}:children"), :>, Robin::Batch::TTL - 60
  end

  # The child counts in its parent as it's created, in the same
  # transaction; a new batch opens its first block there too.
  def test_creating_a_child_batch_is_one_transaction
    parent = new_batch
    child = nil
    pool = nil
    parent.jobs do
      child = new_batch(tags: ["t"])
      pool = recording_pool { child.jobs { nil } }
    end
    parent_hash, parent_jids = Robin::Batch.keys(config, parent.bid)
    children = Robin::Batch.keys(config, parent.bid).fetch(3)
    child_hash = bkey(child.bid)

    assert_equal [:call, "HGETALL", parent_hash], pool.calls.first
    assert_equal [:multi], pool.calls.fetch(1)
    assert_equal [["SADD", parent_jids, "batch:#{child.bid}"], ["EXPIRE", parent_jids, Robin::Batch::TTL],
      ["HINCRBY", parent_hash, "pending", 1], ["HINCRBY", parent_hash, "total", 1],
      ["SADD", children, child.bid], ["EXPIRE", children, Robin::Batch::TTL], ["HSET", child_hash],
      ["HINCRBY", child_hash, "open", 1], ["EXPIRE", child_hash, Robin::Batch::TTL], ["ZADD", config.key("batches")],
      ["ZADD", Robin::Batch.tag_key(config, "t")], ["EXPIRE", Robin::Batch.tag_key(config, "t"), Robin::Batch::TTL]],
      pool.calls.drop(2).take_while { |c| c[0] == :tx }.map { |c| (c[1] == "HSET" || c[1] == "ZADD") ? c[1, 2] : c.drop(1) }
    # Then the block closes (the callbacks for the empty child follow).
    assert_equal :evalsha, pool.calls.drop(2).find { |c| c[0] != :tx }.first
    assert_equal %w[1 1 0], hash(parent.bid).values_at("pending", "total", "open")
  end

  def test_child_batch_from_running_job
    parent = new_batch
    parent.jobs { nil }
    Thread.current[Robin::Batch::RUNNING] = parent.bid
    child = new_batch
    child.jobs { nil }

    assert_equal parent.bid, child.parent_bid
  ensure
    Thread.current[Robin::Batch::RUNNING] = nil
  end

  def test_register
    b = new_batch
    b.jobs { nil }
    b.register("m1")

    assert_equal ["m1"], redis("SMEMBERS", "#{bkey(b.bid)}:jids")
    assert_equal "1", hash(b.bid)["pending"]
    assert_equal "1", hash(b.bid)["total"]
  end

  # -- tags --------------------------------------------------------------------

  def test_tags_are_normalized_and_stored
    b = new_batch

    assert_empty b.tags
    b.tags = ["imports", :eu, "", "imports", 7]

    assert_equal %w[imports eu 7], b.tags
    b.tags = "solo"

    assert_equal ["solo"], b.tags
    b.tags = nil

    assert_empty b.tags
    b.tags = %w[a b]
    b.jobs { nil }

    assert_equal '["a","b"]', hash(b.bid)["tags"]
    assert_equal %w[a b], b.status.tags
    assert_equal %w[a b], Robin::Batch.new(b.bid, config: config).tags
    error = assert_raises(ArgumentError) { b.tags = ["late"] }
    assert_equal "a batch's tags are set before its first jobs", error.message
    assert_equal %w[a b], b.tags
    %w[a b].each do |tag|
      assert_equal [b.bid], redis("ZRANGE", Robin::Batch.tag_key(config, tag), 0, -1)
      assert_operator redis("TTL", Robin::Batch.tag_key(config, tag)), :>, Robin::Batch::TTL - 60
    end
    assert_equal config.key("batches", "tag", "x y"), Robin::Batch.tag_key(config, "x y")
  end

  def test_untagged_batches_have_no_tags
    b = new_batch
    b.jobs { nil }

    refute hash(b.bid).key?("tags")
    assert_empty b.status.tags
    assert_empty Robin::Batch.new(b.bid, config: config).tags
  end

  def test_list_by_tag
    old, other, recent = [%w[imports], %w[exports], %w[imports eu]].map do |tags|
      b = new_batch
      b.tags = tags
      b.jobs { nil }
      b.bid
    end
    redis("ZADD", Robin::Batch.tag_key(config, "imports"), Robin.now_ms + 1, recent)
    redis("ZADD", Robin::Batch.tag_key(config, "imports"), Robin.now_ms - Robin::Batch::TTL * 1000 - 5_000, "ancient")

    assert_equal [recent, old], Robin::Batch.list(tag: "imports", config: config).map { |h| h["bid"] }
    assert_equal [recent], Robin::Batch.list(tag: "imports", limit: 1, config: config).map { |h| h["bid"] }
    assert_equal [other], Robin::Batch.list(tag: "exports", config: config).map { |h| h["bid"] }
    assert_empty Robin::Batch.list(tag: "none", config: config)
    assert_nil redis("ZSCORE", Robin::Batch.tag_key(config, "imports"), "ancient")
    assert_equal 3, Robin::Batch.list(config: config).size
    Robin::Batch::Status.new(recent, config: config).delete!

    assert_equal [old], Robin::Batch.list(tag: "imports", config: config).map { |h| h["bid"] }
    assert_equal 0, redis("EXISTS", Robin::Batch.tag_key(config, "eu"))
  end

  # -- Status ------------------------------------------------------------------

  def test_status_readers_and_to_h
    b = new_batch(description: "s")
    b.jobs { Job.perform_async }
    s = b.status

    assert_equal b.bid, s.bid
    assert_equal 1, s.total
    assert_equal 1, s.pending
    assert_equal 0, s.failures
    assert_equal "s", s.description
    assert_nil s.parent_bid
    assert_kind_of Integer, s.created_at
    refute_predicate s, :complete?
    refute_predicate s, :success?
    refute_predicate s, :dead?
    refute_predicate s, :cancelled?
  end

  def test_status_to_h
    b = new_batch(description: "s")
    b.jobs { Job.perform_async }
    s = b.status
    h = s.to_h

    assert_equal %w[bid callbacks cancelled_at children complete_at created_at death_at description failed_jobs failures jids parent_bid pending success_at tags total],
      h.keys.sort
    assert_equal s.jids, h["jids"]
    assert_empty h["children"]
    assert_empty h["failed_jobs"]
    assert_nil h["complete_at"]
    assert_equal s.created_at, h["created_at"]
  end

  def test_status_progress
    b = new_batch(description: "secret")
    b.jobs { 3.times { Job.perform_async } }
    config.redis { |c| c.call("HSET", config.key("b", b.bid), "failures", 1, "pending", 2) }

    assert_equal({"bid" => b.bid, "total" => 3, "pending" => 2, "failures" => 1,
                  "complete" => false, "success" => false, "dead" => false, "cancelled" => false}, b.status.progress)
    config.redis { |c| c.call("HSET", config.key("b", b.bid), "complete_at", 1, "success_at", 1, "death_at", 1, "cancelled_at", 1) }

    assert_equal [true] * 4, b.status.progress.values_at("complete", "success", "dead", "cancelled")
  end

  def test_status_of_missing_batch
    s = Robin::Batch::Status.new("zzz", config: config)

    refute_predicate s, :exists?
    assert_nil s.created_at
    assert_equal 0, s.total
    assert_equal 0, s.pending
    assert_equal 0, s.failures
    assert_nil s.description
    assert_equal "zzz", s.to_h["bid"]
  end

  def test_defaults_to_global_config
    assert_same @decoy, Robin::Batch.new.config
    assert_empty Robin::Batch.list
    refute_predicate Robin::Batch::Status.new("zzz"), :exists?
  end

  def test_summarize_defaults
    full = Robin::Batch::Status.summarize("y", {"parent_bid" => "p", "callbacks" => '{"success":[]}', "tags" => '["t"]'})

    assert_equal "p", full["parent_bid"]
    assert_equal ["t"], full["tags"]
    assert_equal({"success" => []}, full["callbacks"])
    h = Robin::Batch::Status.summarize("x", {"complete_at" => "5"})

    assert_equal({"bid" => "x", "description" => nil, "parent_bid" => nil, "callbacks" => {}, "tags" => [], "total" => 0,
                  "pending" => 0, "failures" => 0, "created_at" => nil, "complete_at" => 5, "success_at" => nil,
                  "death_at" => nil, "cancelled_at" => nil}, h)
  end

  def test_delete
    b = new_batch
    b.jobs { Job.perform_async }
    Robin::Batch.job_failed(config, b.bid, b.status.jids.first, {"error_class" => "E"})
    s = b.status

    assert_true s.delete!
    refute_predicate s, :exists?
    assert_equal 0, redis("EXISTS", *Robin::Batch.keys(config, b.bid))
    assert_empty redis("ZRANGE", config.key("batches"), 0, -1)
  end

  # -- Callback ------------------------------------------------------------------

  def perform_callback(*) = Robin::Batch::Callback.new.perform(*)

  def test_callback_runs_targets
    b = new_batch
    b.on(:success, Recorder, "x" => 1).on(:success, "BatchUnit::Recorder#custom")
    b.jobs { nil }
    Robin::Queue.new("default", config: config).clear
    perform_callback(b.bid, "success")

    assert_equal [[:success, b.bid, {"x" => 1}], [:custom, b.bid, {}]], Recorder.calls
    assert_empty callback_args
  end

  def test_a_chained_callback_goes_to_the_batchs_callback_queue
    b = new_batch(callback_queue: "cb")
    b.jobs { nil }
    perform_callback(b.bid, "complete", "success")

    # After the one closing the (empty) batch pushed.
    assert_equal [[b.bid, "complete", "success"], [b.bid, "success"]], Robin::Queue.new("cb", config: config).map(&:args)
    assert_equal "cb", b.status.callback_queue
    assert_nil Robin::Batch::Status.new("gone", config: config).callback_queue
  end

  def test_callback_with_chain_and_missing_batch
    perform_callback("missing", "success", "x")

    assert_empty Recorder.calls
    assert_empty callback_args
    b = new_batch
    b.on(:complete, Recorder)
    b.jobs { nil }
    Robin::Queue.new("default", config: config).clear
    perform_callback(b.bid, "complete", "success")

    assert_equal [[:complete, b.bid, {}]], Recorder.calls
    assert_equal [[b.bid, "success"]], callback_args
  end

  def test_callback_method_is_everything_after_first_hash
    redis("HSET", bkey("raw"), "callbacks", Robin.dump_json({"death" => [["BatchUnit::Recorder#custom#x", {}]]}))
    error = assert_raises(NoMethodError) { perform_callback("raw", "death") }

    assert_equal :"custom#x", error.name
  end

  def test_callback_without_parent_touches_nothing_else
    %w[success complete death].each { |event| perform_callback("orphan", event) }
    redis("HSET", bkey("orphan"), "total", 0)
    pool = recording_pool { %w[success complete death].each { |event| perform_callback("orphan", event) } }

    assert_equal [bkey("orphan")], redis("KEYS", "#{key_prefix_for_test}*")
    assert_equal [:call], pool.calls.map(&:first).uniq, "it only read the batch"
  end

  def test_callback_with_nil_options
    redis("HSET", bkey("raw"), "callbacks", Robin.dump_json({"death" => [["BatchUnit::Recorder"]]}))
    perform_callback("raw", "death")

    assert_equal [[:death, "raw", {}]], Recorder.calls
  end

  def build_family
    parent = new_batch
    child = nil
    parent.jobs do
      child = new_batch
      child.jobs { Job.perform_async }
    end
    Robin::Queue.new("default", config: config).clear
    [parent, child]
  end

  def test_child_success_propagates
    parent, child = build_family
    perform_callback(child.bid, "success")

    assert_predicate parent.status, :success?
    assert_equal [[parent.bid, "complete", "success"]], callback_args
  end

  def test_child_complete_with_failures_marks_parent_failed
    parent, child = build_family
    Robin::Batch.job_failed(config, child.bid, child.status.jids.first, {"error_class" => "E"})
    perform_callback(child.bid, "complete")

    failed = parent.status.failed_jobs

    assert_equal [{"jid" => "batch:#{child.bid}", "error_class" => "Robin::Batch::ChildFailed",
                   "error_message" => "child batch #{child.bid} has 1 failure(s)"}], failed
  end

  def test_child_complete_when_successful_or_chained_does_not_fail_parent
    parent, child = build_family
    perform_callback(child.bid, "complete", "success")

    assert_empty parent.status.failed_jobs
    Robin::Batch.job_succeeded(config, child.bid, child.status.jids.first)
    Robin::Queue.new("default", config: config).clear
    perform_callback(child.bid, "complete")

    assert_empty parent.status.failed_jobs
  end

  # -- cancellation --------------------------------------------------------------

  def cancelled_members = redis("ZRANGE", config.key("cancelled"), 0, -1, "WITHSCORES").each_slice(2).to_h

  def test_cancel_marks_the_batch_and_its_descendants
    parent, child = build_family
    grandchild = nil
    Robin::Batch.new(child.bid, config: config).jobs do
      grandchild = new_batch
      grandchild.jobs { Job.perform_async }
    end
    other = new_batch.tap { |b| b.jobs { Job.perform_async } }
    batch = Robin::Batch.new(parent.bid, config: config)

    refute_predicate batch, :cancelled?
    assert_false new_batch.cancelled?
    before = Robin.now_ms

    assert_equal [parent.bid, child.bid, grandchild.bid], assert_roundtrips(2) { batch.cancel! }
    after = Robin.now_ms

    assert_predicate batch, :cancelled?
    [parent, child, grandchild].each do |b|
      status = b.status

      assert_predicate status, :cancelled?
      assert_includes before..after, status.to_h["cancelled_at"]
      assert_includes before + (Robin::Batch::TTL * 1000)..after + (Robin::Batch::TTL * 1000), cancelled_members.fetch("batch:#{b.bid}").to_i
    end
    refute_predicate other.status, :cancelled?
    refute_predicate Robin::Batch.new(other.bid, config: config), :cancelled?
    assert_predicate Robin::Batch.new(child.bid, config: config), :cancelled?
  end

  def test_cancelling_again_keeps_the_first_time
    b = new_batch.tap { |x| x.jobs { Job.perform_async } }
    redis("HSET", bkey(b.bid), "cancelled_at", 5)

    assert_equal [b.bid], b.cancel!
    assert_equal "5", hash(b.bid)["cancelled_at"]
  end

  def test_a_cancelled_batch_completes_but_never_succeeds
    b = new_batch
    b.on(:success, Recorder).on(:complete, Recorder)
    b.jobs { Job.perform_async }
    b.cancel!
    Robin::Batch.job_succeeded(config, b.bid, b.status.jids.first)

    assert_equal [[b.bid, "complete"]], callback_args
    assert_predicate b.status, :complete?
    refute_predicate b.status, :success?
  end

  def test_children_of_a_cancelled_batch_start_cancelled
    parent = new_batch.tap { |b| b.jobs { Job.perform_async } }
    parent.cancel!
    child = nil
    Robin::Batch.new(parent.bid, config: config).jobs do
      child = new_batch
      child.jobs { Job.perform_async }
    end

    assert_predicate child, :cancelled?
    assert_predicate child.status, :cancelled?
    assert cancelled_members.key?("batch:#{child.bid}")
  end

  def test_a_cancelled_child_fails_its_parent
    parent, child = build_family
    child.cancel!
    Robin::Batch.job_succeeded(config, child.bid, child.status.jids.first)
    Robin::Queue.new("default", config: config).clear
    perform_callback(child.bid, "complete")

    assert_equal [{"jid" => "batch:#{child.bid}", "error_class" => "Robin::Batch::ChildFailed",
                   "error_message" => "child batch #{child.bid} was cancelled"}], parent.status.failed_jobs
  end

  # -- StatsD ----------------------------------------------------------------------

  def test_batch_events_are_counted_in_statsd
    config.statsd = StatsdRecorder.new
    b = new_batch
    b.jobs { 2.times { Job.perform_async } }
    j1, j2 = b.status.jids.sort
    redis("HSET", bkey(b.bid), "created_at", Robin.now_ms - 5_000)
    Robin::Batch.job_failed(config, b.bid, j1, {"error_class" => "E"})
    Robin::Batch.job_succeeded(config, b.bid, j2) # complete, with a failure
    Robin::Batch.job_succeeded(config, b.bid, j1) # now successful
    Robin::Batch.died(config, b.bid)
    Robin::Batch.died(config, b.bid)
    calls = config.statsd.calls

    assert_equal [[:increment, "batch.created", 1, {}], [:increment, "batch.complete", 1, {}]], calls.first(2)
    assert_equal ["batch.duration", {}], calls[2].values_at(1, 3)
    assert_in_delta 5_000, calls[2][2], 2_000
    assert_equal [[:increment, "batch.success", 1, {}], [:increment, "batch.death", 1, {}]], calls.drop(3)
  ensure
    config.statsd = nil
  end

  def test_dogstatsd_batch_metrics_carry_the_batch_tags_and_distributions
    config.statsd = StatsdRecorder.new(dogstatsd: true, distributions: true)
    b = new_batch
    b.tags = %w[nightly eu]
    b.jobs { Job.perform_async }
    redis("HSET", bkey(b.bid), "created_at", Robin.now_ms - 5_000)
    Robin::Batch.died(config, b.bid)
    Robin::Batch.job_succeeded(config, b.bid, b.status.jids.first)
    tags = {tag: %w[nightly eu]}
    calls = config.statsd.calls

    assert_equal [[:increment, "batch.created", 1, {}], [:increment, "batch.death", 1, tags],
      [:increment, "batch.complete", 1, tags], [:increment, "batch.success", 1, tags]], calls.first(4)
    assert_equal [[:timing, "batch.duration", tags], [:distribution, "batch.duration_dist", tags]], calls.drop(4).map { |c| c.values_at(0, 1, 3) }
    assert_in_delta 5_000, calls[4][2], 2_000
    assert_equal calls[4][2], calls[5][2]
    config.statsd = StatsdRecorder.new(dogstatsd: true)
    untagged = new_batch
    untagged.jobs { nil }

    assert_equal [[:increment, "batch.created", 1, {}], [:increment, "batch.complete", 1, {tag: []}],
      [:increment, "batch.success", 1, {tag: []}], :timing], config.statsd.calls.map { |c| (c[0] == :timing) ? c[0] : c }
  ensure
    config.statsd = nil
  end

  def test_complete_and_success_together_are_both_counted
    config.statsd = StatsdRecorder.new
    b = new_batch
    b.jobs { Job.perform_async }
    Robin::Batch.job_succeeded(config, b.bid, b.status.jids.first)

    assert_equal ["batch.created", "batch.complete", "batch.success", "batch.duration"], config.statsd.calls.map { |c| c[1] }
  ensure
    config.statsd = nil
  end

  def test_cancelling_counts_every_batch_cancelled
    parent, = build_family
    config.statsd = StatsdRecorder.new
    parent.cancel!

    assert_equal [[:increment, "batch.cancelled", 2, {}]], config.statsd.calls
  ensure
    config.statsd = nil
  end

  def test_child_death_propagates
    parent, child = build_family
    parent.on(:death, Recorder)
    perform_callback(child.bid, "death")

    assert_predicate parent.status, :dead?
    assert_equal [[parent.bid, "death"]], callback_args
  end

  # -- middleware ---------------------------------------------------------------

  def client_mw = Robin::Batch::ClientMiddleware.new.tap { |m| m.config = config }

  def server_mw = Robin::Batch::ServerMiddleware.new.tap { |m| m.config = config }

  def test_client_middleware
    payload = {"jid" => "j1"}

    assert_equal :ok, client_mw.call(nil, payload, "q", nil) { :ok }
    refute payload.key?("bid")
    b = new_batch
    nil_bid = {"jid" => "j4", "bid" => nil, "batch_callback" => false}
    b.jobs do
      client_mw.call(nil, nil_bid, "q", nil) { nil }

      assert_equal :ok, client_mw.call(nil, payload, "q", nil) { :ok }
      tagged = {"jid" => "j2", "bid" => "other"}
      client_mw.call(nil, tagged, "q", nil) { nil }

      assert_equal "other", tagged["bid"]
      cb = {"jid" => "j3", "batch_callback" => true}
      client_mw.call(nil, cb, "q", nil) { nil }

      refute cb.key?("bid")
    end

    assert_equal b.bid, payload["bid"]
    assert_equal b.bid, nil_bid["bid"]
    assert_equal %w[j1 j4], b.status.jids.sort
  end

  def test_server_middleware_without_bid
    Thread.current[Robin::Batch::RUNNING] = "outer"
    seen = nil

    assert_equal :r, (server_mw.call(nil, {}, "q") do
      seen = Thread.current[Robin::Batch::RUNNING]
      :r
    end)
    assert_equal "outer", seen
  ensure
    Thread.current[Robin::Batch::RUNNING] = nil
  end

  def server_batch
    b = new_batch
    b.jobs { Job.perform_async }
    [b, b.status.jids.first]
  end

  def test_server_middleware_success
    b, jid = server_batch
    seen = nil

    assert_equal :r, (server_mw.call(nil, {"bid" => b.bid, "jid" => jid}, "q") do
      seen = Thread.current[Robin::Batch::RUNNING]
      :r
    end)
    assert_equal b.bid, seen
    assert_nil Thread.current[Robin::Batch::RUNNING]
    assert_predicate b.status, :success?
  end

  def test_server_middleware_restores_previous_running
    b, jid = server_batch
    Thread.current[Robin::Batch::RUNNING] = "outer"
    server_mw.call(nil, {"bid" => b.bid, "jid" => jid}, "q") { nil }

    assert_equal "outer", Thread.current[Robin::Batch::RUNNING]
    assert_raises(RuntimeError) { server_mw.call(nil, {"bid" => b.bid, "jid" => jid}, "q") { raise "x" } }
    assert_equal "outer", Thread.current[Robin::Batch::RUNNING]
  ensure
    Thread.current[Robin::Batch::RUNNING] = nil
  end

  def test_server_middleware_interrupted_iteration_stays_pending
    b, jid = server_batch
    server_mw.call(nil, {"bid" => b.bid, "jid" => jid, "iteration_interrupted" => true}, "q") { nil }

    assert_equal 1, b.status.pending
    server_mw.call(nil, {"bid" => b.bid, "jid" => jid, "iteration_interrupted" => false}, "q") { nil }

    assert_equal 0, b.status.pending
  end

  def test_server_middleware_discard_counts_as_success
    b, jid = server_batch
    assert_raises(Robin::Discard) { server_mw.call(nil, {"bid" => b.bid, "jid" => jid}, "q") { raise Robin::Discard } }

    assert_predicate b.status, :success?
  end

  def test_server_middleware_failure_is_recorded_and_truncated
    b, jid = server_batch
    error = assert_raises(ArgumentError) do
      server_mw.call(nil, {"bid" => b.bid, "jid" => jid}, "q") { raise ArgumentError, "a#{"x" * 1500}" }
    end

    assert_equal 1501, error.message.size
    failed = b.status.failed_jobs.first

    assert_equal "ArgumentError", failed["error_class"]
    assert_equal "a#{"x" * 999}", failed["error_message"]
  end

  def test_server_middleware_ignores_shutdown_and_over_limit
    b, jid = server_batch
    payload = {"bid" => b.bid, "jid" => jid}
    shutdown = Class.new(Robin::Shutdown)
    over = Class.new(Robin::Limiter::OverLimit)
    assert_raises(shutdown) { server_mw.call(nil, payload, "q") { raise shutdown } }
    limiter = Robin::Limiter.concurrent("x", 1, config: config)
    assert_raises(over) { server_mw.call(nil, payload, "q") { raise over.new(limiter) } }

    assert_equal 0, b.status.failures
    assert_equal 1, b.status.pending
  end

  def test_server_middleware_holds_the_failure_back_for_the_processor
    b, jid = server_batch
    payload = {"bid" => b.bid, "jid" => jid}
    held = Robin::Batch::HeldFailure.new(payload)
    outer = Robin::Batch::HeldFailure.new({})
    Thread.current[Robin::Batch::FAILURE] = outer
    pool = recording_pool do
      Robin::Batch.holding_failure(held) do
        assert_same held, Thread.current[Robin::Batch::FAILURE]
        assert_raises(ArgumentError) { server_mw.call(nil, payload, "q") { raise ArgumentError, "bad" } }
      end
    end

    assert_same outer, Thread.current[Robin::Batch::FAILURE]
    assert_empty pool.calls
    assert_equal({"error_class" => "ArgumentError", "error_message" => "bad"}, held.info)
    assert_equal 0, b.status.failures
  ensure
    Thread.current[Robin::Batch::FAILURE] = nil
  end

  def test_server_middleware_records_another_jobs_failure_itself
    b, jid = server_batch
    held = Robin::Batch::HeldFailure.new({"bid" => b.bid, "jid" => jid})

    Robin::Batch.holding_failure(held) do
      assert_raises(ArgumentError) { server_mw.call(nil, {"bid" => b.bid, "jid" => jid}, "q") { raise ArgumentError, "bad" } }
    end

    assert_nil held.info
    assert_equal 1, b.status.failures
    assert_nil Thread.current[Robin::Batch::FAILURE]
  end

  def test_holding_failure_restores_the_previous_one_when_the_job_raises
    assert_raises(RuntimeError) { Robin::Batch.holding_failure(Robin::Batch::HeldFailure.new({})) { raise "boom" } }
    assert_nil Thread.current[Robin::Batch::FAILURE]
    assert_equal :done, Robin::Batch.holding_failure(Robin::Batch::HeldFailure.new({})) { :done }
  end

  def test_client_middleware_only_applies_inside_a_jobs_block
    middleware = Robin::Batch::ClientMiddleware

    assert_false middleware.applies?(nil, {"jid" => "j"}, "q", nil)
    Thread.current[Robin::Batch::CONTEXT] = Object.new

    assert_true middleware.applies?(nil, {"jid" => "j"}, "q", nil)
  ensure
    Thread.current[Robin::Batch::CONTEXT] = nil
  end

  def test_server_middleware_only_applies_to_batch_jobs
    middleware = Robin::Batch::ServerMiddleware

    assert_true middleware.applies?(nil, {"bid" => 1}, "q")
    assert_false middleware.applies?(nil, {"jid" => "j"}, "q")
  end
end
