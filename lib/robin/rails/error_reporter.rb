# frozen_string_literal: true

module Robin
  module Rails
    # A Robin error handler that reports to the Rails error reporter
    # (Rails.error), so every service subscribed to it sees Robin's errors.
    # A failed job is reported as unhandled with source "robin.job"; Robin's
    # own errors (e.g. Redis unreachable while fetching) as handled with
    # source "robin". The context names the job, never its arguments.
    #
    # Rails.error reports an exception only once, so an app handler that
    # also calls Rails.error.report doesn't double-report.
    class ErrorReporter
      JOB_FAILED = "job raised"

      def initialize(reporter)
        @reporter = reporter
      end

      def call(exception, context, _config)
        job = context.fetch(:job, {})
        failed = context[:context] == JOB_FAILED
        details = {
          robin: context[:context], queue: context.fetch(:queue, job["queue"]), jid: job["jid"],
          job_class: Robin.display_class(job), retry_count: job["retry_count"], bid: job["bid"]
        }
        @reporter.report(exception, handled: !failed, source: failed ? "robin.job" : "robin", context: details.compact)
      end
    end
  end
end
