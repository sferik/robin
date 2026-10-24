# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

module ProcessorTestJobs
  LOG = []

  class Ok
    include Robin::Job

    def perform(*args)
      LOG << [:ok, args, jid, payload["queue"]]
      :done
    end
  end

  class Fails
    include Robin::Job

    robin_options retry: 3

    def perform = raise(ArgumentError, "nope")
  end

  class MutatesThenFails
    include Robin::Job

    def perform(opts)
      opts.delete("token")
      raise ArgumentError, "after mutating"
    end
  end

  class WrapsShutdown
    include Robin::Job

    def perform
      sleep 10
    rescue Exception # rubocop:disable Lint/RescueException
      raise ArgumentError, "cleanup failed"
    end
  end

  class Discards
    include Robin::Job

    def perform = raise(Robin::Discard, "not needed")
  end

  class Slow
    include Robin::Job

    def perform(seconds) = sleep(seconds)
  end

  # Rescues every StandardError, as plenty of real jobs do.
  class Forgiving
    include Robin::Job

    def perform(seconds)
      sleep(seconds)
    rescue
      :swallowed
    end
  end

  class Raises
    include Robin::Job

    class << self
      attr_accessor :error
    end

    def perform = raise(self.class.error)
  end

  class Bare
    def perform(x) = LOG << [:bare, x]
  end

  # Waits for GATE, then records whether it was asked to stop early.
  class Gated
    include Robin::Job

    GATE = Thread::Queue.new

    def perform
      GATE.pop
      LOG << [:gated, interrupted?]
    end
  end

  class Quiet < Robin::Discard
    def message = "custom reason"
  end

  class Unreadable < StandardError
    def message = raise(NoMethodError, "unreadable")
  end

  class UnreadableDiscard < Robin::Discard
    def message = raise(NoMethodError, "unreadable")
  end

  class Capsules
    include Robin::Job

    def perform = LOG << capsule
  end

  class DiscardsQuietly
    include Robin::Job

    def perform = raise(Quiet, "base")
  end
end

class ProcessorTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Processor*"
  cover "Robin::Shutdown*"

  class FakeManager
    attr_reader :events

    def initialize = @events = []

    def work_started(processor, unit) = @events << [:started, processor, unit.raw]

    def work_finished(processor, payload, ms, ok) = @events << [:finished, processor, payload["jid"], ms, ok]

    def processor_stopped(processor) = @events << [:stopped, processor]

    def processor_died(processor, ex) = @events << [:died, processor, ex]
  end

  # Hands out what the script returns; acknowledgements go to the real
  # fetcher.
  class ScriptedFetcher
    attr_reader :slots, :acks

    def initialize(real, &script)
      @real = real
      @script = script
      @slots = []
      @acks = []
    end

    # Like the real fetcher, acknowledges +ack+ whatever happens next.
    def fetch(slot, ack: nil)
      @slots << slot
      @acks << ack
      @real.config.redis { |c| acknowledge(c, [ack]) } if ack
      @script.call(@slots.size)
    end

    def acknowledge(conn, keys) = @real.acknowledge(conn, keys)

    def releases = @releases ||= 0

    def release
      @releases = releases + 1
    end
  end

  def setup
    super
    ProcessorTestJobs::LOG.clear
    @manager = FakeManager.new
    @fetcher = Robin::Fetcher.new(config.default_capsule, "me")
    @errors = capture_errors
  end

  def scripted(&) = ScriptedFetcher.new(@fetcher, &)

  def processor(fetcher = @fetcher, slot: 2) = Robin::Processor.new(@manager, config.default_capsule, fetcher, slot)

  def unit_for(item) = unit_in_flight(@fetcher, item.is_a?(String) ? item : JSON.generate(item), "q1")

  def job(klass, *args, **extra) = {"class" => klass.name, "args" => args, "jid" => "jid-#{klass.name.split("::").last}", "queue" => "q1"}.merge(extra.transform_keys(&:to_s))

  def inflight = in_flight(@fetcher.inflight_key)

  def finished = @manager.events.select { |e| e[0] == :finished }

  # Processes a job, then sends the acknowledgement it would otherwise
  # leave for the next fetch.
  # Runs +item+, making +trips+ round trips, then acknowledges it if
  # it's left waiting for the next fetch.
  def process(item, proc = processor, trips: 0..)
    unit = unit_for(item)
    assert_roundtrips(trips) { proc.send(:process, unit) }
    proc.send(:acknowledge_unacked)
  end

  # -- process ---------------------------------------------------------------

  def test_retries_keep_the_arguments_the_job_was_pushed_with
    process(job(ProcessorTestJobs::MutatesThenFails, {"token" => "t"}))
    stored = JSON.parse(redis("ZRANGE", config.key("retry"), 0, -1).first)

    assert_equal [{"token" => "t"}], stored.fetch("args")
    assert_equal "after mutating", stored.fetch("error_message")
  end

  def test_successful_job
    proc = processor
    item = job(ProcessorTestJobs::Ok, 1, "two")
    process(item, proc, trips: 0) # acknowledged with the next fetch

    assert_equal [[:ok, [1, "two"], "jid-Ok", "q1"]], ProcessorTestJobs::LOG
    assert_empty inflight
    assert_equal [:started, proc, JSON.generate(item)], @manager.events[0]
    _, who, jid, ms, ok = @manager.events[1]

    assert_equal [proc, "jid-Ok", true], [who, jid, ok]
    assert_kind_of Float, ms
    assert_operator ms, :>=, 0
    assert_nil proc.job
    assert_empty @errors
  end

  def test_elapsed_time_is_measured_in_milliseconds_with_one_decimal
    process(job(ProcessorTestJobs::Slow, 0.05))
    ms = finished.first[3]

    assert_operator ms, :>=, 50
    assert_operator ms, :<, 1_000
    assert_equal ms, ms.round(1)
  end

  def test_sparse_payloads_run
    process({"class" => "ProcessorTestJobs::Ok"})

    assert_equal [[:ok, [], nil, nil]], ProcessorTestJobs::LOG
    assert_empty inflight
  end

  def test_missing_class_is_a_type_error
    process({"args" => [], "jid" => "x"})

    assert_equal "TypeError", JSON.parse(redis("ZRANGE", config.key("retry"), 0, -1).first)["error_class"]
  end

  def test_discard_message_uses_message
    logs = capture_logs
    process({"class" => "ProcessorTestJobs::DiscardsQuietly"})

    assert_includes logs.string, "INFO: discarded ProcessorTestJobs::DiscardsQuietly jid=: custom reason\n"
  end

  def test_elapsed_time_comes_from_the_monotonic_clock
    proc = processor
    ticks = [10.0, 10.37546]
    proc.define_singleton_method(:monotonic) { ticks.shift }
    process(job(ProcessorTestJobs::Ok), proc)

    assert_in_delta 375.5, finished.first[3], 1e-9 # rounded to 0.1ms
    assert_in_delta Process.clock_gettime(Process::CLOCK_MONOTONIC), processor.send(:monotonic), 1
  end

  def test_invalid_json_dead_set_uses_the_processors_config
    other = Robin::Config.new
    other.redis = {url: REDIS_URL}
    other.key_prefix = "#{key_prefix_for_test}other:"
    original = Robin.config
    proc = processor
    Robin.config = other
    process("not json", proc)
    Robin.config = original

    assert_equal 1, redis("ZCARD", config.key("dead"))
  ensure
    Robin.config = original
    other.redis_pool.shutdown
  end

  def test_jobs_without_robin_accessors_still_run
    process(job(ProcessorTestJobs::Bare, 5))

    assert_equal [[:bare, 5]], ProcessorTestJobs::LOG
  end

  def test_failure_is_recorded_for_retry
    process(job(ProcessorTestJobs::Fails), trips: 1) # recorded and acknowledged together

    assert_empty inflight
    raw, score = redis("ZRANGE", config.key("retry"), 0, -1, "WITHSCORES")
    retry_item = JSON.parse(raw)

    assert_equal "ArgumentError", retry_item["error_class"]
    assert_equal 0, retry_item["retry_count"]
    refute retry_item.key?("at")
    assert_false finished.first[4]
    ex, ctx = @errors.first

    assert_equal "nope", ex.message
    assert_equal({context: "job raised", job: retry_item.merge("at" => Float(score)), queue: "q1"}, ctx)
  end

  def test_error_handlers_run_in_the_jobs_logging_context
    seen = []
    config.error_handlers << ->(_ex, _ctx, _cfg) { seen << Robin::Context.current.dup }
    process(job(ProcessorTestJobs::Fails, bid: "b1", tags: %w[a b]))

    assert_equal [{class: "ProcessorTestJobs::Fails", jid: "jid-Fails", bid: "b1", tags: "a,b"}], seen
    assert_empty Robin::Context.current
  end

  def test_success_of_a_recovered_job_clears_its_orphan_counter_in_the_same_round_trip
    orphan = config.key("orphan", "jid-Ok")
    redis("SET", orphan, "2")
    unit = unit_for(job(ProcessorTestJobs::Ok, recovered: true))
    worker = processor
    pool = recording_pool { assert_roundtrips(1) { worker.send(:process, unit) } }

    assert_equal 0, redis("EXISTS", orphan)
    assert_empty inflight
    assert_equal [[:pipelined], [:pipe, "DEL", unit.key], [:pipe, "SREM", @fetcher.inflight_key, unit.key], [:pipe, "DEL", orphan]], pool.calls
    assert_nil worker.unacked, "acknowledged already"
  end

  def test_discarded_recovered_jobs_clear_their_orphan_counter
    redis("SET", config.key("orphan", "jid-Discards"), "2")
    process(job(ProcessorTestJobs::Discards, recovered: true))

    assert_equal 0, redis("EXISTS", config.key("orphan", "jid-Discards"))
    assert_empty inflight
  end

  def test_jobs_that_were_never_recovered_skip_the_orphan_counter
    redis("SET", config.key("orphan", "jid-Ok"), "2")
    unit = unit_for(job(ProcessorTestJobs::Ok))
    worker = processor
    pool = recording_pool do
      worker.send(:process, unit)
      worker.send(:acknowledge_unacked)
    end

    assert_equal "2", redis("GET", config.key("orphan", "jid-Ok"))
    assert_equal [[:call, "DEL", unit.key]], pool.calls
    assert_empty inflight
  end

  def test_failures_with_unreadable_or_binary_messages_are_recorded
    [[ProcessorTestJobs::Unreadable, "(NoMethodError raised reading the error message)"],
      [RuntimeError.new("bin \xFF".b), "bin \uFFFD"]].each do |error, recorded|
      redis("DEL", config.key("retry"))
      ProcessorTestJobs::Raises.error = error
      process(job(ProcessorTestJobs::Raises))

      assert_empty inflight
      assert_equal [recorded], redis("ZRANGE", config.key("retry"), 0, -1).map { |r| JSON.parse(r)["error_message"] }
    end
  end

  def test_discards_with_unreadable_messages_are_logged
    ProcessorTestJobs::Raises.error = ProcessorTestJobs::UnreadableDiscard
    logs = capture_logs
    process(job(ProcessorTestJobs::Raises))

    assert_empty inflight
    assert_includes logs.string, "discarded ProcessorTestJobs::Raises jid=jid-Raises: (NoMethodError raised reading the error message)\n"
  end

  def test_unknown_class_is_a_failure
    process({"class" => "No::Such::Job", "args" => [], "jid" => "x", "queue" => "q1"})

    assert_equal "NameError", JSON.parse(redis("ZRANGE", config.key("retry"), 0, -1).first)["error_class"]
  end

  def test_nested_class_names_resolve
    process(job(ProcessorTestJobs::Ok))

    assert_equal 1, ProcessorTestJobs::LOG.size
  end

  def test_discard_acknowledges_quietly
    logs = capture_logs
    process(job(ProcessorTestJobs::Discards), trips: 0)

    assert_empty inflight
    assert_equal 0, redis("ZCARD", config.key("retry"))
    assert_true finished.first[4]
    assert_includes logs.string, "INFO: discarded ProcessorTestJobs::Discards jid=jid-Discards: not needed\n"
    assert_empty @errors
  end

  def test_discards_are_events
    events = capture_events
    item = job(ProcessorTestJobs::Discards)
    process(item)

    assert_equal 1, events.size
    name, payload = events.first

    assert_equal "job.discarded", name
    assert_equal [:job, :error], payload.keys
    assert_equal item, payload.fetch(:job)
    assert_instance_of Robin::Discard, payload.fetch(:error)
    assert_equal "not needed", payload.fetch(:error).message
  end

  def test_invalid_json_goes_to_dead_set
    raw = "{not json #{"x" * 300}"
    process(raw)

    assert_empty inflight
    assert_equal [raw], redis("ZRANGE", config.key("dead"), 0, -1)
    ex, ctx = @errors.first

    assert_kind_of JSON::ParserError, ex
    assert_equal({context: "invalid JSON job payload", queue: "q1", raw: raw[0, 200]}, ctx)
    assert_empty @manager.events
  end

  def test_cancelled_job_without_class_is_logged
    redis("ZADD", config.key("cancelled"), Robin.now_ms + 60_000, "c1")
    config.redis { |c| Robin::Cancellation.refresh(config, c) }
    logs = capture_logs
    stub_method(Robin::Batch, :job_succeeded, ->(*) { flunk "a nil bid isn't a batch" }) do
      process({"jid" => "c1", "bid" => nil})
    end

    assert_equal "INFO: skipping cancelled job  jid=c1\n", logs.string
  ensure
    redis("DEL", config.key("cancelled"))
    config.redis { |c| Robin::Cancellation.refresh(config, c) }
  end

  def test_cancelled_jobs_are_skipped
    redis("ZADD", config.key("cancelled"), Robin.now_ms + 60_000, "jid-Ok")
    config.redis { |c| Robin::Cancellation.refresh(config, c) }
    logs = capture_logs
    process(job(ProcessorTestJobs::Ok))

    assert_empty ProcessorTestJobs::LOG
    assert_empty inflight
    assert_empty @manager.events
    assert_equal "INFO: skipping cancelled job ProcessorTestJobs::Ok jid=jid-Ok\n", logs.string
  end

  def test_cancelled_jobs_are_events
    redis("ZADD", config.key("cancelled"), Robin.now_ms + 60_000, "jid-Ok")
    config.redis { |c| Robin::Cancellation.refresh(config, c) }
    events = capture_events
    item = job(ProcessorTestJobs::Ok)
    process(item)

    assert_equal [["job.skipped", {job: item, reason: "cancelled"}]], events
  end

  def test_jobs_of_cancelled_batches_are_skipped
    redis("ZADD", config.key("cancelled"), Robin.now_ms + 60_000, "batch:b1")
    config.redis { |c| Robin::Cancellation.refresh(config, c) }
    calls = []
    stub_method(Robin::Batch, :job_succeeded, ->(*args) { calls << args }) do
      process(job(ProcessorTestJobs::Ok, bid: "b1"))
    end

    assert_empty ProcessorTestJobs::LOG
    assert_empty inflight
    assert_equal [[config, "b1", "jid-Ok"]], calls
  ensure
    redis("DEL", config.key("cancelled"))
  end

  # Like a finished job's, the acknowledgement waits for the next fetch.
  def test_skipping_a_cancelled_job_costs_no_round_trip
    redis("ZADD", config.key("cancelled"), Robin.now_ms + 60_000, "jid-Ok")
    config.redis { |c| Robin::Cancellation.refresh(config, c) }
    item = job(ProcessorTestJobs::Ok)
    unit = unit_for(item)
    worker = processor
    pool = recording_pool { worker.send(:process, unit) }

    assert_empty pool.calls
    assert_equal unit.key, worker.unacked
    assert_equal [unit.raw], inflight
    recovered = job(ProcessorTestJobs::Ok, recovered: true)
    redis("SET", config.key("orphan", "jid-Ok"), 1)
    worker.send(:process, unit_for(recovered))

    assert_equal [unit.raw], inflight, "a recovered one is acknowledged right away"
    assert_equal 0, redis("EXISTS", config.key("orphan", "jid-Ok"))
  ensure
    redis("DEL", config.key("cancelled"))
    config.redis { |c| Robin::Cancellation.refresh(config, c) }
  end

  def test_cancelled_batch_jobs_count_as_done_for_the_batch
    redis("ZADD", config.key("cancelled"), Robin.now_ms + 60_000, "jid-Ok")
    config.redis { |c| Robin::Cancellation.refresh(config, c) }
    calls = []
    stub_method(Robin::Batch, :job_succeeded, ->(*args) { calls << args }) do
      process(job(ProcessorTestJobs::Ok, bid: "b1"))
      redis("ZADD", config.key("cancelled"), Robin.now_ms + 60_000, "other")
      config.redis { |c| Robin::Cancellation.refresh(config, c) }
      process(job(ProcessorTestJobs::Ok).merge("jid" => "other"))
    end

    assert_equal [[config, "b1", "jid-Ok"]], calls
  ensure
    redis("DEL", config.key("cancelled"))
    config.redis { |c| Robin::Cancellation.refresh(config, c) }
  end

  def test_shutdown_leaves_job_in_flight
    ProcessorTestJobs::Raises.error = Robin::Shutdown
    item = job(ProcessorTestJobs::Raises)

    assert_raises(Robin::Shutdown) { process(item) }
    assert_equal [JSON.generate(item)], inflight
    assert_false finished.first[4]
    assert_empty @errors
  end

  def test_system_exit_and_no_memory_propagate_unrecorded
    [SystemExit, NoMemoryError, Class.new(SystemExit), Class.new(NoMemoryError)].each do |klass|
      ProcessorTestJobs::Raises.error = klass
      assert_raises(klass) { process(job(ProcessorTestJobs::Raises)) }
    end

    assert_empty @errors
    assert_equal 0, redis("ZCARD", config.key("retry"))
    assert_equal 4, inflight.size
  end

  def test_script_errors_are_recorded_and_contained
    ProcessorTestJobs::Raises.error = NotImplementedError
    process(job(ProcessorTestJobs::Raises))

    assert_equal 1, redis("ZCARD", config.key("retry"))
    assert_equal [NotImplementedError], @errors.map { |e| e[0].class }
  end

  def test_other_exceptions_are_recorded_then_reraised
    ProcessorTestJobs::Raises.error = Interrupt

    assert_raises(Interrupt) { process(job(ProcessorTestJobs::Raises)) }
    assert_equal 1, redis("ZCARD", config.key("retry"))
    assert_empty inflight
  end

  def test_failure_to_record_a_failure_is_reported
    retrier = Object.new
    retrier.define_singleton_method(:handle) { |*| raise Robin::Redis::ConnectionError, "redis down" }
    proc = processor
    proc.instance_variable_set(:@retrier, retrier)
    item = job(ProcessorTestJobs::Fails)
    process(item, proc)

    assert_equal [JSON.generate(item)], inflight
    assert_equal ["nope", "redis down"], @errors.map { |e| e[0].message }
    assert_equal({context: "recording job failure", job: item.merge("x" => 1).except("x")}, @errors.last[1])
  end

  def test_retrier_receives_unit_payload_class_and_error
    seen = nil
    retrier = Object.new
    retrier.define_singleton_method(:handle) { |*args| seen = args }
    proc = processor
    proc.instance_variable_set(:@retrier, retrier)
    item = job(ProcessorTestJobs::Fails)
    process(item, proc)
    unit, payload, klass, ex = seen

    assert_equal JSON.generate(item), unit.raw
    assert_equal item, payload
    assert_equal ProcessorTestJobs::Fails, klass
    assert_equal "nope", ex.message
  end

  # -- a batch job's failure is recorded with its retry --------------------------

  # A batch with one pending job, +jid+.
  def batch_of_one(jid)
    batch = Robin::Batch.new(config: config)
    batch.jobs { batch.register(jid) }
    batch
  end

  def failed_members(batch) = redis("HGETALL", Robin::Batch.tracking_keys(config, batch.bid).last).each_slice(2).to_h

  def nope = '{"error_class":"ArgumentError","error_message":"nope"}'

  def test_a_failing_batch_job_records_its_failure_with_the_retry_in_one_round_trip
    batch = batch_of_one("jid-Fails")
    unit = unit_for(job(ProcessorTestJobs::Fails, bid: batch.bid))
    worker = processor
    pool = recording_pool { assert_roundtrips(2) { worker.send(:process, unit) } }
    update, zadd, del, srem = pool.calls.drop(1).take_while { |c| c[0] == :tx }

    # The transaction, then the complete callback's push.
    assert_equal [:multi, :tx, :tx, :tx, :tx, :pipelined], pool.calls.map(&:first).reject { |kind| kind == :pipe }
    assert_equal [:tx, :evalsha, Robin::Batch::UPDATE, Robin::Batch.tracking_keys(config, batch.bid)], update.take(4)
    assert_equal ["failure", "jid-Fails", nope], update.last.values_at(0, 1, 3)
    assert_equal [[:tx, "ZADD"], [:tx, "DEL", unit.key], [:tx, "SREM", @fetcher.inflight_key, unit.key]], [zadd.take(2), del, srem]
    assert_equal({"jid-Fails" => nope}, failed_members(batch))
    assert_equal 1, redis("ZCARD", config.key("retry"))
    assert_empty inflight
    assert_predicate batch.status, :complete?
  end

  def test_retrier_gets_no_batch_failure_outside_a_batch
    seen = nil
    retrier = Object.new
    retrier.define_singleton_method(:handle) { |*, **opts| seen = opts }
    proc = processor
    proc.instance_variable_set(:@retrier, retrier)
    process(job(ProcessorTestJobs::Fails), proc)

    assert_equal({batch_failure: nil}, seen)
    batch = batch_of_one("jid-Fails")
    process(job(ProcessorTestJobs::Fails, bid: batch.bid), proc)

    assert_equal({batch_failure: {"error_class" => "ArgumentError", "error_message" => "nope"}}, seen)
    assert_empty failed_members(batch), "the retrier records it"
  end

  # An outer middleware that turns the job's error into +outcome+.
  def outer_middleware(outcome)
    Class.new do
      define_method(:call) do |*, &blk|
        blk.call
      rescue ArgumentError
        outcome.call
      end
    end
  end

  def test_a_batch_failure_that_never_reaches_the_retrier_is_recorded_on_the_way_out
    [-> { :swallowed }, -> { raise Class.new(Robin::Discard) }].each do |outcome|
      outer = outer_middleware(outcome)
      config.server_middleware.prepend(outer)
      batch = batch_of_one("jid-Fails")
      process(job(ProcessorTestJobs::Fails, bid: batch.bid))

      assert_equal({"jid-Fails" => nope}, failed_members(batch))
      assert_equal 0, redis("ZCARD", config.key("retry"))
      assert_empty inflight
      config.server_middleware.remove(outer)
    end
  end

  def test_a_batch_failure_turned_into_an_exit_is_recorded_and_the_exit_goes_on
    [Class.new(SystemExit), Class.new(NoMemoryError)].each do |fatal|
      outer = outer_middleware(-> { raise fatal })
      config.server_middleware.prepend(outer)
      batch = batch_of_one("jid-Fails")
      item = job(ProcessorTestJobs::Fails, bid: batch.bid)

      assert_raises(fatal) { processor.send(:process, unit_for(item)) }
      assert_equal({"jid-Fails" => nope}, failed_members(batch))
      assert_equal 0, redis("ZCARD", config.key("retry"))
      config.server_middleware.remove(outer)
    end
  end

  # A batch job an outer middleware stops before it runs neither fails
  # nor succeeds: it's still pending.
  def test_a_batch_job_that_never_ran_records_nothing
    config.server_middleware.prepend(Class.new { def call(*) = nil })
    batch = batch_of_one("jid-Fails")
    process(job(ProcessorTestJobs::Fails, bid: batch.bid))

    assert_empty failed_members(batch)
    assert_equal [1, 0], [batch.status.pending, batch.status.failures]
  end

  # Only a batch job's failure is held back, and a success holds none.
  def test_only_batch_jobs_hold_their_failure
    seen = []
    config.job_wrapper = lambda do |payload, &blk|
      seen << [payload.fetch("jid"), Thread.current[Robin::Batch::FAILURE]&.payload]
      blk.call
    end
    batch = batch_of_one("jid-Ok")
    item = job(ProcessorTestJobs::Ok, bid: batch.bid)
    process(item)
    process(job(ProcessorTestJobs::Ok).merge("jid" => "plain"))

    assert_equal [["jid-Ok", item], ["plain", nil]], seen
    assert_empty failed_members(batch)
    assert_predicate batch.status, :success?
  end

  def test_a_batch_failure_turned_into_a_shutdown_is_recorded_and_the_job_left_in_flight
    config.server_middleware.prepend(outer_middleware(-> { raise Robin::Shutdown }))
    batch = batch_of_one("jid-Fails")
    item = job(ProcessorTestJobs::Fails, bid: batch.bid)

    assert_raises(Robin::Shutdown) { processor.send(:process, unit_for(item)) }
    assert_equal({"jid-Fails" => nope}, failed_members(batch))
    assert_equal [JSON.generate(item)], inflight
  end

  def test_a_batch_failure_that_cannot_be_recorded_is_handled_like_the_jobs_error
    config.server_middleware.prepend(outer_middleware(-> { :swallowed }))
    batch = batch_of_one("jid-Fails")
    item = job(ProcessorTestJobs::Fails, bid: batch.bid)
    down = ->(kind, args) { (kind == :evalsha && args.first.equal?(Robin::Batch::UPDATE)) ? raise(Robin::Redis::ConnectionError, "down") : :forward }
    recording_pool(down) { process(item) }

    assert_equal ["down"], @errors.map { |e| e[0].message }
    assert_empty failed_members(batch)
    assert_equal ["Robin::Redis::ConnectionError"], redis("ZRANGE", config.key("retry"), 0, -1).map { |raw| JSON.parse(raw).fetch("error_class") }
  end

  def test_held_batch_failures_are_only_this_jobs
    held = Robin::Batch::HeldFailure.new({"bid" => "b"})
    other = {"bid" => "b", "jid" => "j"}
    Robin::Batch.holding_failure(held) do
      stub_method(Robin::Batch, :job_failed, ->(*args) { held.info = args }) { Robin::Batch.failed(config, other, {"e" => 1}) }
    end

    assert_equal [config, "b", "j", {"e" => 1}], held.info
    assert_nil Thread.current[Robin::Batch::FAILURE]
  end

  def test_missing_class_is_retried_as_object
    seen = nil
    retrier = Object.new
    retrier.define_singleton_method(:handle) { |*args| seen = args }
    proc = processor
    proc.instance_variable_set(:@retrier, retrier)
    process({"class" => "Nope", "args" => [], "jid" => "j", "queue" => "q1"}, proc)

    assert_equal Object, seen[2]
  end

  def test_job_timeout
    item = job(ProcessorTestJobs::Slow, 5, timeout: 0.05)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    process(item)

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_equal "Robin::Job::Timeout", JSON.parse(redis("ZRANGE", config.key("retry"), 0, -1).first)["error_class"]
  end

  def test_job_timeout_subclasses_are_recorded_too
    sub = Class.new(Robin::Job::Timeout)
    job_class = Class.new do
      include Robin::Job

      define_method(:perform) { raise sub, "custom deadline" }
    end
    stub_const = ProcessorTestJobs.const_set(:RaisesTimeoutSubclass, job_class)
    process(job(stub_const))

    assert_equal 1, redis("ZCARD", config.key("retry"))
  ensure
    ProcessorTestJobs.send(:remove_const, :RaisesTimeoutSubclass)
  end

  def test_job_timeout_is_not_a_standard_error
    refute_includes Robin::Job::Timeout.ancestors, StandardError
    item = job(ProcessorTestJobs::Forgiving, 5, timeout: 0.05)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # The worker records the failure and carries on (process returns).
    process(item)

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_equal "Robin::Job::Timeout", JSON.parse(redis("ZRANGE", config.key("retry"), 0, -1).first)["error_class"]
  end

  def test_timeout_string_values_are_seconds
    process(job(ProcessorTestJobs::Slow, 0.01, timeout: "2"))

    assert_equal 0, redis("ZCARD", config.key("retry"))
  end

  def test_middleware_and_logger_wrap_the_job
    order = []
    mw = Class.new do
      define_method(:call) do |job, payload, queue, &blk|
        order << [:mw, job.class, payload["jid"], queue]
        blk.call
      end
    end
    config.server_middleware.add(mw)
    io = capture_logs
    process(job(ProcessorTestJobs::Ok))

    assert_equal [[:mw, ProcessorTestJobs::Ok, "jid-Ok", "q1"]], order
    assert_equal %w[start done], io.string.lines.map { |l| l.split(": ", 2).last.strip }
  end

  def test_job_wrapper_wraps_execution
    calls = []
    config.job_wrapper = lambda do |payload, &blk|
      calls << payload["jid"]
      blk.call
    end
    process(job(ProcessorTestJobs::Ok))

    assert_equal ["jid-Ok"], calls
    assert_equal 1, ProcessorTestJobs::LOG.size
  end

  def test_current_job_is_exposed_while_running
    proc = processor
    seen = []
    config.server_middleware.add(Class.new do
      define_method(:call) do |job, *_rest, &blk|
        seen << job
        blk.call
      end
    end)
    probe = ->(*) { seen << proc.job }
    stub_method(ProcessorTestJobs::Ok, :new, lambda { |*|
      instance = ProcessorTestJobs::Ok.allocate
      instance.define_singleton_method(:perform) { |*| probe.call }
      instance
    }) do
      process(job(ProcessorTestJobs::Ok), proc)
    end

    assert_same seen[0], seen[1]
    assert_nil proc.job
  end

  # -- lifecycle -------------------------------------------------------------

  def test_terminate_flags_the_running_job
    proc = processor
    job_instance = ProcessorTestJobs::Ok.new
    proc.instance_variable_set(:@job, job_instance)
    proc.terminate

    assert_predicate job_instance, :interrupted?
    assert proc.instance_variable_get(:@done)
    processor.terminate # no job: nothing to flag
  end

  def test_retire_stops_after_the_current_job_without_interrupting_it
    proc = processor
    job_instance = ProcessorTestJobs::Ok.new
    proc.instance_variable_set(:@job, job_instance)

    assert_false proc.retired?
    proc.retire

    refute_predicate job_instance, :interrupted?
    assert_true proc.retired?
    assert_true proc.instance_variable_get(:@done)
    refute_predicate processor.tap(&:terminate), :retired?, "only #retire retires"
  end

  def test_a_retired_worker_finishes_its_job_then_stops
    unit = unit_for(job(ProcessorTestJobs::Gated))
    fetcher = scripted { |n| (n == 1) ? unit : (sleep(0.01) && nil) }
    proc = processor(fetcher)
    proc.start(0)
    eventually { @manager.events.any? { |e| e[0] == :started } }
    proc.retire
    ProcessorTestJobs::Gated::GATE << true
    proc.thread.join(2)

    refute_predicate proc, :alive?
    assert_equal [[:gated, false]], ProcessorTestJobs::LOG
    assert_equal [true], finished.map(&:last)
    assert_equal [:stopped, proc], @manager.events.last
    assert_equal 1, fetcher.slots.size, "it fetched nothing more"
    assert_empty inflight
  ensure
    ProcessorTestJobs::Gated::GATE.clear
  end

  def test_a_new_worker_has_finished_no_jobs
    p = processor

    assert_same 0, p.finished
    assert_nil p.finished_at
  end

  def test_alive_and_kill_without_thread
    proc = processor

    assert_nil proc.alive?
    begin
      proc.kill
    rescue Robin::Shutdown
      flunk "kill must not interrupt the calling thread"
    end

    assert proc.instance_variable_get(:@done)
  end

  def test_start_runs_in_a_named_thread_until_terminated
    fetcher = scripted do |_n|
      sleep 0.01
      nil
    end
    proc = processor(fetcher)

    assert_same proc, proc.start(0)
    eventually { fetcher.slots.size >= 2 }

    assert_equal "robin.default.2", proc.thread.name
    assert_same config.default_capsule, proc.thread[:robin_capsule]
    refute proc.thread.report_on_exception
    assert Thread.report_on_exception, "must not change the global default"
    assert_predicate proc, :alive?
    proc.terminate
    proc.thread.join(2)

    refute_predicate proc, :alive?
    assert_equal [:stopped, proc], @manager.events.last
    assert_equal [2], fetcher.slots.uniq
  end

  def test_a_starting_worker_announces_itself_on_its_own_thread
    seen = Queue.new
    config.event_handlers << ->(name, payload) { seen << [name, payload, Thread.current.name, Robin::Capsule.current] }
    proc = processor(scripted { |_n| sleep 0.01 })
    proc.start(0)

    assert_equal ["worker.started", {capsule: "default"}, "robin.default.2", config.default_capsule], seen.pop
    proc.terminate
    proc.thread.join(2)
  end

  def test_a_job_knows_its_capsule
    unit = unit_for(job(ProcessorTestJobs::Capsules))
    proc = processor(scripted { |n| (n == 1) ? unit : sleep(0.01) && nil })
    proc.start(0)
    eventually { ProcessorTestJobs::LOG.any? }
    proc.terminate
    proc.thread.join(2)

    assert_equal [config.default_capsule], ProcessorTestJobs::LOG
    assert_nil Robin::Capsule.current
    assert_nil ProcessorTestJobs::Capsules.new.capsule
  end

  def test_kill_while_fetching_waits_for_the_fetch_then_stops
    entered = Queue.new
    release = Queue.new
    fetcher = scripted do |_n|
      entered << true
      release.pop # stands in for a blocking BLMOVE
      nil
    end
    proc = processor(fetcher)
    proc.start(0)
    entered.pop
    proc.kill
    sleep 0.05

    assert_predicate proc, :alive?, "the fetch must not be interrupted"
    release << true
    proc.thread.join(2)

    refute_predicate proc, :alive?
    assert_equal [:stopped, proc], @manager.events.last
    assert_equal 1, fetcher.slots.size
  end

  def test_kill_interrupts_the_backoff_after_a_failed_fetch
    proc = processor(scripted { raise Robin::Redis::ConnectionError, "down" })
    proc.instance_variable_set(:@backoff, 30) # the next backoff sleep is a minute
    proc.start(0)
    sleep 0.05
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    proc.kill
    proc.thread.join(2)

    refute_predicate proc, :alive?
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  end

  def test_kill_interrupts_a_sleep
    proc = processor(scripted { nil })
    proc.start(30) # e.g. a respawn delay
    sleep 0.05
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    proc.kill
    proc.thread.join(2)

    refute_predicate proc, :alive?
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    assert_equal [:stopped, proc], @manager.events.last
  end

  def test_a_job_that_wraps_the_shutdown_is_interrupted_not_failed
    item = job(ProcessorTestJobs::WrapsShutdown)
    raws = [unit_for(item)]
    proc = processor(scripted { |_n| raws.shift || (sleep(0.01) && nil) })
    proc.start(0)
    eventually { @manager.events.any? { |e| e[0] == :started } }
    proc.kill
    proc.thread.join(2)

    refute_predicate proc, :alive?
    assert_equal [:stopped, proc], @manager.events.last
    assert_equal [JSON.generate(item)], inflight
    assert_equal 0, redis("ZCARD", config.key("retry"))
  end

  def test_kill_raises_shutdown_into_the_running_job
    item = job(ProcessorTestJobs::Slow, 10)
    raws = [unit_for(item)]
    fetcher = scripted do |_n|
      raws.shift || (sleep(0.01) && nil)
    end
    proc = processor(fetcher)
    proc.start(0)
    eventually { @manager.events.any? { |e| e[0] == :started } }
    begin
      proc.kill
      proc.thread.join(2)
    rescue Robin::Shutdown
      flunk "Shutdown must stay inside the worker"
    end

    refute_predicate proc, :alive?
    assert_equal [:stopped, proc], @manager.events.last
    assert_equal [JSON.generate(item)], inflight
    proc.kill # already dead: no error
  end

  def test_run_processes_units_and_requeues_when_quieted
    first = unit_for(job(ProcessorTestJobs::Ok, 1))
    second = unit_for(job(ProcessorTestJobs::Ok, 2))
    proc = nil
    fetcher = scripted do |n|
      case n
      when 1 then nil
      when 2 then first
      when 3
        proc.terminate
        second
      end
    end
    proc = processor(fetcher)
    proc.send(:run, 0)

    assert_equal [[:ok, [1], "jid-Ok", "q1"]], ProcessorTestJobs::LOG
    assert_equal [JSON.generate(job(ProcessorTestJobs::Ok, 2))], redis("LRANGE", config.key("queue", "q1"), 0, -1)
    assert_empty inflight
    assert_equal [:stopped, proc], @manager.events.last
  end

  def test_run_backs_off_and_reports_connection_errors
    sleeps = []
    proc = nil
    fetcher = scripted do |n|
      if n == 40
        proc.terminate
        nil
      elsif n == 9
        nil # one success resets the backoff
      elsif n.odd? && n < 9
        raise Robin::Redis::Pool::TimeoutError, "pool #{n}"
      else
        raise Robin::Redis::ConnectionError, "down #{n}"
      end
    end
    proc = processor(fetcher)
    proc.define_singleton_method(:sleep) { |s| sleeps << s }
    proc.send(:run, 0)

    assert_equal [0.2, 0.4, 0.8, 1.6, 3.2, 5, 5, 5], sleeps.first(8)
    assert_equal [0.2, 0.4, 0.8], sleeps[8, 3]
    assert_equal 38, sleeps.size
    assert_equal ["pool 1", "down 10", "down 39"], @errors.map { |e| e[0].message }
    assert_equal [{context: "fetch"}], @errors.map(&:last).uniq
  end

  def test_run_does_not_sleep_after_error_once_stopping
    proc = nil
    fetcher = scripted do |_n|
      proc.terminate
      raise Robin::Redis::ConnectionError, "down"
    end
    proc = processor(fetcher)

    proc.define_singleton_method(:sleep) { |_s| flunk "slept while stopping" }
    proc.send(:run, 0)

    assert_equal [:stopped, proc], @manager.events.last
  end

  def test_run_reports_shutdown_as_stopped
    proc = processor(scripted { raise Robin::Shutdown })
    begin
      proc.send(:run, 0)
    rescue Robin::Shutdown
      flunk "Shutdown escaped the worker loop"
    end

    assert_equal [[:stopped, proc]], @manager.events
  end

  def test_run_backs_off_on_any_fetch_error_and_logs_recovery
    sleeps = []
    clock = 100.0
    proc = nil
    errors = [Robin::Redis::CommandError.new("OOM command not allowed"), Robin::Redis::CommandError.new("LOADING"),
      Robin::Redis::CommandError.new("WRONGTYPE"), RuntimeError.new("bug")]
    fetcher = scripted do |n|
      clock += 1.5
      case n
      when 1..4 then raise errors.fetch(n - 1)
      when 5, 6 then nil
      when 7 then raise errors.first
      else
        proc.terminate
        nil
      end
    end
    proc = processor(fetcher)
    proc.define_singleton_method(:sleep) { |s| sleeps << s }
    proc.define_singleton_method(:monotonic) { clock }
    logs = capture_logs
    proc.send(:run, 0)

    assert_equal [0.2, 0.4, 0.8, 1.6, 0.2], sleeps
    assert_equal [errors.first, errors.first], @errors.map(&:first)
    # The outage started with the first failed fetch and ended with the
    # first successful one, four fetches later.
    assert_equal ["INFO: Redis is back after 6.0s\n", "INFO: Redis is back after 1.5s\n"], logs.string.lines
    assert_equal [:stopped, proc], @manager.events.last
  end

  # -- acknowledgement with the next fetch -------------------------------------

  def test_finished_jobs_are_acknowledged_by_the_next_fetch
    proc = processor
    unit = unit_for(job(ProcessorTestJobs::Ok))
    pool = recording_pool { proc.send(:process, unit) }

    assert_empty pool.calls, "finishing a job costs no round trip"
    assert_equal unit.key, proc.unacked
    assert_equal [unit.raw], inflight
    redis("LPUSH", config.key("queue", "default"), "next")
    pool = recording_pool { assert_equal "next", proc.send(:fetch).raw }

    assert_equal [:pipelined], pool.calls.map(&:first) - [:pipe], "one round trip"
    assert_equal [:pipe, "DEL", unit.key], pool.calls.fetch(1)
    assert_nil proc.unacked
    assert_equal %w[next], inflight
  end

  # One time round, on the calling thread: fetch, run, and acknowledge
  # with the next fetch.
  def test_work_once
    ProcessorTestJobs::LOG.clear
    proc = processor
    redis("LPUSH", config.key("queue", "default"), JSON.generate(job(ProcessorTestJobs::Ok, 1, queue: "default")))

    assert_same true, proc.work_once
    assert_equal [[:ok, [1], "jid-Ok", "default"]], ProcessorTestJobs::LOG
    refute_nil proc.unacked, "its acknowledgement left for the next fetch"
    assert_same false, proc.work_once, "nothing more to do"
    assert_nil proc.unacked
    assert_empty inflight
  end

  def test_discarded_jobs_are_acknowledged_by_the_next_fetch_too
    proc = processor
    unit = unit_for(job(ProcessorTestJobs::Discards))
    proc.send(:process, unit)

    assert_equal unit.key, proc.unacked
  end

  def test_a_failed_fetch_leaves_the_acknowledgement_to_the_fetcher
    unit = unit_for(job(ProcessorTestJobs::Ok))
    proc = nil
    fetcher = scripted do |n|
      case n
      when 1 then unit
      when 2 then raise Robin::Redis::ConnectionError, "down"
      else
        proc.terminate
        nil
      end
    end
    proc = processor(fetcher)
    proc.define_singleton_method(:sleep) { |_s| nil }
    proc.send(:run, 0)

    assert_equal [nil, unit.key, nil], fetcher.acks
    assert_nil proc.unacked
    assert_empty inflight
  end

  def test_a_stopping_worker_acknowledges_its_last_job_before_it_stops
    unit = unit_for(job(ProcessorTestJobs::Ok))
    proc = processor(scripted { unit })
    now = -> { inflight }
    seen = :unset
    @manager.define_singleton_method(:work_started) { |p, _unit| p.terminate }
    @manager.define_singleton_method(:processor_stopped) { |_p| seen = now.call }
    proc.send(:run, 0)

    assert_empty seen
    assert_nil proc.unacked
  end

  def test_shutdown_and_death_acknowledge_the_last_job_first
    [[Robin::Shutdown.new, :stopped], [Class.new(Exception).new("fatal"), :died]].each do |error, event| # rubocop:disable Lint/InheritException
      unit = unit_for(job(ProcessorTestJobs::Ok))
      proc = processor(scripted { |n| (n == 1) ? unit : raise(error) })
      proc.send(:run, 0)

      assert_empty inflight
      assert_nil proc.unacked
      assert_equal event, @manager.events.last[0]
    end
  end

  def test_a_failed_final_acknowledgement_is_reported_and_kept
    proc = processor
    proc.instance_variable_set(:@unacked, "done")
    boom = Robin::Redis::ConnectionError.new("down")
    config.define_singleton_method(:redis) { |&_| raise boom }
    begin
      proc.send(:acknowledge_unacked)
    ensure
      config.singleton_class.remove_method(:redis)
    end

    assert_equal [[boom, {context: "acknowledging a finished job"}]], @errors
    assert_equal "done", proc.unacked
  end

  def test_only_a_stopping_worker_hands_back_the_fetched_jobs
    stopping = nil
    fetcher = scripted do
      stopping.terminate
      nil
    end
    stopping = processor(fetcher)
    stopping.send(:run, 0)

    assert_equal 1, fetcher.releases
    dying = scripted { raise Class.new(Exception) } # rubocop:disable Lint/InheritException
    processor(dying).send(:run, 0)

    assert_equal 0, dying.releases
  end

  def test_a_failed_hand_back_is_reported
    proc = processor
    @fetcher.instance_variable_get(:@acks) << "finished"
    boom = Robin::Redis::ConnectionError.new("down")
    config.define_singleton_method(:redis) { |&_| raise boom }
    begin
      proc.send(:release_fetched)
    ensure
      config.singleton_class.remove_method(:redis)
    end

    assert_equal [[boom, {context: "handing back fetched jobs"}]], @errors
  end

  def test_nothing_to_acknowledge_costs_nothing
    pool = recording_pool { processor.send(:acknowledge_unacked) }

    assert_empty pool.calls
    assert_empty @errors
  end

  def test_run_reports_unexpected_errors_as_death
    boom = Class.new(Exception).new("fatal") # rubocop:disable Lint/InheritException
    proc = processor(scripted { raise boom })
    proc.send(:run, 0)

    assert_equal [[:died, proc, boom]], @manager.events
    oops = RuntimeError.new("processing bug")
    proc = processor(scripted { Object.new })
    proc.define_singleton_method(:process) { |_unit| raise oops }
    proc.send(:run, 0)

    assert_equal [:died, proc, oops], @manager.events.last
  end

  def test_start_can_wait_before_running
    sleeps = []
    proc = nil
    fetcher = scripted do |_n|
      proc.terminate
      nil
    end
    proc = processor(fetcher)
    proc.define_singleton_method(:sleep) { |s| sleeps << s }
    proc.send(:run, 2.5)
    proc.send(:run, 0)

    assert_equal [2.5], sleeps
    assert_equal 1, fetcher.slots.size
  end

  def test_start_passes_its_delay_to_the_worker_thread
    proc = processor(scripted { nil })
    delays = []
    proc.define_singleton_method(:run) { |delay| delays << delay }
    proc.start(1.5).thread.join(2)

    assert_equal [1.5], delays
  end

  def test_shutdown_is_an_interrupt
    assert_operator Robin::Shutdown, :<, Interrupt
  end
end
