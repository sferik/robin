# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class ProfilerTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Profiler*"

  Profiler = Robin::Profiler

  # Stands in for Vernier::Collector.
  class FakeCollector
    attr_reader :log

    def initialize(start: nil, stop: nil, gecko: '{"meta":{}}')
      @start = start
      @stop = stop
      @gecko = gecko
      @log = []
    end

    def start
      @log << :start
      raise @start if @start
    end

    def stop
      @log << :stop
      raise @stop if @stop

      Struct.new(:to_gecko).new(@gecko)
    end
  end

  def setup
    super
    Profiler.instance_variable_set(:@available, nil)
  end

  def teardown
    Profiler.instance_variable_set(:@available, nil)
    super
  end

  def payload(**extra) = {"jid" => "j1", "class" => "SlowJob", "queue" => "q", "profile" => true}.merge(extra.transform_keys(&:to_s))

  def with_collector(collector, &)
    stub_method(Profiler, :start, ->(_config) { collector.tap(&:start) }, &)
  end

  def middleware = Profiler::ServerMiddleware.new.tap { |m| m.config = config }

  def require_vernier
    skip "vernier needs CRuby" unless RUBY_ENGINE == "ruby"
    require "vernier"
  end

  def test_available_loads_vernier_once
    loads = []
    stub_method(Profiler, :require, ->(name) { (loads << name) && true }) do
      assert Profiler.available?(config)
      assert Profiler.available?(config)
    end

    assert_equal ["vernier"], loads
  end

  def test_unavailable_without_vernier_warns_once
    logs = capture_logs
    stub_method(Profiler, :require, ->(_) { raise LoadError, "cannot load such file -- vernier" }) do
      refute Profiler.available?(config)
      refute Profiler.available?(config)
    end

    assert_equal "WARN: profiling a job needs the vernier gem (CRuby); running it unprofiled\n", logs.string
  end

  def test_records_a_profile
    collector = FakeCollector.new(gecko: '{"meta":{"product":"x"}}')
    clock = [1_000, 1_250]
    result = nil
    stub_method(Robin, :now_ms, -> { clock.shift || 1_250 }) do
      with_collector(collector) { result = Profiler.profile(config, payload("display_class" => "Wrapped")) { :done } }
    end

    assert_equal :done, result
    assert_equal %i[start stop], collector.log
    data = redis("GET", config.key("profile", "j1"))

    assert_equal '{"meta":{"product":"x"}}', Zlib.gunzip(data)
    assert_in_delta Profiler::TTL, redis("TTL", config.key("profile", "j1")), 5
    assert_equal [{"jid" => "j1", "class" => "Wrapped", "queue" => "q", "label" => nil, "started_at" => 1_000,
                   "duration_ms" => 250, "ok" => true, "bytes" => data.bytesize}], Profiler.list
    assert_equal ["1000"], redis("ZRANGE", config.key("profiles"), 0, -1, "WITHSCORES").values_at(1)
    assert_equal '{"meta":{"product":"x"}}', Profiler.data("j1")
  end

  def test_failed_runs_are_recorded_and_raise
    error = assert_raises(RuntimeError) do
      with_collector(FakeCollector.new) { Profiler.profile(config, payload("profile" => :export)) { raise "boom" } }
    end

    assert_equal "boom", error.message
    assert_equal [false, "export", "SlowJob"], Profiler.list.first.values_at("ok", "label", "class")
  end

  def test_runs_unprofiled_when_the_profiler_cannot_start
    require_vernier
    logs = capture_logs
    collector = FakeCollector.new(start: RuntimeError.new("profile already started"))

    stub_method(Vernier::Collector, :new, ->(mode, opts) { (collector.log << [mode, opts]) && collector }) do
      assert_equal :ran, Profiler.profile(config, payload) { :ran }
    end

    assert_equal [[:wall, {}], :start], collector.log
    assert_equal "WARN: couldn't start the profiler (RuntimeError: profile already started); running the job unprofiled\n", logs.string
    assert_empty Profiler.list
  end

  def test_start_returns_a_running_collector
    require_vernier
    collector = FakeCollector.new

    stub_method(Vernier::Collector, :new, ->(*) { collector }) do
      assert_same collector, Profiler.start(config)
    end

    assert_equal [:start], collector.log
  end

  def test_storage_errors_are_reported_not_raised
    errors = capture_errors

    with_collector(FakeCollector.new(stop: RuntimeError.new("stop failed"))) do
      assert_equal 1, Profiler.profile(config, payload) { 1 }
    end
    ex, ctx = errors.first

    assert_equal "stop failed", ex.message
    assert_equal({context: "storing a job profile", job: payload}, ctx)
  end

  def test_profiles_too_big_are_dropped
    logs = capture_logs
    big = Random.new(1).bytes(64).unpack1("H*") * 4
    with_constant(Profiler, :MAX_BYTES, 100) do
      with_collector(FakeCollector.new(gecko: big)) { Profiler.profile(config, payload) { nil } }
      with_collector(FakeCollector.new(gecko: "{}")) { Profiler.profile(config, payload("jid" => "small")) { nil } }
    end

    assert_match(/\AWARN: profile of SlowJob jid=j1 is too big to keep \(\d+ bytes\)\n\z/, logs.string)
    assert_equal ["small"], Profiler.list.map { |e| e["jid"] }
    assert_equal 16 * 1024 * 1024, Profiler::MAX_BYTES
  end

  def test_keeps_the_newest_and_drops_old_ones
    times = [1_000, 2_000, 3_000]
    with_constant(Profiler, :KEEP, 2) do
      times.each_with_index do |t, i|
        stub_method(Robin, :now_ms, -> { t }) do
          with_collector(FakeCollector.new) { Profiler.profile(config, payload("jid" => "j#{i}")) { nil } }
        end
      end
    end

    assert_equal %w[j2 j1], Profiler.list.map { |e| e["jid"] }
    week = Profiler::TTL * 1000
    stub_method(Robin, :now_ms, -> { 3_000 + week }) do
      with_collector(FakeCollector.new) { Profiler.profile(config, payload("jid" => "late")) { nil } }
    end

    # j2 (started 3000) is exactly a week old: kept; j1 is older: dropped.
    assert_equal %w[late j2], Profiler.list.map { |e| e["jid"] }
    assert_equal 100, Profiler::KEEP
    assert_equal 604_800, Profiler::TTL
  end

  def test_data_and_delete
    with_collector(FakeCollector.new) { Profiler.profile(config, payload) { nil } }
    with_collector(FakeCollector.new) { Profiler.profile(config, payload("jid" => "other")) { nil } }

    assert Profiler.delete("j1")
    assert_nil Profiler.data("j1")
    assert_equal ["other"], Profiler.list.map { |e| e["jid"] }
    refute Profiler.delete("j1")
    assert_equal ["other"], Profiler.list.map { |e| e["jid"] }
  end

  def test_config_is_honored
    other = Robin::Config.new
    other.redis = {url: REDIS_URL}
    other.key_prefix = "#{key_prefix_for_test}other:"
    with_collector(FakeCollector.new) { Profiler.profile(other, payload) { nil } }

    assert_empty Profiler.list
    assert_equal ["j1"], Profiler.list(config: other).map { |e| e["jid"] }
    assert Profiler.data("j1", config: other)
    assert Profiler.delete("j1", config: other)
    assert_empty Profiler.list(config: other)
  ensure
    other.redis_pool.shutdown
  end

  # -- middleware ---------------------------------------------------------------

  def test_middleware_skips_jobs_without_the_option
    stub_method(Profiler, :available?, ->(_) { flunk "must not load vernier" }) do
      assert_equal :plain, middleware.call(nil, payload("profile" => nil), "q") { :plain }
      assert_equal :plain, middleware.call(nil, payload.except("profile"), "q") { :plain }
    end
  end

  def test_middleware_skips_when_vernier_is_missing
    stub_method(Profiler, :available?, ->(_) { false }) do
      stub_method(Profiler, :profile, ->(*) { flunk "must not profile" }) do
        assert_equal :plain, middleware.call(nil, payload, "q") { :plain }
      end
    end
  end

  def test_middleware_profiles_one_job_at_a_time
    seen = []
    stub_method(Profiler, :available?, ->(c) { (seen << c) && true }) do
      stub_method(Profiler, :profile, ->(c, p, &b) { (seen << [c, p, Profiler::LOCK.locked?]) && b.call }) do
        assert_equal :profiled, middleware.call(nil, payload, "q") { :profiled }
        Profiler::LOCK.synchronize do
          assert_equal :plain, Thread.new { middleware.call(nil, payload, "q") { :plain } }.value
        end
        assert_raises(RuntimeError) { middleware.call(nil, payload, "q") { raise "boom" } }
      end
    end

    assert_equal [config, [config, payload, true], config, config, [config, payload, true]], seen
    refute_predicate Profiler::LOCK, :locked?
  end

  def test_profiles_a_real_job
    require_vernier

    assert Profiler.available?(config)
    Profiler.profile(config, payload) { 20_000.times { |i| i.to_s } }
    profile = JSON.parse(Profiler.data("j1"))

    assert profile.fetch("meta").key?("startTime")
    assert_operator profile.fetch("threads").size, :>=, 1
  end

  def test_server_middleware_only_applies_to_profiled_jobs
    middleware = Robin::Profiler::ServerMiddleware

    assert_true middleware.applies?(nil, {"profile" => 1}, "q")
    assert_false middleware.applies?(nil, {"jid" => "j"}, "q")
  end
end
