# frozen_string_literal: true

require "monitor"
require "robin"

module Robin
  # Test helpers. Requiring this file switches Robin to fake mode: pushes
  # are kept in memory instead of going to Redis.
  #
  #   require "robin/testing"
  #
  #   HardJob.perform_async(1)
  #   assert_equal 1, HardJob.jobs.size
  #   HardJob.drain                   # runs them (and anything they push)
  #
  #   Robin::Testing.inline! do       # run jobs immediately when pushed
  #     HardJob.perform_async(2)
  #   end
  #
  #   Robin::Testing.disable!         # real Redis again
  #
  # Called with a block, a mode lasts for the block and only applies to
  # the current thread (so tests running in parallel don't disturb each
  # other); without one, it's the default for every thread.
  #
  # Client middleware runs in every mode; server middleware runs when
  # fake jobs are drained and in inline mode.
  module Testing
    class EmptyQueue < Robin::Error; end

    @mode = :fake
    @queues = Hash.new { |h, k| h[k] = [] }
    @mutex = Monitor.new
    MODE_KEY = :robin_testing_mode

    class << self
      # The current thread's mode.
      def mode = Thread.current[MODE_KEY] || @mode

      def fake!(&) = switch(:fake, &)

      def inline!(&) = switch(:inline, &)

      def disable!(&) = switch(:disable, &)

      def fake? = mode == :fake

      def inline? = mode == :inline

      def disabled? = mode == :disable

      # Every faked job, in push order, keyed by queue.
      attr_reader :queues

      # Every faked job across all queues.
      def jobs = @mutex.synchronize { @queues.values.flatten }

      def jobs_for(class_name)
        @mutex.synchronize { @queues.values.flatten.select { |j| j.fetch("class") == class_name } }
      end

      def clear_all = @mutex.synchronize { @queues.clear }

      def clear(class_name)
        @mutex.synchronize { @queues.each_value { |list| list.reject! { |j| j.fetch("class") == class_name } } }
      end

      # Runs faked jobs (including any they push) until none are left.
      def drain_all
        while (job = shift_next)
          execute(job)
        end
      end

      # Runs faked jobs of one class until none are left.
      def drain(class_name)
        while (job = shift_next(class_name))
          execute(job)
        end
      end

      def perform_one(class_name)
        job = shift_next(class_name) or raise EmptyQueue, "no #{class_name} jobs to perform"
        execute(job)
      end

      # Called by the client in place of a Redis push.
      def push(payloads)
        payloads.each do |payload|
          job = Robin.load_json(Robin.dump_json(payload))
          job["enqueued_at"] ||= Robin.now_ms unless job["at"]
          if inline?
            execute(job)
          else
            @mutex.synchronize { @queues[job.fetch("queue")] << job }
          end
        end
      end

      # Runs one job hash through the server middleware chain.
      def execute(payload, config: Robin.config)
        klass = Object.const_get(payload.fetch("class"))
        job = klass.new
        job.jid = payload.fetch("jid") if job.respond_to?(:jid=)
        job.payload = payload if job.respond_to?(:payload=)
        config.server_middleware.invoke(job, payload, payload["queue"]) do
          job.perform(*payload.fetch("args"))
        end
      end

      private

      def switch(mode)
        unless block_given?
          @mode = mode
          return
        end

        previous = Thread.current[MODE_KEY]
        Thread.current[MODE_KEY] = mode
        begin
          yield
        ensure
          Thread.current[MODE_KEY] = previous
        end
      end

      def shift_next(class_name = nil)
        @mutex.synchronize do
          candidates = @queues.values.flatten
          candidates = candidates.select { |j| j.fetch("class") == class_name } if class_name
          job = candidates.min_by { |j| j["at"] ? Robin.epoch_ms(j["at"]) : j["enqueued_at"] || 0 }
          @queues.fetch(job.fetch("queue")).delete(job) if job
        end
      end
    end

    # Routes pushes to memory unless testing is disabled. Returns the
    # payloads it handled, or nil to let Redis take them (see
    # Client.interceptor).
    def self.intercept(payloads) = (push(payloads) unless disabled?)

    # Class-level helpers on every Robin::Job class.
    module JobMethods
      def jobs = Testing.jobs_for(name)

      def clear = Testing.clear(name)

      def drain = Testing.drain(name)

      def perform_one = Testing.perform_one(name)
    end
  end

  # (lambda, not ->: Steep splats a -> lambda's one Array parameter.)
  Client.interceptor = lambda { |payloads| Testing.intercept(payloads) }
  Job::ClassMethods.include(Testing::JobMethods)
end
