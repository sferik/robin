# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "robin"
require "minitest/autorun"
require "minitest/strict"

begin
  require "robin_resp/robin_resp"
rescue LoadError
  nil
end

# Robin::NativeGVL, the C extension's GVL wait timer.
class GVLNativeTest < Minitest::Test
  def setup
    skip "needs the C extension (run `rake compile`)" unless defined?(Robin::NativeGVL)
    Robin::NativeGVL.stop
  end

  def teardown
    Robin::NativeGVL.stop if defined?(Robin::NativeGVL)
  end

  def gvl = Robin::NativeGVL

  # Threads that only compute keep each other waiting for the GVL.
  def spin(threads, iterations = 2_000_000)
    Array.new(threads) do
      Thread.new do
        x = 0
        iterations.times { x += 1 }
      end
    end.each(&:join)
  end

  def test_start_and_stop
    refute_predicate gvl, :running?
    assert_nil gvl.start
    assert_predicate gvl, :running?
    assert_nil gvl.start # already running

    assert_predicate gvl, :running?
    assert_nil gvl.stop
    refute_predicate gvl, :running?
    assert_nil gvl.stop # already stopped
  end

  def test_contended_threads_wait
    gvl.start
    before = gvl.wait_ns
    spin(4)
    waited = gvl.wait_ns - before

    assert_kind_of Integer, waited
    assert_operator waited, :>, 10_000_000 # 10ms: they took turns for far longer
  end

  # A thread woken by another (a new one, or one joining a thread that
  # ends) starts waiting on the waker's native thread: counted from then,
  # not from an earlier wait of whatever thread last ran there. Threads
  # that only sleep hardly wait at all (it once counted ~385ms here).
  def test_threads_woken_by_others_are_counted_from_their_waking
    gvl.start
    before = gvl.wait_ns
    Array.new(4) { Thread.new { 3.times { sleep 0.05 } } }.each(&:join)
    Thread.new { sleep 0.2 }.join
    waited = gvl.wait_ns - before

    assert_operator waited, :<, 100_000_000 # 100ms
  end

  def test_nothing_is_counted_while_stopped
    gvl.start
    gvl.stop
    before = gvl.wait_ns
    spin(4)

    assert_equal before, gvl.wait_ns
  end

  # Threads already waiting for the GVL when measuring starts have no start
  # time; their first turn isn't counted, or the total would jump.
  def test_threads_waiting_before_it_started
    started = Queue.new
    threads = Array.new(3) do
      Thread.new do
        started << true
        x = 0
        3_000_000.times { x += 1 }
      end
    end
    3.times { started.pop }
    before = gvl.wait_ns
    gvl.start
    threads.each(&:join)
    waited = gvl.wait_ns - before

    assert_operator waited, :<, 60 * 1_000_000_000
  end
end
