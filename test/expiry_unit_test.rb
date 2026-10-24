# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/statsd_recorder"

class ExpiryUnitTest < RobinTest
  cover "Robin::Expiry*"

  class Job
    include Robin::Job

    def perform = nil
  end

  def setup
    super
    @log = StringIO.new
    @mw_config = Robin::Config.new
    @mw_config.redis = {url: REDIS_URL}
    @mw_config.key_prefix = "#{key_prefix_for_test}mw:"
    @mw_config.logger = Logger.new(@log, formatter: ->(_, _, _, msg) { "#{msg}\n" })
  end

  def teardown
    @mw_config.redis_pool.shutdown
    super
  end

  def middleware = Robin::Expiry::ServerMiddleware.new.tap { |m| m.config = @mw_config }

  def test_expired
    now = 1_000

    refute Robin::Expiry.expired?({}, now)
    refute Robin::Expiry.expired?({"expires_at" => nil}, now)
    assert Robin::Expiry.expired?({"expires_at" => 999}, now)
    refute Robin::Expiry.expired?({"expires_at" => 1_000}, now)
    refute Robin::Expiry.expired?({"expires_at" => 1_001}, now)
  end

  def test_expired_defaults_to_now
    assert Robin::Expiry.expired?({"expires_at" => Robin.now_ms - 60_000})
    refute Robin::Expiry.expired?({"expires_at" => Robin.now_ms + 60_000})
  end

  def test_fresh_jobs_run
    assert_equal :ran, middleware.call(nil, {"expires_at" => Robin.now_ms + 60_000}, "q") { :ran }
    assert_equal :ran, middleware.call(nil, {}, "q") { :ran }
    assert_empty @log.string
  end

  def test_expired_jobs_are_skipped_and_logged
    ran = false
    result = nil
    # Not in a batch: nothing to tell Redis.
    pool = @mw_config.redis_pool
    @mw_config.redis_pool = Object.new.tap { |o| o.define_singleton_method(:with) { |&| raise "no round trip expected" } }
    begin
      result = middleware.call(nil, {"class" => "Foo", "jid" => "j9", "expires_at" => 1}, "q") { ran = true }
    ensure
      @mw_config.redis_pool = pool
    end

    assert_nil result
    refute ran
    assert_equal "skipping expired job Foo jid=j9\n", @log.string
    @mw_config.statsd = StatsdRecorder.new
    middleware.call(nil, {"class" => "W", "display_class" => "Foo", "jid" => "j8", "expires_at" => 1}, "q") { ran = true }

    assert_equal [[:increment, "jobs.expired", 1, {class: "Foo"}]], @mw_config.statsd.calls
  end

  def test_expired_jobs_are_events
    events = []
    @mw_config.event_handlers << ->(name, payload) { events << [name, payload] }
    payload = {"class" => "Foo", "jid" => "j9", "expires_at" => 1}
    middleware.call(nil, payload, "q") { :ran }
    middleware.call(nil, {"class" => "Foo", "jid" => "j8"}, "q") { :ran }

    assert_equal [["job.expired", {job: payload}]], events
  end

  def test_expired_batch_jobs_count_as_succeeded_in_the_middleware_config
    # Finishing the batch reports to StatsD; the middleware still returns nil.
    @mw_config.statsd = StatsdRecorder.new(distributions: true)
    batch = Robin::Batch.new(config: @mw_config)
    batch.jobs { batch.register("j1") }
    result = middleware.call(nil, {"class" => "Foo", "jid" => "j1", "bid" => batch.bid, "expires_at" => 1}, "q") { :ran }

    assert_nil result
    assert_predicate batch.status, :success?
  end

  def test_server_middleware_only_applies_to_expiring_jobs
    middleware = Robin::Expiry::ServerMiddleware

    assert_true middleware.applies?(nil, {"expires_at" => 1}, "q")
    assert_false middleware.applies?(nil, {"jid" => "j"}, "q")
  end
end
