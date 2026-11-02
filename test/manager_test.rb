# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class ManagerTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Manager*"

  class FakeLauncher
    attr_reader :identity, :events

    def initialize
      @identity = "host:1:abc"
      @events = []
    end

    def work_finished_cleanup(processor) = @events << [:cleanup, processor]

    def work_started(*args) = @events << [:started, *args]

    def work_finished(*args) = @events << [:finished, *args]
  end

  class FakeProcessor
    attr_reader :thread, :log
    attr_accessor :alive

    def initialize(alive: true, thread: nil)
      @alive = alive
      @thread = thread
      @log = []
    end

    def alive? = @alive

    def retired? = !!@retired

    def retire
      @retired = true
      @log << :retire
    end

    def start(delay)
      @log << [:start, delay]
      self
    end

    def terminate = @log << :terminate

    def kill
      @log << :kill
      @alive = false
    end
  end

  def setup
    super
    config.concurrency = 3
    @launcher = FakeLauncher.new
    @manager = Robin::Manager.new(config.default_capsule, @launcher)
  end

  def fake!(*procs) = @manager.instance_variable_set(:@processors, procs)

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def test_builds_one_processor_per_slot
    procs = @manager.processors

    assert_equal 3, procs.size
    assert(procs.all?(Robin::Processor))
    assert_equal [0, 1, 2], procs.map { |p| p.instance_variable_get(:@slot) }
    assert_same config.default_capsule, @manager.capsule
    assert_same @launcher, @manager.launcher
    assert_equal config.key("inflight", "host:1:abc"), @manager.fetcher.inflight_key
    assert(procs.all? { |p| p.instance_variable_get(:@fetcher).equal?(@manager.fetcher) })
    assert(procs.all? { |p| p.capsule.equal?(config.default_capsule) })
    assert(procs.all? { |p| p.instance_variable_get(:@manager).equal?(@manager) })
    refute @manager.instance_variable_get(:@stopping)
  end

  def test_processors_returns_a_copy
    @manager.processors.clear

    assert_equal 3, @manager.processors.size
  end

  def test_start_starts_every_processor
    started = []
    @manager.processors.each { |p| p.define_singleton_method(:start) { |delay| started << [self, delay] } }
    @manager.start

    assert_equal(@manager.processors.map { |p| [p, 0] }, started)
  end

  def test_quiet_terminates_everyone
    a = FakeProcessor.new
    b = FakeProcessor.new
    fake!(a, b)
    @manager.quiet

    assert_equal [[:terminate], [:terminate]], [a.log, b.log]
    assert @manager.instance_variable_get(:@stopping)
  end

  def test_stop_returns_once_processors_finish
    a = FakeProcessor.new(alive: false)
    fake!(a)
    logs = capture_logs
    started = monotonic
    @manager.stop(monotonic + 5, monotonic + 8)

    assert_operator monotonic - started, :<, 1
    assert_equal [:terminate], a.log
    assert_empty logs.string
  end

  def test_stop_polls_until_processors_finish
    a = FakeProcessor.new
    fake!(a)
    naps = []
    @manager.define_singleton_method(:sleep) do |s|
      naps << s
      a.alive = false if naps.size == 3
    end
    @manager.stop(monotonic + 5, monotonic + 8)

    assert_equal [0.05, 0.05, 0.05], naps
    assert_equal [:terminate], a.log
  end

  def with_mutex_held
    mutex = @manager.instance_variable_get(:@mutex)
    mutex.lock
    yield
  ensure
    mutex.unlock
  end

  def assert_blocks_on_mutex(&)
    thread = nil
    with_mutex_held do
      thread = Thread.new(&)
      sleep 0.01 until thread.status == "sleep" || !thread.alive?

      assert_equal "sleep", thread.status
    end
    thread.join(2)
  end

  def test_processor_list_is_guarded_by_the_mutex
    capture_errors
    a = FakeProcessor.new
    b = FakeProcessor.new
    fake!(a, b)
    assert_blocks_on_mutex { @manager.processors }
    assert_blocks_on_mutex { @manager.processor_stopped(a) }
    stub_method(Robin::Processor, :new, ->(*) { FakeProcessor.new.tap { |p| p.define_singleton_method(:start) { |_delay| self } } }) do
      assert_blocks_on_mutex { @manager.processor_died(b, RuntimeError.new("x")) }
    end
  end

  def test_stop_kills_stragglers_after_deadline
    config.timeout = 9
    joined = []
    thread = Object.new
    thread.define_singleton_method(:join) { |t| joined << t }
    a = FakeProcessor.new(thread: thread)
    b = FakeProcessor.new(alive: false)
    c = FakeProcessor.new
    fake!(a, b, c)
    logs = capture_logs
    started = monotonic
    @manager.stop(monotonic + 0.15, monotonic + 3.15)

    assert_operator monotonic - started, :>=, 0.15
    assert_operator monotonic - started, :<, 1
    assert_equal [:terminate, :kill], a.log
    assert_equal [:terminate], b.log
    assert_equal [:terminate, :kill], c.log
    assert_equal 1, joined.size
    assert_in_delta 3.0, joined.first, 0.2
    assert_equal "WARN: interrupting 2 job(s) still running after 9s\n", logs.string
  end

  def test_interrupted_jobs_are_an_event
    events = capture_events
    fake!(FakeProcessor.new(alive: false))
    @manager.stop(monotonic + 1, monotonic + 1)

    assert_empty events
    fake!(FakeProcessor.new, FakeProcessor.new(alive: false), FakeProcessor.new)
    @manager.stop(monotonic - 1, monotonic - 1)

    assert_equal [["jobs.interrupted", {count: 2}]], events
  end

  def test_stragglers_share_what_is_left_of_the_hard_deadline
    joined = []
    threads = Array.new(2) do
      Object.new.tap { |t| t.define_singleton_method(:join) { |s| joined << s } }
    end
    fake!(*threads.map { |t| FakeProcessor.new(thread: t) })
    capture_logs
    @manager.stop(monotonic - 1, monotonic - 0.5)

    assert_equal [0, 0], joined
  end

  def test_processor_stopped
    a = FakeProcessor.new
    b = FakeProcessor.new
    fake!(a, b)
    @manager.processor_stopped(a)

    assert_equal [b], @manager.processors
    assert_equal [[:cleanup, a]], @launcher.events
  end

  def test_processor_died_is_replaced_in_its_slot
    errors = capture_errors
    a = FakeProcessor.new
    b = FakeProcessor.new
    fake!(a, b)
    started = []
    replacement = nil
    stub_method(Robin::Processor, :new, lambda { |*args|
      replacement = FakeProcessor.new
      replacement.define_singleton_method(:start) { |delay| started << [*args, delay] }
      replacement
    }) do
      @manager.processor_died(a, RuntimeError.new("dead"))
    end

    assert_equal [[@manager, config.default_capsule, @manager.fetcher, 0, 0]], started
    assert_equal [b, replacement], @manager.processors
    assert_equal [[:cleanup, a]], @launcher.events
    ex, ctx = errors.last

    assert_equal "dead", ex.message
    assert_equal({context: "worker thread died"}, ctx)
  end

  def test_unknown_dead_processor_gets_next_slot
    fake!(FakeProcessor.new, FakeProcessor.new)
    slots = []
    stub_method(Robin::Processor, :new, lambda { |*args|
      slots << args.last
      FakeProcessor.new.tap { |p| p.define_singleton_method(:start) { |_delay| self } }
    }) do
      @manager.processor_died(FakeProcessor.new, RuntimeError.new("x"))
    end

    assert_equal [2], slots
  end

  def test_repeated_deaths_delay_respawns
    capture_errors
    logs = capture_logs
    clock = 1000.0
    @manager.define_singleton_method(:monotonic) { clock }
    delays = []
    stub_method(Robin::Processor, :new, lambda { |*|
      FakeProcessor.new.tap { |p| p.define_singleton_method(:start) { |delay| delays << delay } }
    }) do
      [0, 1, 59, 1, 1, 1, 1, 1, 1, 60, 1].each do |gap|
        clock += gap
        @manager.processor_died(@manager.processors.first, RuntimeError.new("x"))
      end
    end

    # Isolated deaths restart at once; deaths less than a minute apart
    # wait 1s, 2s, 4s... up to 30s.
    assert_equal [0, 1, 2, 4, 8, 16, 30, 30, 30, 0, 1], delays
    assert_equal 3, @manager.processors.size
    assert_includes logs.string, "WARN: worker thread died 2 times in a row; restarting it in 1s\n"
    assert_includes logs.string, "WARN: worker thread died 9 times in a row; restarting it in 30s\n"
    assert_equal 9, logs.string.lines.size # none for immediate restarts
  end

  def test_worker_deaths_are_events_with_the_respawn_delay
    capture_errors
    events = capture_events
    clock = 1000.0
    @manager.define_singleton_method(:monotonic) { clock }
    errors = Array.new(3) { |i| RuntimeError.new("x#{i}") }
    stub_method(Robin::Processor, :new, lambda { |*|
      FakeProcessor.new.tap { |p| p.define_singleton_method(:start) { |_delay| self } }
    }) do
      errors.each do |error|
        clock += 1
        @manager.processor_died(@manager.processors.first, error)
      end
    end

    assert_equal [["worker.died", {error: errors[0], delay: 0}], ["worker.died", {error: errors[1], delay: 1}],
      ["worker.died", {error: errors[2], delay: 2}]], events
  end

  def test_no_replacement_while_stopping
    capture_errors
    a = FakeProcessor.new
    fake!(a)
    @manager.quiet
    events = capture_events
    error = RuntimeError.new("x")
    @manager.processor_died(a, error)

    assert_empty @manager.processors
    assert_equal [["worker.died", {error: error, delay: nil}]], events
  end

  # -- resize ------------------------------------------------------------------

  # Runs the block with Processor.new making FakeProcessors; returns them
  # with the arguments they were made with.
  def making_fakes
    made = []
    stub_method(Robin::Processor, :new, ->(*args) { FakeProcessor.new.tap { |p| made << [p, args] } }) { yield }
    made
  end

  def slot_numbers(made) = made.map { |_p, args| args.last }

  def test_concurrency_starts_as_the_capsules
    assert_equal 3, @manager.concurrency
  end

  def test_resize_before_start_adds_workers_that_start_with_the_others
    made = making_fakes { @manager.resize(5) }

    assert_equal 5, @manager.concurrency
    assert_equal 5, config.default_capsule.concurrency
    assert_equal [3, 4], slot_numbers(made)
    assert_equal([[@manager, config.default_capsule, @manager.fetcher]] * 2, made.map { |_p, args| args.first(3) })
    assert_equal [[], []], made.map { |p, _args| p.log }, "not started yet"
    assert_equal 5, @manager.processors.size
    assert_equal(made.map(&:first), @manager.processors.last(2))
    fake!(*@manager.processors.last(2))
    @manager.start

    assert_equal [[[:start, 0]], [[:start, 0]]], made.map { |p, _args| p.log }
  end

  def test_resize_after_start_starts_the_new_workers_at_once
    a = FakeProcessor.new
    fake!(a)
    @manager.start
    made = making_fakes { @manager.resize(4) }

    assert_equal [3, 4, 5], slot_numbers(made)
    assert_equal [[[:start, 0]]] * 3, made.map { |p, _args| p.log }
    assert_equal [a, *made.map(&:first)], @manager.processors
    assert_equal [[:start, 0]], a.log
  end

  def test_shrinking_retires_the_last_workers
    a, b, c = Array.new(3) { FakeProcessor.new }
    fake!(a, b, c)
    made = making_fakes { @manager.resize(1) }

    assert_empty made
    assert_equal 1, @manager.concurrency
    assert_equal [[], [:retire], [:retire]], [a.log, b.log, c.log]
    assert_equal [a, b, c], @manager.processors, "retired workers leave once they stop"
  end

  def test_grow_then_shrink_then_grow
    fake!(*Array.new(3) { FakeProcessor.new })
    @manager.start
    grown = making_fakes { @manager.resize(5) }
    first, second, third = @manager.processors
    @manager.resize(2)

    assert_equal [[[:start, 0]], [[:start, 0]], [[:start, 0], :retire]], [first.log, second.log, third.log]
    assert_equal [[[:start, 0], :retire]] * 2, grown.map { |p, _args| p.log }
    regrown = making_fakes { @manager.resize(4) }

    assert_equal [5, 6], slot_numbers(regrown), "new workers get fresh slots"
    assert_equal 4, @manager.concurrency
    assert_equal 7, @manager.processors.size
    assert_equal 4, @manager.processors.count { |p| !p.retired? }
  end

  def test_resizing_to_the_same_size_changes_nothing
    procs = Array.new(3) { FakeProcessor.new }
    fake!(*procs)
    made = making_fakes { @manager.resize(3) }

    assert_empty made
    assert_equal [[]] * 3, procs.map(&:log)
    assert_equal procs, @manager.processors
  end

  def test_no_resizing_while_stopping
    a = FakeProcessor.new
    fake!(a)
    @manager.quiet
    made = making_fakes do
      @manager.resize(5)
      @manager.resize(1)
    end

    assert_empty made
    assert_equal 3, @manager.concurrency
    assert_equal [a], @manager.processors
    assert_equal [:terminate], a.log
  end

  def test_resize_concurrency_and_start_hold_the_mutex
    fake!(FakeProcessor.new)
    assert_blocks_on_mutex { @manager.concurrency }
    assert_blocks_on_mutex { @manager.start }
    making_fakes { assert_blocks_on_mutex { @manager.resize(4) } }
  end

  def test_a_retired_worker_that_dies_is_not_replaced
    capture_errors
    a = FakeProcessor.new
    b = FakeProcessor.new
    fake!(a, b)
    @manager.resize(1)
    events = capture_events
    error = RuntimeError.new("x")
    made = making_fakes { @manager.processor_died(b, error) }

    assert_empty made
    assert_equal [a], @manager.processors
    assert_equal [["worker.died", {error: error, delay: nil}]], events
    assert_equal [[:cleanup, b]], @launcher.events
  end

  def test_work_callbacks_delegate_to_launcher
    @manager.work_started(:proc, :unit)
    @manager.work_finished(:proc, {"a" => 1}, 1.5, true)

    assert_equal [[:started, :proc, :unit], [:finished, :proc, {"a" => 1}, 1.5, true]], @launcher.events
  end
end
