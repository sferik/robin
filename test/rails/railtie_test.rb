# frozen_string_literal: true

require_relative "helper"
require "rails"
require "active_job/railtie"

# Defined (but only initialized on demand) so it has a valid app name.
class RobinRailsTestApp < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "robin-test"
  config.active_support.deprecation = :silence
  config.root = Dir.pwd
end

module RailtieTestApp
  # Boots the app once, against a config of its own.
  def self.boot
    @boot ||= begin
      previous = Robin.config
      Robin.config = Robin::Config.new
      RobinRailsTestApp.initialize!
      [RobinRailsTestApp.instance, Robin.config]
    ensure
      Robin.config = previous
    end
  end
end

class RailtieTest < Minitest::Test
  cover "Robin::Rails::Railtie*"

  # A reloader that records what it wraps, and what errors pass through it.
  class FakeReloader
    attr_reader :wrapped, :errors

    def initialize
      @wrapped = 0
      @errors = []
    end

    def wrap
      @wrapped += 1
      yield
    rescue Exception => e # rubocop:disable Lint/RescueException
      @errors << e
      raise
    end
  end

  # Records Rails.error reports.
  class Subscriber
    attr_reader :reports

    def initialize = @reports = []

    def report(error, **details) = @reports << [error, details]
  end

  FakeApp = Struct.new(:reloader, :config)

  def setup
    @config = Robin::Config.new
    @config.logger = Logger.new(nil)
    @server = Robin.server?
    @rails_logger = Rails.logger
  end

  def teardown
    Robin.instance_variable_set(:@server, @server)
    Rails.logger = @rails_logger
  end

  def client! = Robin.instance_variable_set(:@server, false)

  def fake_app(reloader = FakeReloader.new, report_errors: false, transactional_push: false, current_attributes: [],
    notifications: false)
    options = ActiveSupport::OrderedOptions.new
    options.robin = ActiveSupport::OrderedOptions.new
    options.robin.report_errors = report_errors
    options.robin.transactional_push = transactional_push
    options.robin.current_attributes = current_attributes
    options.robin.notifications = notifications
    FakeApp.new(reloader, options)
  end

  def test_boots_inside_a_rails_app
    app, booted = RailtieTestApp.boot

    assert_same app, Rails.application
    assert_equal %w[robin.environment robin.active_job], Rails.application.initializers.map(&:name).grep(/\Arobin\./)
    assert_equal Rails.env, booted.environment
    refute_nil booted.job_wrapper
    # (Rails.error is there from Rails 7.0.)
    reporters = Rails.respond_to?(:error) ? [Robin::Rails::ErrorReporter] : []

    assert_equal [Robin::Config::DEFAULT_ERROR_HANDLER, *reporters], booted.error_handlers.map { |h| h.is_a?(Proc) ? h : h.class }
    assert_nil booted.push_deferrer
    assert_equal [Robin::Rails::Notifications], booted.event_handlers
    assert_equal({report_errors: true, transactional_push: false, current_attributes: [], notifications: true}, app.config.robin.to_h)
    assert ActiveJob::Base # loading it loads the integration
    assert defined?(ActiveJob::QueueAdapters::RobinAdapter)
  end

  def test_initializers_run_before_the_apps_and_active_jobs
    names = Rails.application.initializers.tsort_each.map(&:name)

    assert_operator names.index("robin.environment"), :<, names.index(:load_config_initializers)
    assert_operator names.index("robin.active_job"), :<, names.index("active_job.set_configs")
  end

  # Runs the block with a Subscriber to Rails.error (from Rails 7.0), and
  # unsubscribes it: with unsubscribe, from Rails 7.1.
  def subscribed
    subscriber = Subscriber.new
    Rails.error.subscribe(subscriber)
    yield subscriber
  ensure
    if Rails.error.respond_to?(:unsubscribe)
      Rails.error.unsubscribe(subscriber)
    else
      Rails.error.instance_variable_get(:@subscribers).delete(subscriber)
    end
  end

  def test_jobs_run_in_the_apps_reloader_and_errors_skip_the_executor
    skip "Rails.error is from Rails 7.0" unless Rails.respond_to?(:error)
    app, = RailtieTestApp.boot
    subscribed do |subscriber|
      wrapper = Robin::Rails::Railtie.job_wrapper(app)
      ran_inside = nil

      assert_equal :done, wrapper.call({}) { ran_inside = app.executor.active? && :done }
      assert_equal :done, ran_inside
      assert_raises(Robin::Discard) { wrapper.call({}) { raise Robin::Discard } }
      assert_empty subscriber.reports
    end
  end

  def test_job_wrapper
    reloader = FakeReloader.new
    wrapper = Robin::Rails::Railtie.job_wrapper(fake_app(reloader))

    assert_equal :done, wrapper.call({"class" => "X"}) { :done }
    assert_nil wrapper.call({}) {}
    boom = RuntimeError.new("boom")
    error = assert_raises(RuntimeError) { wrapper.call({}) { raise boom } }

    assert_same boom, error
    assert_equal 3, reloader.wrapped
    assert_empty reloader.errors
  end

  def test_jobs_log_through_rails_with_tags
    io = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::TaggedLogging.new(Logger.new(io))
    wrapper = Robin::Rails::Railtie.job_wrapper(fake_app)
    wrapper.call({"class" => "Wrapper", "display_class" => "SignupJob", "jid" => "j1"}) { Rails.logger.info("hello") }
    wrapper.call({"class" => "PlainJob", "jid" => "j2"}) { Rails.logger.info("again") }
    # The processor passes the job as a lambda, which a tagged logger's
    # yielding itself mustn't break.
    result = wrapper.call({"class" => "LambdaJob", "jid" => "j3"}, &-> { Rails.logger.info("strict") && :ran })

    assert_equal ["[SignupJob jid=j1] hello", "[PlainJob jid=j2] again", "[LambdaJob jid=j3] strict"], io.string.lines(chomp: true)
    assert_equal :ran, result
  ensure
    Rails.logger = previous
  end

  def test_jobs_run_untagged_with_a_plain_logger
    previous = Rails.logger
    Rails.logger = Logger.new(nil)

    assert_equal :ok, Robin::Rails::Railtie.job_wrapper(fake_app).call({"class" => "X"}) { :ok }
  ensure
    Rails.logger = previous
  end

  def test_integrate_wraps_jobs_in_the_reloader
    reloader = FakeReloader.new
    Robin::Rails::Railtie.integrate(fake_app(reloader), config: @config)

    assert_equal :done, @config.job_wrapper.call({"class" => "X"}) { :done }
    assert_equal 1, reloader.wrapped
  end

  def test_integrate_keeps_an_existing_wrapper
    existing = ->(_payload, &job) { job.call }
    @config.job_wrapper = existing
    Robin::Rails::Railtie.integrate(fake_app, config: @config)

    assert_same existing, @config.job_wrapper
  end

  def test_integrate_cleans_backtraces_with_rails
    Robin::Rails::Railtie.integrate(fake_app, config: @config)
    app_line = "#{Rails.root}/app/jobs/x.rb:1"
    gem_line = "#{Gem.paths.home}/gems/rack-3.0/lib/rack.rb:2"

    assert_equal Rails.backtrace_cleaner.clean([app_line, gem_line]), @config.backtrace_cleaner.call([app_line, gem_line])
    refute_includes @config.backtrace_cleaner.call([app_line, gem_line]), gem_line
  end

  def test_integrate_keeps_an_existing_backtrace_cleaner
    existing = ->(lines) { lines }
    @config.backtrace_cleaner = existing
    Robin::Rails::Railtie.integrate(fake_app, config: @config)

    assert_same existing, @config.backtrace_cleaner
  end

  def test_integrate_uses_rails_logger_outside_the_server
    client!
    Rails.logger = Logger.new(nil)
    Robin::Rails::Railtie.integrate(fake_app, config: @config)

    assert_same Rails.logger, @config.logger
  end

  def test_integrate_keeps_robin_logger_in_the_server
    Robin.server!
    Rails.logger = Logger.new(nil)
    Robin::Rails::Railtie.integrate(fake_app, config: @config)

    refute_same Rails.logger, @config.logger
  end

  def test_integrate_without_rails_logger
    client!
    Rails.logger = nil
    original = @config.logger
    Robin::Rails::Railtie.integrate(fake_app, config: @config)

    assert_same original, @config.logger
  end

  def test_integrate_reports_errors_to_rails_once
    skip "Rails.error is from Rails 7.0" unless Rails.respond_to?(:error)
    subscribed do |subscriber|
      app = fake_app(report_errors: true)
      Robin::Rails::Railtie.integrate(app, config: @config)
      Robin::Rails::Railtie.integrate(app, config: @config)
      reporters = @config.error_handlers.grep(Robin::Rails::ErrorReporter)

      assert_equal 1, reporters.size
      @config.handle_exception(RuntimeError.new("x"), {context: "fetch"})

      assert_equal ["x"], subscriber.reports.map { |error, _| error.message }
    end
  end

  # Before Rails 7.0, which has no Rails.error, there's nothing to report
  # to.
  def test_integrate_without_rails_error
    rails = Struct.new(:logger, :backtrace_cleaner).new(nil, nil)
    Robin::Rails::Railtie.integrate(fake_app(report_errors: true), config: @config, rails: rails)

    assert_empty @config.error_handlers.grep(Robin::Rails::ErrorReporter)
    reporter = Subscriber.new
    rails.define_singleton_method(:error) { reporter }
    Robin::Rails::Railtie.integrate(fake_app(report_errors: true), config: @config, rails: rails)

    assert_same reporter, @config.error_handlers.grep(Robin::Rails::ErrorReporter).first.instance_variable_get(:@reporter)
  end

  def test_integrate_without_error_reporting
    Robin::Rails::Railtie.integrate(fake_app(report_errors: false), config: @config)

    assert_equal [Robin::Config::DEFAULT_ERROR_HANDLER], @config.error_handlers
  end

  def test_integrate_transactional_push
    Robin::Rails::Railtie.integrate(fake_app, config: @config)

    assert_nil @config.push_deferrer
    Robin::Rails::Railtie.integrate(fake_app(transactional_push: true), config: @config)

    assert_same Robin::Rails::TransactionalPush, @config.push_deferrer
    custom = ->(_payloads, &_deliver) {}
    @config.push_deferrer = custom
    Robin::Rails::Railtie.integrate(fake_app(transactional_push: true), config: @config)

    assert_same custom, @config.push_deferrer
  end

  def test_integrate_current_attributes
    Robin::Rails::Railtie.integrate(fake_app, config: @config)

    refute @config.server_middleware.exists?(Robin::Rails::CurrentAttributes::Load)
    Robin::Rails::Railtie.integrate(fake_app(current_attributes: ["Current"]), config: @config)

    assert @config.client_middleware.exists?(Robin::Rails::CurrentAttributes::Save)
    assert @config.server_middleware.exists?(Robin::Rails::CurrentAttributes::Load)
  end

  def test_integrate_publishes_events_once
    Robin::Rails::Railtie.integrate(fake_app, config: @config)

    assert_empty @config.event_handlers
    app = fake_app(notifications: true)
    Robin::Rails::Railtie.integrate(app, config: @config)
    Robin::Rails::Railtie.integrate(app, config: @config)

    assert_equal [Robin::Rails::Notifications], @config.event_handlers
  end

  def test_integrate_defaults_to_global_config
    client!
    Rails.logger = Logger.new(nil)
    previous = Robin.config
    Robin.config = @config
    Robin::Rails::Railtie.integrate(fake_app)

    assert_same Rails.logger, @config.logger
    refute_nil @config.job_wrapper
  ensure
    Robin.config = previous
  end

  # In a Rails app, Rails is loaded before Bundler.require loads robin.
  def test_requiring_robin_after_rails_loads_the_integration
    lib = File.expand_path("../../lib", __dir__)
    script = 'require "rails"; require "robin"; p defined?(Robin::Rails::Railtie)'
    without = 'require "robin"; p [defined?(Robin::Rails), defined?(Rails)]'
    run = ->(code) { run_ruby(code, lib) }

    assert_equal %("constant"\n), run.call(script)
    assert_equal "[nil, nil]\n", run.call(without), "and nothing of it elsewhere"
  end

  # Loading ActiveJob::Base applies config.active_job as it stands, so
  # robin mustn't load it before the app's initializers (which may set
  # the queue adapter) have run.
  def test_an_initializers_active_job_settings_are_kept
    lib = File.expand_path("../../lib", __dir__)
    script = <<~RUBY
      require "rails"
      require "active_job/railtie"
      require "robin"
      require "robin/active_job"
      Class.new { include Robin::Job } # as an app's job class may, as it boots
      loaded = ActiveJob.autoload?(:Base).nil?
      class App < Rails::Application
        config.eager_load = false
        config.logger = Logger.new(nil)
        config.robin.current_attributes = ["Object"]
        initializer("app.adapter", after: :load_config_initializers) { config.active_job.queue_adapter = :inline }
      end
      App.initialize!
      p [loaded, ActiveJob::Base.queue_adapter_name]
    RUBY

    assert_equal %([false, "inline"]\n), run_ruby(script, lib)
  end
end
