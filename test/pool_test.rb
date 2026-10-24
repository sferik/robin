# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class PoolTest < Minitest::Test
  cover "Robin::Redis::Pool*"

  Pool = Robin::Redis::Pool

  class FakeConn
    attr_reader :id, :closed, :abandoned

    def initialize(id)
      @id = id
    end

    def call(*args) = [:call, @id, args]

    def pipelined = [:pipelined, @id, yield(:pipe)]

    def multi = [:multi, @id, yield(:tx)]

    def evalsha(script, keys, argv) = [:evalsha, @id, script, keys, argv]

    def blocking_call(timeout, *args) = [:blocking, @id, timeout, args]

    def close
      @closed = true
    end

    def abandon
      @abandoned = true
    end
  end

  # What a holding thread put on +queue+. Waits a while, never forever: a
  # thread that died without putting anything would otherwise leave the
  # test (and the process) deadlocked rather than failing.
  def taken(queue) = queue.pop(timeout: 5) || flunk("the holding thread never got a connection")

  def pool(size: 2, timeout: 1, **)
    @made = []
    Pool.new(size: size, timeout: timeout, **) { FakeConn.new(@made.size).tap { |c| @made << c } }
  end

  # Runs the block with a controllable monotonic clock.
  def with_clock
    clock = [100.0]
    original = Process.method(:clock_gettime)
    Process.define_singleton_method(:clock_gettime) { |*args| (args == [Process::CLOCK_MONOTONIC]) ? clock.first : original.call(*args) }
    yield clock
  ensure
    Process.define_singleton_method(:clock_gettime, original)
  end

  def test_requires_a_factory
    error = assert_raises(ArgumentError) { Pool.new }
    assert_equal "a connection factory block is required", error.message
  end

  def test_defaults
    p = Pool.new { nil }

    assert_equal 5, p.size
    assert_in_delta 3.0, p.timeout
    assert_nil p.idle_timeout
  end

  def test_idle_connections_are_closed_at_the_next_checkout
    with_clock do |clock|
      p = pool(size: 3, idle_timeout: 60)
      p.with { p.with { nil } }
      # Two connections at once, so the pool holds two.
      t = Thread.new { p.with { sleep 0.05 } }
      sleep 0.01
      p.with { nil }
      t.join
      a, b = @made

      assert_equal 60, p.idle_timeout
      clock[0] += 60 # exactly the timeout: kept

      p.with { |c| assert_includes [a, b], c }

      refute(@made.any?(&:closed))
      clock[0] += 61

      p.with { |c| assert_same @made.last, c } # both were idle too long

      assert a.closed
      assert b.closed
      assert_equal 3, @made.size
      assert_equal [@made.last], p.instance_variable_get(:@slots).drain
    end
  end

  def test_only_the_idle_connections_are_closed
    with_clock do |clock|
      p = pool(idle_timeout: 10)
      t = Thread.new { p.with { sleep 0.05 } }
      sleep 0.01
      p.with { nil } # returned at 100
      t.join # returned at 100 too
      clock[0] = 105
      first = nil
      p.with { |c| first = c } # used and returned at 105 (top of the stack)
      clock[0] = 112

      p.with { |c| assert_same first, c }

      assert_equal [first], @made.reject(&:closed)
    end
  end

  def test_no_idle_bookkeeping_without_a_timeout
    with_clock do
      p = pool
      p.with { nil }

      slots = p.instance_variable_get(:@slots)

      assert_empty slots.reap(0), "returned as idle since 0"
      assert_equal @made, slots.reap(0.5)
    end
  end

  def test_with_reuses_connections_and_nests
    p = pool

    assert_empty @made
    first = p.with { |c| p.with { |inner| [c, inner] } }

    assert_same first[0], first[1]
    assert_same first[0], p.with { |c| c }
    assert_equal 1, @made.size
    assert_nil Thread.current[p.instance_variable_get(:@key)]
  end

  def test_with_returns_the_block_value_and_checks_in_on_error
    p = pool(size: 1)

    assert_equal :value, p.with { :value }
    assert_raises(RuntimeError) { p.with { raise "boom" } }
    assert_equal 0, p.with(&:id)
  end

  def test_threads_get_separate_connections
    p = pool
    held = Thread::Queue.new
    release = Thread::Queue.new
    thread = Thread.new do
      p.with do |c|
        held << c
        release.pop
      end
    end
    theirs = taken(held)
    mine = p.with { |c| c }
    release << true
    thread.join

    refute_same theirs, mine
    assert_equal 2, @made.size
  end

  def test_waits_for_a_free_connection
    p = pool(size: 1, timeout: 3)
    held = Thread::Queue.new
    thread = Thread.new do
      p.with do |c|
        held << c
        sleep 0.1
      end
    end
    taken(held)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_equal 0, Timeout.timeout(5) { p.with(&:id) }
    # Woken by the checkin, not by the timeout.
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 1.5
    thread.join
  end

  def test_reuses_the_most_recently_returned_connection
    p = pool
    held = Thread::Queue.new
    release = Thread::Queue.new
    t = Thread.new do
      p.with do |a|
        held << a
        release.pop
      end
    end
    first = taken(held)
    second = p.with do |b|
      release << true
      t.join # first goes back before second
      b
    end

    refute_same first, second
    assert_same second, p.with { |c| c }
  end

  def test_pools_do_not_share_checked_out_connections
    a = pool
    b = Pool.new(size: 1) { :from_b }

    assert_equal :from_b, a.with { b.with { |c| c } }
  end

  def test_records_its_process
    assert_equal Process.pid, pool.instance_variable_get(:@pid)
  end

  def assert_size_one_is_enforced(p)
    held = Thread::Queue.new
    release = Thread::Queue.new
    t = Thread.new do
      p.with do
        held << true
        release.pop
      end
    end
    taken(held)

    assert_raises(Pool::TimeoutError) { p.with { nil } }
  ensure
    release << true
    t.join
  end

  def test_size_stays_enforced_after_errors_resets_and_shutdowns
    attempts = 0
    flaky = Pool.new(size: 1, timeout: 0.05) do
      attempts += 1
      raise "nope" if attempts == 1

      FakeConn.new(attempts)
    end
    assert_raises(RuntimeError) { flaky.with { nil } }
    assert_size_one_is_enforced(flaky)

    forked = pool(size: 1, timeout: 0.05)
    forked.with { nil }
    forked.instance_variable_set(:@pid, -1)

    assert_size_one_is_enforced(forked)

    restarted = pool(size: 1, timeout: 0.05)
    restarted.with { nil }
    restarted.shutdown

    assert_size_one_is_enforced(restarted)
  end

  def test_times_out_when_exhausted
    p = pool(size: 1, timeout: 0.1)
    held = Thread::Queue.new
    release = Thread::Queue.new
    thread = Thread.new do
      p.with do
        held << true
        release.pop
      end
    end
    taken(held)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Pool::TimeoutError) { Timeout.timeout(3) { p.with { nil } } }

    assert_equal "waited 0.1s for a Redis connection (pool size 1)", error.message
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :>=, 0.09
    assert_kind_of Robin::Redis::TimeoutError, error
  ensure
    release << true
    thread&.join
  end

  # Checks out +count+ connections at once, on threads that hold them
  # until #release_held.
  def hold(p, count)
    @release = Thread::Queue.new
    held = Thread::Queue.new
    @holders = Array.new(count) do
      Thread.new do
        Thread.current.report_on_exception = false
        p.with do
          held << true
          @release.pop
        end
      end
    end

    count.times { assert held.pop(timeout: 3), "a connection should have been free" }
  end

  def release_held
    @holders&.each { @release << true }
    @holders&.each do |thread|
      thread.join
    rescue
      nil # one that couldn't check a connection out failed #hold already
    end
  end

  def assert_exhausted(p)
    error = assert_raises(Pool::TimeoutError) { Timeout.timeout(3) { p.with { nil } } }

    assert_equal "waited 0.05s for a Redis connection (pool size #{p.size})", error.message
  end

  def test_grow_adds_connections
    p = pool(size: 1, timeout: 0.05)

    assert_equal 3, p.grow(3)
    assert_equal 3, p.size
    hold(p, 3)

    assert_exhausted(p)
  ensure
    release_held
  end

  def test_grow_never_shrinks
    p = pool(size: 3, timeout: 0.05)

    p.instance_variable_get(:@slots).define_singleton_method(:add) { |_count| flunk "no slots to add" }

    assert_equal 3, p.grow(2)
    assert_equal 3, p.grow(3)
    assert_equal 3, p.size
    hold(p, 3)

    assert_exhausted(p)
  ensure
    release_held
  end

  def test_grow_wakes_a_waiting_checkout
    p = pool(size: 1, timeout: 3)
    hold(p, 1)
    waiter = Thread.new { p.with(&:id) }
    sleep 0.05
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    p.grow(2)

    assert_equal 1, Timeout.timeout(3) { waiter.value }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 1.5
  ensure
    release_held
  end

  def test_a_grown_pool_keeps_its_size_after_fork
    p = pool(size: 1, timeout: 0.05)

    assert_equal 2, p.grow(2)
    p.instance_variable_set(:@pid, -1)
    hold(p, 2)

    assert_exhausted(p)
  ensure
    release_held
  end

  def test_factory_errors_free_the_slot
    attempts = 0
    p = Pool.new(size: 1, timeout: 0.1) do
      attempts += 1
      raise "nope" if attempts == 1

      FakeConn.new(attempts)
    end

    assert_raises(RuntimeError) { p.with { nil } }
    assert_equal 2, p.with(&:id)
  end

  def test_pass_throughs
    p = pool

    assert_equal [:call, 0, ["GET", "k"]], p.call("GET", "k")
    assert_equal [:pipelined, 0, [:pipe, 1]], p.pipelined { |x| [x, 1] }
    assert_equal [:multi, 0, [:tx, 2]], p.multi { |x| [x, 2] }
    assert_equal [:evalsha, 0, :s, ["k"], ["a"]], p.evalsha(:s, ["k"], ["a"])
    assert_equal [:evalsha, 0, :s, [], []], p.evalsha(:s)
    assert_equal [:blocking, 0, 5, ["BLPOP", "q"]], p.blocking_call(5, "BLPOP", "q")
  end

  def test_shutdown_closes_idle_connections
    p = pool(size: 1)
    first = p.with { |c| c }
    p.shutdown

    assert first.closed
    second = p.with { |c| c }

    refute_same first, second
    assert_equal 1, second.id
  end

  def test_shutdown_in_a_forked_child_abandons_what_it_inherited
    p = pool(size: 2)
    inherited = p.with { |c| c }
    p.instance_variable_set(:@pid, -1)
    p.shutdown

    assert inherited.abandoned
    refute inherited.closed
    assert_equal Process.pid, p.instance_variable_get(:@pid)
    own = p.with { |c| c }
    p.shutdown

    assert own.closed
    refute own.abandoned
  end

  def test_resets_after_fork
    p = pool(size: 1)
    first = p.with { |c| c }
    p.instance_variable_set(:@pid, -1)
    second = p.with { |c| c }

    assert first.abandoned, "a forked child must not say goodbye on its parent's sockets"
    refute first.closed
    refute_same first, second
    assert_same second, p.with { |c| c }
    assert_equal Process.pid, p.instance_variable_get(:@pid)
  end

  def test_slots_held_by_the_parents_threads_are_forgotten_after_fork
    p = pool(size: 1)
    held = Thread::Queue.new
    holder = Thread.new do
      p.with do
        held << true
        sleep
      end
    end
    taken(held)
    p.instance_variable_set(:@pid, -1)

    assert_equal 1, Timeout.timeout(3) { p.with(&:id) }
  ensure
    holder&.kill
  end

  def test_uses_the_extensions_slots_when_there_are_some
    native = Module.new
    native.const_set(:NativeSlots, Class.new)

    assert_same native::NativeSlots, Pool.slots_class(native)
    assert_same Pool::Slots, Pool.slots_class(Module.new)
    assert_same Pool.slots_class, Pool::SLOTS
  end
end
