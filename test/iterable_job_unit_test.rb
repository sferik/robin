# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

module IterUnit
  class << self
    attr_accessor :config
  end

  class Job
    include Robin::IterableJob

    class << self
      attr_accessor :items, :enumerator_override, :on_each
    end

    def self.robin_config = IterUnit.config

    attr_reader :events

    def initialize
      super
      @events = []
    end

    def build_enumerator(*args, cursor:)
      @events << [:build, args, cursor]
      return self.class.enumerator_override.call(cursor) if self.class.enumerator_override

      array_enumerator(self.class.items, cursor: cursor)
    end

    def each_iteration(item, *args)
      @events << [:item, item, args]
      self.class.on_each&.call(self, item)
    end

    def on_start = @events << :start

    def on_resume = @events << :resume

    def on_cancel = @events << [:cancel, cursor, current_object]

    def on_stop = @events << :stop

    def on_complete = @events << :complete
  end

  class Plain
    include Robin::IterableJob
  end

  # Quacks like an ActiveRecord relation over integer ids.
  class FakeRelation
    Record = Struct.new(:id)

    class Column
      def initialize(name) = @name = name

      def gt(value) = [:gt, @name, value]
    end

    class Table
      def [](name) = Column.new(name)
    end

    attr_reader :queries

    def initialize(ids, queries = [], order: nil, limit: nil, after: nil)
      @ids = ids
      @queries = queries
      @order = order
      @limit = limit
      @after = after
    end

    def primary_key = "id"

    def arel_table = Table.new

    def reorder(order) = FakeRelation.new(@ids, @queries, order: order, limit: @limit, after: @after)

    def limit(n) = FakeRelation.new(@ids, @queries, order: @order, limit: n, after: @after)

    def where(condition)
      op, column, value = condition
      raise "unexpected #{condition.inspect}" unless op == :gt && column == "id" && value

      FakeRelation.new(@ids, @queries, order: @order, limit: @limit, after: value)
    end

    def to_a
      @queries << {order: @order, limit: @limit, after: @after}
      raise "unordered" unless @order == {"id" => :asc}

      @ids.sort.select { |id| @after.nil? || id > @after }.first(@limit).map { |id| Record.new(id) }
    end
  end
end

class IterableJobUnitTest < RobinTest
  include IterUnit
  include RuntimeTestHelpers

  cover "Robin::IterableJob*"

  def setup
    super
    @alt = Robin::Config.new
    @alt.redis = {url: REDIS_URL}
    @alt.key_prefix = "#{key_prefix_for_test}alt:"
    IterUnit.config = @alt
    Job.items = %w[a b c]
    Job.enumerator_override = nil
    Job.on_each = nil
    @clock = 0.0
    @log = StringIO.new
    config.logger = Logger.new(@log, formatter: ->(_, _, _, msg) { "#{msg}\n" })
  end

  def teardown
    @alt.redis_pool.shutdown
    super
  end

  def alt(*) = @alt.redis { |c| c.call(*) }

  def iter_key(jid) = @alt.key("iter", jid)

  # A job whose clock advances +step+ seconds per reading.
  def build_job(jid: "j1", payload: {}, step: 0.0)
    job = Job.new
    job.jid = jid
    job.payload = {"jid" => jid, "class" => "IterUnit::Job", "args" => []}.merge(payload)
    test = self
    job.define_singleton_method(:monotonic) { test.instance_variable_set(:@clock, test.instance_variable_get(:@clock) + step) }
    job
  end

  def test_include_makes_a_job
    klass = Class.new { include Robin::IterableJob }

    assert_includes klass.ancestors, Robin::Job
    assert_respond_to klass, :perform_async
  end

  def test_default_hooks_do_nothing
    job = Plain.new

    assert_nil job.on_start
    assert_nil job.on_resume
    assert_nil job.on_cancel
    assert_nil job.on_stop
    assert_nil job.on_complete
    assert_equal :ran, job.around_iteration { :ran }
  end

  def test_around_iteration_wraps_each_iteration
    job = build_job
    job.define_singleton_method(:around_iteration) do |&iteration|
      @events << :before
      iteration.call
      @events << :after
    end
    job.perform(7, "z")

    assert_equal [:start, [:build, [7, "z"], nil], :before, [:item, "a", [7, "z"]], :after, :before, [:item, "b", [7, "z"]],
      :after, :before, [:item, "c", [7, "z"]], :after, :complete], job.events
  end

  def test_fresh_run
    job = build_job
    job.perform(7, "z")

    assert_equal [:start, [:build, [7, "z"], nil], [:item, "a", [7, "z"]], [:item, "b", [7, "z"]],
      [:item, "c", [7, "z"]], :complete], job.events
    assert_equal 2, job.cursor
    assert_equal 3, job.iterations
    assert_equal 0, alt("EXISTS", iter_key("j1"))
    assert_in_delta 100.0, Robin::Progress.fetch("j1")["pct"]
    assert_equal "3/3", Robin::Progress.fetch("j1")["msg"]
  end

  def test_resumed_progress_counts_previous_iterations
    alt("HSET", iter_key("j1"), "cursor", Robin.dump_json({"c" => 0}), "iterations", 1)
    Job.on_each = ->(job, _) { job.interrupt_requested = true }
    build_job.perform

    assert_equal "2/3", Robin::Progress.fetch("j1")["msg"]
  end

  def test_infinite_enumerators_report_a_count
    Job.enumerator_override = ->(_) { Enumerator.new(Float::INFINITY) { |y| 3.times { |i| y.yield "x", i } } }
    seen = []
    Job.on_each = ->(job, _) { seen << Robin::Progress.fetch(job.jid)&.values_at("pct", "msg", "meta") }
    build_job(step: 2.5).perform

    assert_equal [nil, nil, [nil, nil, {"iterations" => 2}]], seen
    assert_equal [nil, nil, {"iterations" => 3}], Robin::Progress.fetch("j1").values_at("pct", "msg", "meta")
  end

  def test_an_empty_enumerator_finishes_at_100_percent
    Job.items = []
    job = build_job
    job.perform

    assert_equal [:start, [:build, [], nil], :complete], job.events
    assert_equal [100.0, "0/0"], Robin::Progress.fetch("j1").values_at("pct", "msg")
  end

  def test_a_resumed_run_with_nothing_left_finishes_at_100_percent
    alt("HSET", iter_key("j1"), "cursor", Robin.dump_json({"c" => 2}), "iterations", 3)
    build_job.perform

    assert_equal [100.0, "3/3"], Robin::Progress.fetch("j1").values_at("pct", "msg")
  end

  def test_resume_from_checkpoint
    alt("HSET", iter_key("j1"), "cursor", Robin.dump_json({"c" => 0}), "iterations", 1)
    job = build_job
    job.perform

    assert_equal [:resume, [:build, [], 0], [:item, "b", []], [:item, "c", []], :complete], job.events
    assert_equal 3, job.iterations
    assert_equal 0, alt("EXISTS", iter_key("j1"))
  end

  def test_nil_enumerator_finishes_immediately
    Job.enumerator_override = ->(_) {}
    alt("HSET", iter_key("j1"), "cursor", Robin.dump_json({"c" => nil}), "iterations", 0)
    job = build_job

    assert_nil job.perform
    assert_equal [:resume, [:build, [], nil], :complete], job.events
    assert_equal 0, alt("EXISTS", iter_key("j1"))
    assert_equal [100.0, "0/0"], Robin::Progress.fetch("j1").values_at("pct", "msg")
  end

  def test_a_nil_enumerator_on_resume_counts_the_iterations_done
    Job.enumerator_override = ->(_) {}
    alt("HSET", iter_key("j1"), "cursor", Robin.dump_json({"c" => 4}), "iterations", 5)
    build_job.perform

    assert_equal [100.0, "5/5"], Robin::Progress.fetch("j1").values_at("pct", "msg")
  end

  def test_non_enumerable_is_rejected
    Job.enumerator_override = ->(_) { 42 }
    error = assert_raises(ArgumentError) { build_job.perform }

    assert_equal "IterUnit::Job#build_enumerator must return an Enumerator", error.message
  end

  def test_unsized_enumerators_report_a_count
    Job.enumerator_override = ->(_) { Enumerator.new { |y| y.yield "only", 0 } }
    job = build_job(step: 10)
    job.perform

    assert_equal [nil, nil, {"iterations" => 1}], Robin::Progress.fetch("j1").values_at("pct", "msg", "meta")
    each_only = Object.new
    def each_only.each = yield("x", 0)
    Job.enumerator_override = ->(_) { each_only }
    job = build_job(jid: "j2", step: 10)
    job.perform

    assert_includes job.events, [:item, "x", []]
    assert_equal({"iterations" => 1}, Robin::Progress.fetch("j2").fetch("meta"))
  end

  # The checkpointed iteration count seen as each item starts.
  def checkpoint_seen
    seen = []
    Job.on_each = ->(job, _) { seen << alt("HGET", iter_key(job.jid), "iterations") }
    seen
  end

  def test_checkpoints_every_five_seconds
    Job.items = %w[a b c d]
    seen = []
    Job.on_each = lambda do |job, _|
      seen << [alt("HGET", iter_key(job.jid), "iterations"), Robin::Progress.fetch(job.jid)&.fetch("msg")]
    end
    # one clock read before the loop (3), then one per item (6, 9, 12, 15)
    build_job(step: 3).perform

    assert_equal [[nil, nil], [nil, nil], ["2", "2/4"], ["2", "2/4"]], seen
  end

  def test_checkpoints_exactly_at_five_seconds
    Job.items = %w[a b c d]
    seen = checkpoint_seen
    # before the loop: 2.5; items: 5.0, 7.5 (= 5s after 2.5), 10.0, 12.5
    build_job(step: 2.5).perform

    assert_equal [nil, nil, "2", "2"], seen
  end

  def test_no_checkpoint_before_five_seconds
    Job.items = %w[a b c d]
    seen = checkpoint_seen
    build_job(step: 1.2).perform

    assert_equal [nil, nil, nil, nil], seen
  end

  def test_interrupt_checkpoints_requeues_and_stops
    Job.items = %w[a b c d]
    Job.on_each = ->(job, item) { job.interrupt_requested = true if item == "b" }
    job = build_job(payload: {"queue" => "slow", "at" => 1, "error_class" => "E", "error_message" => "m",
                              "error_backtrace" => [], "failed_at" => 1, "retried_at" => 2, "failures" => 1})

    assert_nil job.perform(5)
    assert_equal [:start, [:build, [5], nil], [:item, "a", [5]], [:item, "b", [5]], :stop], job.events
    state = alt("HGETALL", iter_key("j1")).each_slice(2).to_h

    assert_equal({"c" => 1}, Robin.load_json(state["cursor"]))
    assert_equal "2", state["iterations"]
    assert_in_delta Robin.now_ms, state["at"].to_i, 5_000
    assert_operator alt("TTL", iter_key("j1")), :>, Robin::IterableJob::STATE_TTL - 60
    progress = Robin::Progress.fetch("j1")

    assert_in_delta 50.0, progress["pct"]
    assert_equal "2/4", progress["msg"]
    assert job.payload["iteration_interrupted"]
    assert_equal "E", job.payload["error_class"] # the live payload isn't stripped
    assert_includes @log.string, "IterUnit::Job jid=j1 interrupted after 2 iterations; requeued\n"
    assert_equal ["slow"], alt("SMEMBERS", @alt.key("queues"))
    item = Robin.load_json(alt("LINDEX", @alt.key("queue", "slow"), 0))

    assert_equal %w[args class enqueued_at failures jid queue], item.keys.sort
    assert_in_delta Robin.now_ms, item["enqueued_at"], 5_000
    assert_equal "j1", item["jid"]
  end

  def test_current_object_is_the_item_being_worked_on
    seen = []
    Job.on_each = ->(job, item) { seen << [item, job.current_object, job.cursor] }
    job = build_job

    assert_nil job.current_object
    job.perform

    assert_equal [["a", "a", nil], ["b", "b", 0], ["c", "c", 1]], seen
    assert_equal "c", job.current_object
  end

  def test_max_iteration_runtime_requeues_the_job
    Job.items = %w[a b c d e]
    @alt.max_iteration_runtime = 2
    # clock: 1 at the start; a 2, b 3 -> 2s -> stop
    job = build_job(payload: {"queue" => "slow"}, step: 1)

    assert_nil job.perform
    assert_equal [:start, [:build, [], nil], [:item, "a", []], [:item, "b", []], :stop], job.events
    assert_equal({"c" => 1}, Robin.load_json(alt("HGET", iter_key("j1"), "cursor")))
    assert_equal "j1", Robin.load_json(alt("LINDEX", @alt.key("queue", "slow"), 0))["jid"]
    assert job.payload["iteration_interrupted"]
    assert_includes @log.string, "IterUnit::Job jid=j1 reached its max_iteration_runtime (2s) after 2 iterations; requeued\n"
  end

  def test_max_iteration_runtime_option_beats_the_config
    Job.items = %w[a b c d e]
    @alt.max_iteration_runtime = 100
    # clock: 0.75 at the start; a 1.5 (0.75s), b 2.25 (1.5s), c 3.0 (2.25s, past 2) -> stop
    job = build_job(payload: {"max_iteration_runtime" => 2}, step: 0.75)
    job.perform

    assert_equal [:start, [:build, [], nil], [:item, "a", []], [:item, "b", []], [:item, "c", []], :stop], job.events
  end

  def test_runs_under_max_iteration_runtime_finish
    @alt.max_iteration_runtime = 5
    job = build_job(step: 1)
    job.perform

    assert_equal :complete, job.events.last
    assert_equal 0, alt("LLEN", @alt.key("queue", "default"))
  end

  def test_requeue_defaults_to_default_queue_and_keeps_ciphertext
    Job.on_each = ->(job, _) { job.interrupt_requested = true }
    job = build_job(payload: {"args" => ["plain"]})
    Robin.remember_raw(job.payload, JSON.generate(job.payload.merge("args" => ["CIPHER"])))
    job.perform("plain")
    item = Robin.load_json(alt("RPOP", @alt.key("queue", "default")))

    assert_equal ["CIPHER"], item["args"]
    assert_equal ["plain"], job.payload["args"]
    refute item.key?("iteration_interrupted")
  end

  def test_requeue_puts_job_at_the_front
    alt("LPUSH", @alt.key("queue", "default"), "older")
    Job.on_each = ->(job, _) { job.interrupt_requested = true }
    build_job.perform

    assert_equal "j1", Robin.load_json(alt("RPOP", @alt.key("queue", "default")))["jid"]
  end

  def test_cancellation_is_checked_at_each_checkpoint
    Job.items = %w[a b c d e]
    Robin.cancel!("j1")
    alt("HSET", iter_key("j1"), "cursor", Robin.dump_json({"c" => nil}), "iterations", 0)
    job = build_job(step: 3)
    job.perform

    # clock: 3 at loop start; reads 6 (a), 9 (b) -> checkpoint -> cancelled
    assert_equal [:resume, [:build, [], nil], [:item, "a", []], [:item, "b", []], [:cancel, 1, "b"], :stop], job.events
    assert_equal 0, alt("EXISTS", iter_key("j1"))
    assert_includes @log.string, "IterUnit::Job jid=j1 cancelled after 2 iterations\n"
  end

  def test_cancellation_checked_at_exactly_five_seconds
    Job.items = %w[a b c d e]
    Robin.cancel!("j1")
    job = build_job(step: 2.5)
    job.perform

    assert_equal [:start, [:build, [], nil], [:item, "a", []], [:item, "b", []], [:cancel, 1, "b"], :stop], job.events
  end

  def test_cancellation_not_checked_before_a_checkpoint
    Job.items = %w[a b c]
    Robin.cancel!("j1")
    job = build_job(step: 1.6) # c at 6.4, 4.8s after the start
    job.perform

    assert_equal :complete, job.events.last
  end

  def test_not_cancelled_keeps_going
    job = build_job(step: 2)
    job.perform

    assert_equal :complete, job.events.last
  end

  # -- one config for the job, its progress and cancellations (the usual case) --

  # Runs a job whose robin_config is Robin.config; returns [job, the
  # commands it sent as [kind, name] pairs].
  def shared_run(*args, trips: 0.., **opts)
    IterUnit.config = config
    job = build_job(**opts)
    pool = recording_pool { assert_roundtrips(trips) { job.perform(*args) } }
    [job, pool.calls.map { |call| call.first(2) }]
  end

  def checkpoint_calls(*extra) = [[:multi], [:tx, "HSET"], [:tx, "EXPIRE"], *extra.map { |name| [:tx, name] }]

  def test_shared_checkpoints_cost_one_round_trip
    Job.items = %w[a b c d]
    # before the loop 2.5; b at 7.5 and d at 12.5 checkpoint: the state
    # read, two checkpoints, the end
    job, calls = shared_run(step: 2.5, trips: 4)

    assert_equal :complete, job.events.last
    assert_equal [[:call, "HGETALL"], *checkpoint_calls("SET", "ZMSCORE"), *checkpoint_calls("SET", "ZMSCORE"),
      [:pipelined], [:pipe, "DEL"], [:pipe, "SET"]], calls
    assert_equal 0, redis("EXISTS", config.key("iter", "j1"))
    assert_equal "4/4", Robin::Progress.fetch("j1").fetch("msg")
    assert_in_delta 100.0, Robin::Progress.fetch("j1").fetch("pct")
  end

  def test_shared_checkpoint_saves_the_progress_in_its_transaction
    Job.items = %w[a b c d]
    seen = []
    Job.on_each = ->(job, _) { seen << [redis("HGET", config.key("iter", job.jid), "iterations"), Robin::Progress.fetch(job.jid)&.fetch("msg")] }
    shared_run(step: 3)

    assert_equal [[nil, nil], [nil, nil], ["2", "2/4"], ["2", "2/4"]], seen
  end

  def test_shared_cancellation_is_checked_in_the_checkpoint
    Job.items = %w[a b c d e]
    Robin.cancel!("j1")
    job, calls = shared_run(step: 2.5)

    assert_equal [:start, [:build, [], nil], [:item, "a", []], [:item, "b", []], [:cancel, 1, "b"], :stop], job.events
    assert_equal [[:call, "HGETALL"], *checkpoint_calls("SET", "ZMSCORE"), [:call, "DEL"]], calls
    assert_equal 0, redis("EXISTS", config.key("iter", "j1"))
    assert_includes @log.string, "IterUnit::Job jid=j1 cancelled after 2 iterations\n"
  end

  def test_shared_cancellation_checks_the_job_and_its_batch
    Job.items = %w[a b c]
    zmscores = []
    IterUnit.config = config
    job = build_job(payload: {"bid" => "b1"}, step: 5)
    pool = recording_pool { job.perform }
    pool.calls.each { |call| zmscores << call.drop(1) if call[0..1] == [:tx, "ZMSCORE"] }

    assert_equal :complete, job.events.last
    assert_equal [["ZMSCORE", config.key("cancelled"), "j1", "batch:b1"]] * 3, zmscores
    Robin::Cancellation.cancel!("batch:b1")
    job = build_job(payload: {"bid" => "b1"}, step: 5)
    job.perform

    assert_equal [:start, [:build, [], nil], [:item, "a", []], [:cancel, 0, "a"], :stop], job.events
    zmscores.clear
    pool = recording_pool { build_job(step: 5).perform }
    pool.calls.each { |call| zmscores << call.drop(1) if call[0..1] == [:tx, "ZMSCORE"] }

    assert_equal [["ZMSCORE", config.key("cancelled"), "j1"]] * 3, zmscores
  end

  def test_shared_interrupt_checkpoints_and_requeues_in_one_transaction
    Job.items = %w[a b c d]
    Job.on_each = ->(job, item) { job.interrupt_requested = true if item == "b" }
    job, calls = shared_run(payload: {"queue" => "slow"})

    assert_equal [:start, [:build, [], nil], [:item, "a", []], [:item, "b", []], :stop], job.events
    assert_equal [[:call, "HGETALL"], *checkpoint_calls("SET", "SADD", "RPUSH")], calls
    assert_equal({"c" => 1}, Robin.load_json(redis("HGET", config.key("iter", "j1"), "cursor")))
    assert_equal "2/4", Robin::Progress.fetch("j1").fetch("msg")
    assert_in_delta 50.0, Robin::Progress.fetch("j1").fetch("pct")
    assert_equal ["slow"], redis("SMEMBERS", config.key("queues"))
    assert_equal "j1", Robin.load_json(redis("LINDEX", config.key("queue", "slow"), 0)).fetch("jid")
  end

  def test_shared_error_checkpoint_saves_the_progress
    Job.on_each = ->(_job, item) { raise ArgumentError, "bad item" if item == "c" }
    IterUnit.config = config
    job = build_job
    pool = recording_pool { assert_raises(ArgumentError) { job.perform } }

    assert_equal [[:call, "HGETALL"], *checkpoint_calls("SET")], pool.calls.map { |call| call.first(2) }
    assert_equal "2/3", Robin::Progress.fetch("j1").fetch("msg")
  end

  def test_shared_unsized_runs_report_a_count_in_the_same_round_trips
    Job.enumerator_override = ->(_) { Enumerator.new { |y| 2.times { |i| y.yield "x", i } } }
    IterUnit.config = config
    pool = recording_pool { build_job(step: 2.5).perform }
    counts = pool.calls.filter_map { |kind, name, *args| Robin.load_json(args[1]).fetch("meta") if name == "SET" && kind != :call }

    assert_equal [[:call, "HGETALL"], *checkpoint_calls("SET", "ZMSCORE"), [:pipelined], [:pipe, "DEL"], [:pipe, "SET"]],
      pool.calls.map { |call| call.first(2) }
    assert_equal [{"iterations" => 2}] * 2, counts # the checkpoint after the second, and the finish
    assert_equal [nil, nil, {"iterations" => 2}], Robin::Progress.fetch("j1").values_at("pct", "msg", "meta")
  end

  def test_a_job_on_another_config_reports_progress_and_checks_cancellation_apart
    Job.items = %w[a b c d]
    alt_pool = RecordingPool.new(@alt.redis_pool, nil)
    @alt.redis_pool = alt_pool
    main = recording_pool { build_job(step: 2.5).perform }
    state_writes = [[:multi], [:tx, "HSET"], [:tx, "EXPIRE"]]

    assert_equal [[:call, "HGETALL"], *state_writes, *state_writes, [:pipelined], [:pipe, "DEL"]],
      alt_pool.calls.map { |call| call.first(2) }
    assert_equal [[:call, "SET"], [:call, "ZMSCORE"], [:call, "SET"], [:call, "ZMSCORE"], [:call, "SET"]],
      main.calls.map { |call| call.first(2) }
    assert_nil Robin::Progress.fetch("j1", config: @alt)
  end

  def test_monotonic_clock
    job = Plain.new
    a = job.send(:monotonic)
    b = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_kind_of Float, a
    assert_in_delta b, a, 1
  end

  # -- enumerator helpers -------------------------------------------------------

  def test_array_enumerator
    job = Plain.new
    enum = job.array_enumerator(%w[x y z], cursor: nil)

    assert_equal [["x", 0], ["y", 1], ["z", 2]], enum.to_a
    assert_equal 3, enum.size
    resumed = job.array_enumerator(%w[x y z], cursor: 0)

    assert_equal [["y", 1], ["z", 2]], resumed.to_a
    assert_equal 2, resumed.size
    done = job.array_enumerator(%w[x y z], cursor: 5)

    assert_empty done.to_a
    assert_equal 0, done.size
    assert_raises(IndexError) { job.array_enumerator(BrokenArray.new([1, 2]), cursor: nil).to_a }
  end

  # Claims more items than it has: helpers must not silently yield nil.
  class BrokenArray < Array
    def size = super + 1
  end

  def test_csv_enumerator
    job = Plain.new
    rows = [%w[h1], %w[r1], %w[r2]]

    assert_equal [[%w[h1], 0], [%w[r1], 1], [%w[r2], 2]], job.csv_enumerator(rows, cursor: nil).to_a
    assert_equal [[%w[r2], 2]], job.csv_enumerator(rows, cursor: 1).to_a
    assert_equal [[%w[r1], 1], [%w[r2], 2]], job.csv_enumerator(rows, cursor: 0).to_a
  end

  def test_active_record_records_enumerator
    rel = FakeRelation.new([5, 1, 3, 9, 7])
    job = Plain.new
    pairs = job.active_record_records_enumerator(rel, cursor: nil, batch_size: 2).map { |r, c| [r.id, c] }

    assert_equal [[1, 1], [3, 3], [5, 5], [7, 7], [9, 9]], pairs
    assert_equal [nil, 3, 7, 9], rel.queries.map { |q| q[:after] }
    assert_equal [2], rel.queries.map { |q| q[:limit] }.uniq
  end

  def test_active_record_records_enumerator_resumes_with_default_batch_size
    rel = FakeRelation.new((1..150).to_a)
    ids = Plain.new.active_record_records_enumerator(rel, cursor: 120).map { |r, _| r.id }

    assert_equal (121..150).to_a, ids
    assert_equal [100], rel.queries.map { |q| q[:limit] }.uniq
  end

  def test_active_record_batches_enumerator
    rel = FakeRelation.new((1..5).to_a)
    batches = Plain.new.active_record_batches_enumerator(rel, cursor: 1, batch_size: 3).map { |rs, c| [rs.map(&:id), c] }

    assert_equal [[[2, 3, 4], 4], [[5], 5]], batches
    default = FakeRelation.new((1..101).to_a)

    assert_equal [100, 1], Plain.new.active_record_batches_enumerator(default, cursor: nil).map { |rs, _| rs.size }
  end

  # -- errors, slow iterations and misuse -----------------------------------------

  def test_an_error_checkpoints_the_progress_made_before_it
    Job.on_each = ->(_job, item) { raise ArgumentError, "bad item" if item == "c" }
    job = build_job
    error = assert_raises(ArgumentError) { job.perform }

    assert_equal "bad item", error.message
    assert_equal({"c" => 1}, JSON.parse(alt("HGET", iter_key("j1"), "cursor")))
    assert_equal "2", alt("HGET", iter_key("j1"), "iterations")
    assert_equal "2/3", Robin::Progress.fetch("j1").fetch("msg")
  end

  def test_an_error_on_the_first_item_saves_nothing
    Job.on_each = ->(*) { raise ArgumentError, "bad" }
    assert_raises(ArgumentError) { build_job.perform }

    assert_equal 0, alt("EXISTS", iter_key("j1"))
  end

  def test_an_error_right_after_a_checkpoint_writes_nothing_new
    Job.on_each = ->(_job, item) { raise IOError, "bad" if item == "c" }
    job = build_job(step: Robin::IterableJob::CHECKPOINT_SECONDS) # every item checkpoints
    writes = []
    job.define_singleton_method(:checkpoint) { |*args, **opts| writes << @iterations && super(*args, **opts) }
    error = assert_raises(IOError) { job.perform }

    assert_equal "bad", error.message
    assert_equal [1, 2], writes
  end

  def test_a_failing_checkpoint_keeps_the_original_error
    errors = []
    @alt.error_handlers.replace([->(ex, ctx, _) { errors << [ex.message, ctx] }])
    Job.on_each = ->(_job, item) { raise ArgumentError, "bad item" if item == "b" }
    job = build_job
    job.define_singleton_method(:checkpoint) { |*| raise "redis down" }
    error = assert_raises(ArgumentError) { job.perform }

    assert_equal "bad item", error.message
    assert_equal [["redis down", "iterable job checkpoint"]], errors.map { |m, ctx| [m, ctx.fetch(:context)] }
    assert_equal [{context: "iterable job checkpoint", job: job.payload}], errors.map(&:last)
  end

  def test_slow_iterations_warn_once
    @alt.timeout = 25
    job = build_job(step: 26) # each clock reading is 26s later
    job.perform

    assert_equal 1, @log.string.scan("longer than the 25s shutdown timeout").size
    assert_includes @log.string, "IterUnit::Job jid=j1: one iteration took 26.0s"
  end

  def test_a_slow_iteration_is_an_event
    @alt.timeout = 25
    events = []
    @alt.event_handlers << ->(name, payload) { events << [name, payload] }
    readings = [0.0, 1.0, 2.0, 40.5]
    job = build_job
    job.define_singleton_method(:monotonic) { readings.shift || 40.5 }
    job.perform

    assert_equal [["iteration.slow", {job: job.payload, seconds: 38.5}]], events
  end

  def test_iterations_within_the_timeout_dont_warn
    @alt.timeout = 25
    build_job(step: 25).perform
    build_job(step: 1).perform

    refute_includes @log.string, "shutdown timeout"
  end

  def test_a_slow_iteration_after_fast_ones_still_warns
    @alt.timeout = 25
    readings = [0.0, 1.0, 2.0, 40.0] # item c takes 38s
    job = build_job
    job.define_singleton_method(:monotonic) { readings.shift || 40.0 }
    job.perform

    assert_includes @log.string, "one iteration took 38.0s, longer than the 25s shutdown timeout"
  end

  def test_defining_perform_is_an_error
    error = assert_raises(ArgumentError) do
      Class.new do
        include Robin::IterableJob

        def perform = nil
      end
    end

    assert_match(/\A#<Class:0x\h+> includes Robin::IterableJob: define build_enumerator and each_iteration, not perform\z/, error.message)
    assert_silent { Class.new { include Robin::IterableJob }.define_method(:other) { nil } }
  end

  def test_other_method_added_hooks_still_run
    parent = Class.new do
      def self.added = @added ||= []

      def self.method_added(name) = added << name
    end
    child = Class.new(parent) { include Robin::IterableJob }
    child.define_method(:other) { nil }

    assert_includes child.added, :other
  end
end
