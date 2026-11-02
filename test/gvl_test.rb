# frozen_string_literal: true

require_relative "test_helper"

class GVLTest < RobinTest
  cover "Robin::GVL*"

  # Stands in for Robin::NativeGVL: wait_ns is whatever the test sets.
  class FakeNative
    attr_accessor :wait_ns
    attr_reader :log

    def initialize
      @wait_ns = 0
      @log = []
    end

    def start = @log << :start

    def stop = @log << :stop
  end

  def setup
    super
    @native = FakeNative.new
    @threads = 5
    @gvl = Robin::GVL.new(@native, threads: -> { @threads })
    @clock = 1_000_000_000
  end

  def at(ns, &) = stub_clock(ns, &)

  def stub_clock(ns)
    clock = ns
    Process.singleton_class.alias_method(:__gvl_test_clock, :clock_gettime)
    Process.define_singleton_method(:clock_gettime) do |*args|
      (args == [Process::CLOCK_MONOTONIC, :nanosecond]) ? clock : __gvl_test_clock(*args)
    end
    yield
  ensure
    Process.singleton_class.alias_method(:clock_gettime, :__gvl_test_clock)
    Process.singleton_class.remove_method(:__gvl_test_clock)
  end

  def test_native_is_the_extensions_where_there_is_one
    if Robin.const_defined?(:NativeGVL)
      assert_same Robin::NativeGVL, Robin::GVL.native
      assert_predicate Robin::GVL.new, :available?
    else
      assert_nil Robin::GVL.native
    end
  end

  def test_native_is_nil_without_the_extension
    hidden = Robin.send(:remove_const, :NativeGVL) if Robin.const_defined?(:NativeGVL)

    assert_nil Robin::GVL.native
    refute_predicate Robin::GVL.new, :available?
  ensure
    Robin.const_set(:NativeGVL, hidden) if hidden
  end

  def test_without_the_extension_it_measures_nothing
    gvl = Robin::GVL.new(nil)

    refute_predicate gvl, :available?
    assert_nil gvl.start
    assert_nil gvl.sample
    assert_nil gvl.stop
  end

  def test_nothing_is_sampled_before_it_starts
    assert_predicate @gvl, :available?
    assert_nil @gvl.sample
  end

  def test_samples_are_the_share_of_possible_waiting
    at(1_000_000_000) { @gvl.start }

    assert_equal [:start], @native.log
    # 4 other threads over 2s could wait 8s; they waited 2s.
    @native.wait_ns = 2_000_000_000

    assert_in_delta 25.0, at(3_000_000_000) { @gvl.sample }
    # Measured from the last sample: 1s more over 1s, of a possible 4s.
    @native.wait_ns = 3_000_000_000

    assert_in_delta 25.0, at(4_000_000_000) { @gvl.sample }
    @native.wait_ns = 3_000_123_456

    assert_in_delta 0.0, at(5_000_000_000) { @gvl.sample }
  end

  def test_samples_are_rounded_to_a_tenth
    at(0) { @gvl.start }
    @native.wait_ns = 1_234_567_890

    assert_in_delta 30.9, at(1_000_000_000) { @gvl.sample }
  end

  def test_samples_count_threads_as_they_are_now
    at(0) { @gvl.start }
    @threads = 3
    @native.wait_ns = 1_000_000_000

    assert_in_delta 50.0, at(1_000_000_000) { @gvl.sample }
  end

  def test_samples_never_exceed_a_hundred
    at(0) { @gvl.start }
    @native.wait_ns = 9_000_000_000

    assert_in_delta 100.0, at(1_000_000_000) { @gvl.sample }
  end

  def test_a_single_thread_or_no_time_is_no_contention
    at(0) { @gvl.start }
    @threads = 1
    @native.wait_ns = 5

    assert_in_delta 0.0, at(1_000_000_000) { @gvl.sample }
    @threads = 2

    assert_in_delta 0.0, at(1_000_000_000) { @gvl.sample }
  end

  def test_stop
    @gvl.stop

    assert_equal [:stop], @native.log
  end

  # Three threads that always want the GVL, sampled while they're running
  # (#sample counts the threads alive then: once they're joined, a
  # process with no others would have nothing to compare with).
  def test_with_the_extension
    skip "needs the C extension" unless Robin.const_defined?(:NativeGVL)

    gvl = Robin::GVL.new
    done = false
    begin
      gvl.start
      threads = Array.new(3) { Thread.new { nil until done } }
      sleep 0.3
      percent = gvl.sample
    ensure
      done = true
      threads&.each(&:join)
      gvl.stop
    end

    assert_operator percent, :>, 0
    assert_operator percent, :<=, 100
  end
end
