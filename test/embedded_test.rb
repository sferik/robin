# frozen_string_literal: true

require_relative "test_helper"

class EmbeddedTest < RobinTest
  cover "Robin::Embedded*"

  def test_configure_yields_config_and_returns_self
    embed = Robin::Embedded.new(config)
    seen = nil

    assert_same embed, embed.configure { |c| seen = c }
    assert_same config, seen
    assert_same config, embed.config
    assert_same embed, embed.configure
    assert_nil embed.launcher
  end

  def test_configure_embed_shortcut
    embed = Robin.configure_embed { |c| c.concurrency = 3 }

    assert_instance_of Robin::Embedded, embed
    assert_equal 3, config.concurrency
  end

  def test_quiet_and_stop_before_run_are_noops
    embed = Robin::Embedded.new(config)

    assert_nil embed.quiet
    assert_nil embed.stop
  end

  def test_run_quiet_and_stop
    config.concurrency = 1
    config.timeout = 1
    old_pool = config.redis_pool
    embed = Robin::Embedded.new(config)

    assert_same embed, embed.run
    assert_predicate Robin, :server?
    refute_same old_pool, config.redis_pool
    assert_equal config.total_concurrency + 5, config.redis_pool.size
    launcher = embed.launcher

    assert_instance_of Robin::Launcher, launcher
    assert launcher.process_info["embedded"]
    assert_operator launcher.started_at, :>, 0
    assert_equal [launcher.identity], redis("SMEMBERS", config.key("processes"))
    assert_same config, launcher.config
    embed.quiet

    assert_predicate launcher, :quiet?
    embed.stop

    assert_predicate launcher, :stopping?
  ensure
    embed&.stop unless launcher&.stopping?
  end

  # Makes the launcher's #stop slow and counts the calls; yields a block
  # that tells whether a stop has finished.
  def slow_stops(launcher)
    stops = 0
    stopped = false
    real_stop = launcher.method(:stop)
    launcher.define_singleton_method(:stop) do
      stops += 1
      sleep 0.2
      real_stop.call
      stopped = true
    end
    [-> { stops }, -> { stopped }]
  end

  def test_a_second_stop_waits_for_the_first_and_does_nothing
    config.concurrency = 1
    config.timeout = 1
    embed = Robin::Embedded.new(config).run
    stops, stopped = slow_stops(embed.launcher)
    first = Thread.new { embed.stop }
    eventually { stops.call == 1 }

    assert_nil embed.stop
    assert stopped.call
    assert_equal 1, stops.call
    assert_empty redis("SMEMBERS", config.key("processes"))
  ensure
    first&.join
  end

  # A stop asked for from the dashboard takes the same path.
  def test_stop_waits_for_a_remote_stop
    config.concurrency = 1
    config.timeout = 1
    embed = Robin::Embedded.new(config).run
    stops, stopped = slow_stops(embed.launcher)
    remote = embed.launcher.request_stop
    eventually { stops.call == 1 }

    assert_nil embed.stop
    assert stopped.call
    assert_equal 1, stops.call
    assert_empty redis("SMEMBERS", config.key("processes"))
  ensure
    remote&.join
  end
end
