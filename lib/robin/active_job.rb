# frozen_string_literal: true

require "active_job"
require "robin"

module Robin
  # ActiveJob integration.
  #
  #   # config/application.rb
  #   config.active_job.queue_adapter = :robin
  #
  #   class ReportJob < ApplicationJob
  #     robin_options retry: 5, expires_in: 3600, tags: ["reports"]
  #   end
  module ActiveJob
    # A Robin::Job inclusion check: ActiveJob classes run on Robin through
    # the adapter, not by including Robin::Job.
    REJECT_ACTIVE_JOB_CLASSES = lambda do |base|
      raise ArgumentError, "Robin::Job can't be included in ActiveJob classes" if base <= ::ActiveJob::Base
    end

    # robin_options that the adapter sets itself.
    IGNORED = %w[queue class args jid at].freeze

    # A Robin::Client rewriter: a job hash naming an ActiveJob class (as
    # periodic jobs may) becomes the wrapper's payload for
    # Class.new(*args), on the hash's queue or the job's own. Other keys
    # (e.g. "retry") override the class's robin_options. ActiveJob's
    # enqueue callbacks don't run, as with ActiveJob.perform_all_later.
    WRAP_ACTIVE_JOB_CLASSES = lambda do |item|
      klass = item["class"]
      next item unless klass.instance_of?(Class) && klass <= ::ActiveJob::Base

      job = klass.new(*item.fetch("args"))
      job.queue_name = item["queue"] if item["queue"]
      ActiveJob.payload(job, item["at"], item.except(*IGNORED))
    end

    # The Robin job hash that runs +job+ through Wrapper.
    def self.payload(job, timestamp, extra = {})
      options = job.class.respond_to?(:robin_options) ? job.class.robin_options.except(*IGNORED) : {} #: job_hash
      # The client defaults "retry" to true, accepts Time or epoch "at"
      # values, and drops a nil "at".
      options.merge(extra).merge(
        {"class" => Wrapper, "wrapped" => job.class.name, "display_class" => display_class(job),
         "queue" => job.queue_name, "args" => [job.serialize], "at" => timestamp}
      )
    end

    # Mail deliveries show as the mail they send ("UserMailer#welcome")
    # rather than all as ActionMailer::MailDeliveryJob.
    def self.display_class(job)
      return job.class.name unless job.class.ancestors.any? { |c| c.name == "ActionMailer::MailDeliveryJob" }

      mailer, mail = job.arguments
      "#{mailer}##{mail}"
    end

    # Runs ActiveJob jobs inside Robin.
    class Wrapper
      include Robin::Job

      def perform(job_data)
        Thread.current[:robin_active_job] = self
        ::ActiveJob::Base.execute(job_data.merge({"provider_job_id" => jid}))
      ensure
        Thread.current[:robin_active_job] = nil
      end
    end

    # Adds +robin_options+ to ActiveJob classes.
    module Options
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def robin_options(opts = nil)
          if opts
            @robin_options = robin_options.merge(opts.to_h { |k, v| [k.to_s, v.instance_of?(Symbol) ? v.to_s : v] })
          end
          @robin_options || (superclass.respond_to?(:robin_options) ? superclass.robin_options : {})
        end
      end
    end
  end
end

module ActiveJob
  module QueueAdapters
    # The ActiveJob adapter, selected with +queue_adapter = :robin+.
    class RobinAdapter < AbstractAdapter
      def enqueue(job)
        enqueue_at(job, nil)
      end

      def enqueue_at(job, timestamp)
        jid = Robin::Client.push(payload(job, timestamp))
        job.provider_job_id = jid
        job.successfully_enqueued = !jid.nil? if job.respond_to?(:successfully_enqueued=)
        jid
      end

      # Bulk enqueue (ActiveJob.perform_all_later): a bulk push per class,
      # queue and time, all in one round trip.
      def enqueue_all(jobs)
        pushed = Robin::Client.together do
          jobs.group_by do |j|
            [j.class, j.queue_name, j.scheduled_at] #: [Class, String, Time | Float | nil]
          end.map do |(_klass, _queue, scheduled_at), group|
            base = payload(group.first, scheduled_at)
            base["args"] = group.map { |j| [j.serialize] }
            [group, Robin::Client.push_bulk(base)] #: [Array[::ActiveJob::Base], Array[String?]]
          end
        end
        pushed.sum do |group, jids|
          group.zip(jids).count do |job, jid|
            job.provider_job_id = jid
            job.successfully_enqueued = !jid.nil? if job.respond_to?(:successfully_enqueued=)
            jid
          end
        end
      end

      # Lets ActiveJob::Continuation (Rails 8.1+) checkpoint when the server
      # shuts down. Rails 8.1's adapters keep +stopping+ the same way; older
      # ones have no such attribute, so it's defined here for all of them.
      attr_writer :stopping

      def stopping?
        job = Thread.current[:robin_active_job]
        job ? job.interrupted? : !!@stopping
      end

      private

      def payload(job, timestamp) = Robin::ActiveJob.payload(job, timestamp)
    end
  end
end

Robin::Job.inclusion_checks << Robin::ActiveJob::REJECT_ACTIVE_JOB_CLASSES
Robin::Client.rewriters << Robin::ActiveJob::WRAP_ACTIVE_JOB_CLASSES
ActiveSupport.on_load(:active_job) { include Robin::ActiveJob::Options }
