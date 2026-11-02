# frozen_string_literal: true

require_relative "test_helper"
require "puma/events"
require "puma/plugin/robin"

class PumaPluginTest < RobinTest
  cover "Puma::RobinPlugin*"

  # What the plugin uses of Puma::Launcher.
  FakeLauncher = Struct.new(:events, :options, :log_writer)

  class FakeLogWriter
    attr_reader :lines

    def initialize = @lines = []

    def log(line) = @lines << line
  end

  def setup
    super
    config.concurrency = 1
    config.timeout = 1
    @options = {workers: 0, worker_shutdown_timeout: 30}
    @log = FakeLogWriter.new
    @launcher = FakeLauncher.new(Puma::Events.new, @options, @log)
    @plugin = Puma::RobinPlugin.new
  end

  def teardown
    @plugin.changed(:done)
    super
  end

  def processes = redis("SMEMBERS", config.key("processes"))

  def start = @plugin.start(@launcher)

  def state(name) = @launcher.events.fire(:state, name)

  def test_is_registered_as_robin
    assert_same Puma::RobinPlugin, Puma::Plugins.find("robin")
  end

  def test_robin_config_collects_blocks_in_the_options
    options = {}
    dsl = Puma::DSL.new(options, nil)
    first = proc {}
    second = proc {}
    dsl.robin_config(&first)
    dsl.robin_config(&second)

    assert_equal [first, second], options[:robin_config]
    error = assert_raises(ArgumentError) { dsl.robin_config }
    assert_equal "robin_config needs a block", error.message
  end

  def test_runs_while_the_server_runs
    required = []
    @plugin.define_singleton_method(:require) { |name| required << name && super(name) }
    start
    state(:booting)

    assert_empty processes
    state(:running)

    assert_equal 1, processes.size
    assert_equal ["robin"], required
    assert_predicate Robin, :server?
    assert_equal ["* Robin #{Robin::VERSION} running 1 worker thread(s)"], @log.lines
    state(:running) # already running

    assert_equal 1, processes.size
    state(:stop)
    state(:done)

    assert_empty processes
    assert_equal "* Robin stopped", @log.lines.last
    state(:done) # already stopped

    assert_equal 2, @log.lines.size
  end

  def test_stopping_starts_in_the_background_and_done_waits_for_it
    start
    state(:running)
    stopper = @plugin.changed(:stop)

    assert_instance_of Thread, stopper
    assert_same stopper, @plugin.changed(:done)
    refute_predicate stopper, :alive?
    assert_empty processes
  end

  def test_restart_and_halt_stop_too
    start
    %i[restart halt].each do |name|
      state(:running)

      assert_equal 1, processes.size
      state(name)
      state(:done)

      assert_empty processes
    end
  end

  def test_done_without_a_stopping_state_stops
    start
    state(:running)
    state(:done)

    assert_empty processes
  end

  def test_config_blocks_run_once_before_the_first_start
    calls = []
    @options[:robin_config] = [->(c) { calls << [:a, c] }, ->(c) { calls << [:b, c] }]
    start
    state(:running)

    assert_equal [[:a, config], [:b, config]], calls
    state(:done)
    state(:running)

    assert_equal 2, calls.size
  end

  def test_a_forked_worker_starts_its_own_server_and_leaves_its_parents_alone
    calls = 0
    @options[:robin_config] = [->(_) { calls += 1 }]
    start
    state(:running)
    parent = processes
    parents = @plugin.instance_variable_get(:@robin)
    @plugin.instance_variable_set(:@pid, -1) # as if this were a forked child
    state(:done) # the parent's server isn't this process's to stop

    assert_equal parent, processes
    state(:running)

    assert_equal 2, processes.size
    assert_equal 1, calls
    state(:done) # its own server

    assert_equal parent, processes
  ensure
    parents&.stop
  end

  def test_a_failed_start_is_logged_and_retried
    attempts = 0
    @options[:robin_config] = [->(_) { raise "bad config" if (attempts += 1) == 1 }]
    start
    state(:running)

    assert_empty processes
    assert_equal "! Robin failed to start: bad config (RuntimeError)", @log.lines.first
    assert_operator @log.lines.size, :>, 2
    assert_match(/\A    \S+puma_plugin_test\.rb:\d+:in /, @log.lines[1])
    assert_nil @plugin.changed(:done)
    state(:running)

    assert_equal 1, processes.size
  end

  def test_a_failed_stop_is_logged
    broken = Object.new
    def broken.stop = raise("no stopping")
    start
    @plugin.changed(:booting) # adopts this process
    @plugin.instance_variable_set(:@robin, broken)
    state(:done)

    assert_equal "! Robin failed to stop: no stopping (RuntimeError)", @log.lines.first
    assert_match(/\A    \S+puma_plugin_test\.rb:\d+:in /, @log.lines[1])
  end

  def test_warns_when_puma_may_kill_workers_before_robin_has_stopped
    @options.update(workers: 2, worker_shutdown_timeout: 30)
    config.timeout = 27 # plus 3s of grace: 30
    start
    state(:running)

    assert_equal "! Robin may need 30s to stop (config.timeout plus 3s), but Puma kills workers " \
      "after worker_shutdown_timeout (30s)", @log.lines.first
  end

  def test_no_timeout_warning_with_room_to_stop
    @options.update(workers: 2, worker_shutdown_timeout: 30)
    config.timeout = 26.9
    start
    state(:running)

    assert_equal 1, @log.lines.size
  end

  def test_no_timeout_warning_in_single_mode
    config.timeout = 60
    start
    state(:running)

    assert_equal 1, @log.lines.size
  end

  MASTER_WARNING = /\A! Robin is loaded in Puma's master process.*extra_runtime_dependencies \["robin"\]\z/m

  def test_warns_when_robin_is_loaded_in_a_pruned_master
    with_pruned_env("1") do
      without_robin_spec { start }
    end

    assert_match MASTER_WARNING, @log.lines.first
  end

  def test_warns_when_robin_is_activated_in_a_pruned_master
    with_pruned_env("1") do
      without_configure_embed { start }
    end

    assert_match MASTER_WARNING, @log.lines.first
  end

  def test_no_warning_when_robin_is_absent_from_a_pruned_master
    with_pruned_env("1") do
      without_robin_spec { without_configure_embed { start } }
    end

    assert_empty @log.lines
  end

  def test_no_warning_without_a_pruned_bundle
    with_pruned_env(nil) { start }

    assert_empty @log.lines
  end

  private

  def with_pruned_env(value)
    original = ENV.fetch("PUMA_BUNDLER_PRUNED", nil)
    ENV["PUMA_BUNDLER_PRUNED"] = value
    yield
  ensure
    ENV["PUMA_BUNDLER_PRUNED"] = original
  end

  def without_robin_spec
    spec = Gem.loaded_specs.delete("robin")
    yield
  ensure
    Gem.loaded_specs["robin"] = spec if spec
  end

  def without_configure_embed
    original = Robin.method(:configure_embed)
    Robin.singleton_class.remove_method(:configure_embed)
    yield
  ensure
    Robin.define_singleton_method(:configure_embed, original)
  end
end
