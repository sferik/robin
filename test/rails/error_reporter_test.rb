# frozen_string_literal: true

require_relative "helper"

class ErrorReporterTest < RobinTest
  cover "Robin::Rails::ErrorReporter*"

  # Records what it's asked to report.
  class FakeReporter
    attr_reader :reports

    def initialize = @reports = []

    def report(error, **details) = @reports << [error, details]
  end

  # A job that always fails.
  class FlakyJob
    include Robin::Job

    def perform(name) = raise(ArgumentError, "bad #{name}")
  end

  def setup
    super
    @reporter = FakeReporter.new
    @handler = Robin::Rails::ErrorReporter.new(@reporter)
  end

  def test_reports_failed_jobs_as_unhandled
    error = RuntimeError.new("boom")
    job = {"class" => "Robin::ActiveJob::Wrapper", "display_class" => "ReportJob", "jid" => "j1", "queue" => "q",
           "retry_count" => 2, "bid" => "b1", "args" => ["secret"]}
    @handler.call(error, {context: "job raised", job: job, queue: "low"}, config)

    assert_equal [[error, {handled: false, source: "robin.job",
                           context: {robin: "job raised", queue: "low", jid: "j1", job_class: "ReportJob", retry_count: 2, bid: "b1"}}]],
      @reporter.reports
  end

  def test_job_details_default_from_the_payload
    @handler.call(RuntimeError.new, {context: "death handler", job: {"class" => "Plain", "queue" => "q", "jid" => "j2"}}, config)

    assert_equal [{handled: true, source: "robin", context: {robin: "death handler", queue: "q", jid: "j2", job_class: "Plain"}}],
      @reporter.reports.map(&:last)
  end

  def test_reports_robins_own_errors_as_handled
    @handler.call(RuntimeError.new, {context: "fetch"}, config)
    @handler.call(RuntimeError.new, {}, config)

    assert_equal [{handled: true, source: "robin", context: {robin: "fetch"}}, {handled: true, source: "robin", context: {}}],
      @reporter.reports.map(&:last)
  end

  # Rails 7.0's Rails.error takes no source.
  def test_reports_to_a_reporter_without_sources
    reports = []
    reporter = Object.new
    reporter.define_singleton_method(:report) { |error, handled:, context:| reports << [error.message, handled, context] }
    handler = Robin::Rails::ErrorReporter.new(reporter)
    handler.call(RuntimeError.new("job"), {context: "job raised", job: {"class" => "X", "jid" => "j"}}, config)
    handler.call(RuntimeError.new("own"), {context: "fetch"}, config)

    assert_equal [["job", false, {robin: "job raised", jid: "j", job_class: "X"}], ["own", true, {robin: "fetch"}]], reports
    sourced = Object.new
    sourced.define_singleton_method(:report) { |error, handled:, context:, source: nil| reports << source }
    Robin::Rails::ErrorReporter.new(sourced).call(RuntimeError.new, {context: "fetch"}, config)

    assert_equal "robin", reports.last
  end

  def test_rails_error_reports_each_exception_once
    skip "ActiveSupport::ErrorReporter is from Rails 7.0" unless defined?(ActiveSupport::ErrorReporter)
    rails_reporter = ActiveSupport::ErrorReporter.new
    seen = FakeReporter.new
    rails_reporter.subscribe(seen)
    handler = Robin::Rails::ErrorReporter.new(rails_reporter)
    error = RuntimeError.new("once")
    handler.call(error, {context: "job raised", job: {"class" => "X"}}, config)
    rails_reporter.report(error, handled: false) # (Rails 7.0 needs handled:)
    # From Rails 7.1, an exception is reported once, with its source; Rails
    # 7.0 reports it again, and takes no source.
    rails_7_1 = ActiveSupport::ErrorReporter.instance_method(:report).parameters.include?([:key, :source])

    assert_equal (rails_7_1 ? 1 : 2), seen.reports.size
    assert_equal [("robin.job" if rails_7_1), false, :error], seen.reports.first.last.values_at(:source, :handled, :severity)
  end

  def test_reports_a_failing_job_from_the_server
    Robin.server!
    config.queues = ["default"]
    config.error_handlers << @handler
    FlakyJob.perform_async("x")
    launcher = Robin::Launcher.new(config).run
    report = eventually { @reporter.reports.first }
    launcher.stop
    error, details = report

    assert_equal "bad x", error.message
    assert_equal({robin: "job raised", queue: "default", job_class: "ErrorReporterTest::FlakyJob"}, details[:context].except(:jid))
    assert_equal "robin.job", details[:source]
  ensure
    Robin.instance_variable_set(:@server, nil)
  end
end
