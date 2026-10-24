# frozen_string_literal: true

require_relative "test_helper"

class MiddlewareTest < Minitest::Test
  cover "Robin::Middleware*"

  class Tracer
    def initialize(log, name = "t")
      @log = log
      @name = name
    end

    def call(*)
      @log << "#{@name}>"
      result = yield
      @log << "<#{@name}"
      result
    end
  end

  class A < Tracer; end

  class B < Tracer; end

  class C < Tracer; end

  class ArgsRecorder
    def initialize(log)
      @log = log
    end

    def call(*args)
      @log << args
      yield
    end
  end

  class YieldsAValue
    def call(*) = yield(:extra)
  end

  class AlsoYieldsAValue < YieldsAValue; end

  class Halt
    def call(*) = :halted
  end

  class Aware
    include Robin::Middleware::ConfigAware

    def call(*) = yield
  end

  class Shared
    include Robin::Middleware::ConfigAware
    include Robin::Middleware::Stateless

    attr_reader :args

    def initialize(*args)
      @args = args
    end

    def call(*) = yield
  end

  class Picky < Tracer
    def self.applies?(*args) = args.first == :wanted
  end

  class Marks
    def call(_job, payload, _queue)
      payload["marked"] = true
      yield
    end
  end

  class OnlyMarked < Tracer
    def self.applies?(_job, payload, _queue) = payload.key?("marked")
  end

  def setup
    @config = Robin::Config.new
    @chain = Robin::Middleware::Chain.new(@config)
    @log = []
  end

  def names = @chain.map(&:klass)

  def test_passes_args_to_every_middleware
    @chain.add(ArgsRecorder, @log).add(YieldsAValue).add(ArgsRecorder, @log)
    @chain.prepend(ArgsRecorder, @log)

    assert_equal :done, @chain.invoke(1, [2], three: 3) { :done }
    assert_equal [[1, [2], {three: 3}]], @log
    @log.clear
    @chain.clear.add(ArgsRecorder, @log)
    @chain.invoke { nil }

    assert_equal [[]], @log
  end

  def test_middleware_that_does_not_apply_is_skipped_and_never_built
    built = 0
    picky = Class.new(Picky) { define_method(:initialize) { |*args| super(*args).tap { built += 1 } } }
    @chain.add(A, @log, "a").add(picky, @log, "p").add(B, @log, "b")

    assert_equal :ok, @chain.invoke(:other) { :ok }
    assert_equal %w[a> b> <b <a], @log
    assert_equal 0, built
    @log.clear
    @chain.invoke(:wanted) { nil }

    assert_equal %w[a> p> b> <b <p <a], @log
    @log.clear
    @chain.clear.add(picky, @log, "p")

    assert_equal :ok, @chain.invoke(:other) { :ok }
    assert_empty @log
  end

  def test_applies_sees_what_earlier_middleware_did
    @chain.add(Class.new(OnlyMarked), @log, "before").add(Marks).add(OnlyMarked, @log, "after")
    @chain.invoke(:job, {}, "q") { nil }

    assert_equal %w[after> <after], @log
  end

  def test_middleware_may_yield_values
    @chain.add(YieldsAValue).add(AlsoYieldsAValue)

    assert_equal :ok, @chain.invoke { :ok }
  end

  def test_empty_chain_yields
    assert_true @chain.empty?
    @chain.add(A, @log)

    assert_false @chain.empty?
    @chain.clear

    assert_empty @chain
    assert_equal 42, @chain.invoke(1) { 42 }
  end

  def test_invoke_wraps_in_order_and_passes_args
    @chain.add(A, @log, "a")
    @chain.add(B, @log, "b")
    seen = nil
    result = @chain.invoke(:x, :y) do
      seen = :ran
      :value
    end

    assert_equal :value, result
    assert_equal :ran, seen
    assert_equal %w[a> b> <b <a], @log
  end

  def test_halting_middleware_skips_block
    @chain.add(Halt)
    ran = false

    assert_equal :halted, @chain.invoke { ran = true }
    refute ran
  end

  def test_add_replaces_existing_entry_at_end
    @chain.add(A, @log).add(B, @log).add(A, @log)

    assert_equal [B, A], names
  end

  def test_prepend
    assert_same @chain, @chain.add(A, @log).prepend(B, @log)

    assert_equal [B, A], names
    @chain.prepend(A, @log)

    assert_equal [A, B], names
  end

  def test_insert_before_and_after
    @chain.add(A, @log).add(C, @log)

    assert_same @chain, @chain.insert_before(C, B, @log)
    assert_equal [A, B, C], names
    assert_same @chain, @chain.insert_after(A, C, @log)
    assert_equal [A, C, B], names
    @chain.insert_before(A, B, @log)

    assert_equal [B, A, C], names
  end

  def test_every_insertion_keeps_config_and_args
    %i[add prepend].each do |how|
      chain = Robin::Middleware::Chain.new(@config)
      chain.public_send(how, ArgsRecorder, @log)
      check_entry(chain.entries.first)
      chain.public_send(how, Aware)

      assert_same @config, chain.entries.find { |e| e.klass == Aware }.build.config
    end
    [[:insert_before, A], [:insert_after, A]].each do |how, target|
      chain = Robin::Middleware::Chain.new(@config).add(A, @log)
      chain.public_send(how, target, ArgsRecorder, @log)
      check_entry(chain.entries.find { |e| e.klass == ArgsRecorder })
      chain.public_send(how, target, Aware)
      aware = chain.entries.find { |e| e.klass == Aware }.build

      assert_same @config, aware.config
    end
  end

  def check_entry(entry)
    built = entry.build
    built.call(:x) { nil }

    assert_equal [:x], @log.pop
  end

  def test_insert_after_missing_target_appends
    @chain.add(A, @log).add(B, @log).add(C, @log).insert_after(Halt, Aware)

    assert_equal [A, B, C, Aware], names
  end

  def test_insert_with_missing_target
    @chain.add(A, @log).add(B, @log)
    @chain.insert_before(Halt, C, @log)

    assert_equal [C, A, B], names
    @chain.insert_after(Halt, C, @log)

    assert_equal [A, B, C], names
  end

  def test_remove_exists_and_clear
    @chain.add(A, @log).add(B, @log)

    assert @chain.exists?(A)
    assert_same @chain, @chain.remove(A)
    assert_equal [B], names
    assert @chain.exists?(B)
    refute @chain.exists?(A)
    assert_same @chain, @chain.clear
    assert_empty @chain
  end

  def test_dup_copies_entries
    @chain.add(A, @log)
    copy = @chain.dup
    copy.add(B, @log)

    assert_equal [A], names
    assert_equal [A, B], copy.map(&:klass)
  end

  class AlsoRecordsArgs < ArgsRecorder; end

  def test_every_middleware_gets_the_arguments
    @chain.add(ArgsRecorder, @log)
    @chain.add(AlsoRecordsArgs, @log)
    @chain.invoke(1, 2) { :done }

    assert_equal [[1, 2], [1, 2]], @log
  end

  def test_entries_are_frozen_after_every_change
    assert_predicate @chain.entries, :frozen?
    [-> { @chain.add(A, @log) }, -> { @chain.prepend(B, @log) }, -> { @chain.insert_before(A, C, @log) },
      -> { @chain.insert_after(A, C, @log) }, -> { @chain.remove(C) }, -> { @chain.clear }].each do |change|
      change.call

      assert_predicate @chain.entries, :frozen?
    end
  end

  # Adds C to the chain while running.
  class AddsC
    def initialize(chain, log)
      @chain = chain
      @log = log
    end

    def call(*)
      @chain.add(C, @log)
      yield
    end
  end

  def test_changes_while_invoking_wait_for_the_next_job
    @chain.add(AddsC, @chain, @log)
    @chain.invoke { @log << "job" }

    assert_equal ["job"], @log
    @chain.invoke { @log << "job" }

    assert_equal ["job", "t>", "job", "<t"], @log
  end

  def test_config_aware_middleware
    @config.redis = {url: REDIS_URL}
    @chain.prepend(Aware)
    built = @chain.entries.first.build

    assert_same @config, built.config
    assert_same @config.logger, built.logger
    assert_equal "PONG", built.redis { |c| c.call("PING") }
  ensure
    @config.redis_pool.shutdown
  end

  def test_middleware_is_built_for_every_job
    @chain.add(Aware)
    entry = @chain.entries.first

    refute_same entry.build, entry.build
  end

  def test_stateless_middleware_is_built_once
    @chain.add(Shared, 1, 2)
    entry = @chain.entries.first
    built = entry.build

    assert_same built, entry.build
    assert_equal [1, 2], built.args
    assert_same @config, built.config
    assert_equal :ok, @chain.invoke { :ok }
    assert_same built, entry.build
  end

  def test_built_in_middleware_is_stateless
    (@config.client_middleware.entries + @config.server_middleware.entries).each do |entry|
      assert_same entry.build, entry.build, entry.klass
    end
  end

  def test_build_passes_arguments
    @chain.add(A, @log, "z")
    @chain.entries.first.build.call { nil }

    assert_equal %w[z> <z], @log
  end
end
