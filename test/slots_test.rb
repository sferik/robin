# frozen_string_literal: true

require_relative "test_helper"

# The pool's bookkeeping, the same for Robin::Redis::Pool::Slots and the
# extension's Robin::Redis::NativeSlots (JRuby).
module SlotsBehavior
  def slots(size = 2) = @slots ||= slots_class.new(size)

  def test_creates_until_full_then_waits
    assert_equal :create, slots.take(1)
    assert_equal :create, slots.take(1)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_nil slots.take(0.05)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :>=, 0.04
    assert_nil slots.take(0)
    assert_nil slots.take(-1)
  end

  def test_hands_out_the_most_recently_returned_first
    2.times { slots.take(1) }
    slots.put(:a, 1.0)
    slots.put(:b, 2.0)

    assert_equal :b, slots.take(1)
    assert_equal :a, slots.take(1)
  end

  def test_returning_or_releasing_frees_a_slot
    2.times { slots.take(1) }
    slots.release

    assert_equal :create, slots.take(0)
    slots.put(:a, 1.0)

    assert_equal :a, slots.take(0)
  end

  def test_returning_or_releasing_frees_exactly_one_slot
    slots(1).take(1)
    slots.put(:a, 1.0)

    assert_equal :a, slots.take(0)
    assert_nil slots.take(0)
    slots.release

    assert_equal :create, slots.take(0)
    assert_nil slots.take(0)
  end

  def test_a_waiting_take_is_woken_by_a_release
    2.times { slots.take(1) }
    waiter = Thread.new { slots.take(5) }
    sleep 0.05
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    slots.release

    assert_equal :create, waiter.value
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 2
  end

  def test_a_waiting_take_is_woken_by_a_return
    2.times { slots.take(1) }
    waiter = Thread.new { slots.take(5) }
    sleep 0.05
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    slots.put(:a, 1.0)

    assert_equal :a, waiter.value
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 2
  end

  def test_thread_raise_interrupts_a_waiting_take
    2.times { slots.take(1) }
    waiter = Thread.new { slots.take(30) }
    waiter.report_on_exception = false
    sleep 0.05
    waiter.raise(RuntimeError, "stop waiting")

    assert_equal "stop waiting", assert_raises(RuntimeError) { waiter.value }.message
    slots.release

    assert_equal :create, slots.take(0), "the interrupted take took no slot"
  end

  def test_add_frees_that_many_more_slots
    slots(2).take(1)
    slots.add(2)

    assert_equal :create, slots.take(0)
    assert_equal :create, slots.take(0)
    assert_equal :create, slots.take(0)
    assert_nil slots.take(0)
  end

  def test_add_wakes_every_waiting_take
    2.times { slots.take(1) }
    waiters = Array.new(2) { Thread.new { slots.take(5) } }
    sleep 0.05
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    slots.add(2)

    assert_equal %i[create create], waiters.map(&:value)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 2
  end

  def test_reaps_the_connections_idle_since_before_the_cutoff
    3.times { slots(3).take(1) }
    3.times { |i| slots.put(:"c#{i}", i.to_f) }

    assert_empty slots.reap(0.0)
    assert_equal %i[c0 c1], slots.reap(1.5)
    assert_empty slots.reap(1.5)
    assert_equal :c2, slots.take(0)
    assert_equal :create, slots.take(0), "reaped connections leave their slots free"
  end

  def test_drain_removes_every_idle_connection
    2.times { slots.take(1) }
    slots.put(:a, 1.0)
    slots.put(:b, 2.0)

    assert_equal %i[a b], slots.drain
    assert_empty slots.drain
    assert_equal :create, slots.take(0)
  end
end

class SlotsTest < Minitest::Test
  include SlotsBehavior

  cover "Robin::Redis::Pool::Slots*"

  def slots_class = Robin::Redis::Pool::Slots

  # Asserts the block can't finish while another thread holds the lock.
  def assert_synchronized
    mutex = slots.instance_variable_get(:@mutex)
    mutex.lock
    thread = Thread.new { yield }

    assert_nil thread.join(0.2), "expected the slots to wait for their lock"
  ensure
    mutex.unlock
    thread&.join
  end

  def test_every_change_holds_the_lock
    slots.take(1)
    assert_synchronized { slots.take(1) }
    assert_synchronized { slots.put(:a, 1.0) }
    assert_synchronized { slots.release }
    assert_synchronized { slots.add(1) }
    assert_synchronized { slots.reap(1.0) }
    assert_synchronized { slots.drain }
  end
end

if defined?(Robin::Redis::NativeSlots)
  class NativeSlotsTest < Minitest::Test
    include SlotsBehavior

    def slots_class = Robin::Redis::NativeSlots
  end
end
