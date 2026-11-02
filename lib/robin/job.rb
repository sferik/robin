# frozen_string_literal: true

module Robin
  # Include in a class to make it a Robin job.
  #
  #   class Thumbnail
  #     include Robin::Job
  #     robin_options queue: "media", retry: 10, expires_in: 3600
  #
  #     def perform(image_id, size)
  #       ...
  #     end
  #   end
  #
  # Supported options (all optional):
  #
  # queue::      queue name (default "default")
  # retry::      true, false, or a maximum number of retries
  # retry_for::  seconds after the first failure to keep retrying; without
  #              an explicit retry count, it replaces config.max_retries
  # retry_queue:: queue the job's retries run on (default: its own)
  # dead::       false to discard instead of moving to the dead set
  # backtrace::  true or a number of lines to keep on failures
  # tags::       array of strings shown and searchable in the web UI
  # expires_in:: seconds after enqueue that the job becomes worthless
  # unique_for:: seconds to suppress duplicate pushes (same class+args)
  # unique_until:: :start or :success (default) - when the lock is released
  # debounce::   seconds; later pushes with the same args replace earlier ones
  # encrypt::    true to encrypt arguments at rest
  # timeout::    seconds the job may run before a Robin::Job::Timeout is raised
  # log_level::  level of the job's start/done/fail lines (default :info)
  # logging::    false to leave those lines out
  # profile::    true or a label to profile the run (see Robin::Profiler)
  module Job
    # Raised inside a job that runs past its +timeout+. Not a
    # StandardError, so a job's own `rescue => e` can't swallow it and run
    # on. Like any Timeout.timeout, it can strike anywhere: inside an
    # ensure block, or halfway through talking to a database, leaving
    # connections or state half-updated. Prefer timeouts on the slow
    # operations themselves, and treat this as a last resort.
    class Timeout < Exception; end # rubocop:disable Lint/InheritException

    @inclusion_checks = []

    class << self
      # Callables run with each class about to include Robin::Job; one
      # raises to reject the class, which is then left untouched.
      # Integrations use it: the Rails integration refuses ActiveJob classes.
      attr_reader :inclusion_checks
    end

    def self.append_features(base)
      inclusion_checks.each { |check| check.call(base) }
      super
      base.extend(ClassMethods)
    end

    # Option hashes use string keys, and symbol values become strings: the
    # same shape the payload has after its JSON round trip.
    def self.stringify(hash)
      hash.map { |k, v| [k.to_s, v.instance_of?(Symbol) ? v.to_s : v] }.to_h
    end

    attr_accessor :jid, :payload, :interrupt_requested

    def logger
      Robin.logger
    end

    def queue
      payload && payload["queue"]
    end

    def batch
      bid && Batch.new(bid)
    end

    def bid
      payload && payload["bid"]
    end

    # How many times this job has failed before.
    def failures
      count = payload && payload["retry_count"]
      count ? Integer(count) + 1 : 0
    end

    # The capsule running the job (its name, queues and concurrency), or
    # nil when it isn't run by a server's worker (perform_inline, tests).
    def capsule = Capsule.current

    # True once someone called Robin.cancel!(jid), or cancelled the job's
    # batch. Long jobs should check this periodically and return early.
    def cancelled?
      Cancellation.cancelled?(jid, bid: bid)
    end

    # Report progress (0-100, or nil when the job can't tell) with an
    # optional message; shown live in the web UI's Busy page.
    def progress!(percent, message = nil, **meta)
      Progress.report(jid, percent, message, meta)
    end

    # True while the server is shutting down; iterable jobs use this to
    # checkpoint and stop between iterations.
    def interrupted?
      !!@interrupt_requested
    end

    module ClassMethods
      RESERVED = %w[class args jid created_at enqueued_at at bid].freeze

      def robin_options(opts = nil)
        # @type ivar @robin_options: job_hash
        if opts
          @robin_options = robin_options.merge(Job.stringify(opts))
          validate_options!(@robin_options)
        end
        @robin_options || (superclass.respond_to?(:robin_options) ? superclass.robin_options : DEFAULT_OPTIONS)
      end

      # Custom retry delay: the block receives (count, exception, payload)
      # and returns seconds, :discard, :kill, or nil for the default.
      def robin_retry_in(&block)
        @robin_retry_in = block
      end

      def robin_retry_in_block
        @robin_retry_in || (superclass.robin_retry_in_block if superclass.respond_to?(:robin_retry_in_block))
      end

      # Called when a job runs out of retries, with (payload, exception).
      def robin_retries_exhausted(&block)
        @robin_retries_exhausted = block
      end

      def robin_retries_exhausted_block
        @robin_retries_exhausted || (superclass.robin_retries_exhausted_block if superclass.respond_to?(:robin_retries_exhausted_block))
      end

      def set(options)
        Setter.new(self, options)
      end

      def perform_async(*)
        Setter.new(self, {}).perform_async(*)
      end

      def perform_in(interval, *)
        Setter.new(self, {}).perform_in(interval, *)
      end

      def perform_at(time, *)
        Setter.new(self, {}).perform_at(time, *)
      end

      def perform_bulk(args_list, **)
        Setter.new(self, {}).perform_bulk(args_list, **)
      end

      # Runs the job immediately in the current thread, through the same
      # argument round-trip (JSON) a real job would take.
      def perform_inline(*)
        Setter.new(self, {}).perform_inline(*)
      end

      def client_push(item)
        Client.new(config: robin_config).push(item)
      end

      def robin_config
        Robin.config
      end

      private

      def validate_options!(opts)
        bad = opts.keys & RESERVED
        raise ArgumentError, "reserved robin_options: #{bad.join(", ")}" unless bad.empty?
      end
    end

    DEFAULT_OPTIONS = {"queue" => "default", "retry" => true}.freeze
    BULK_BATCH_SIZE = 1_000

    # Holds per-push overrides: MyJob.set(queue: "critical", wait: 30).perform_async
    #
    # +pool:+ pushes to another Redis (see Client.via):
    #   MyJob.set(pool: SHARDS.sample).perform_async(1)
    class Setter
      def initialize(klass, options)
        @klass = klass
        @options = {}
        set(options)
      end

      def set(options)
        options = Job.stringify(options)
        @pool = options.delete("pool") if options.key?("pool")
        @options.merge!(options)
        self
      end

      def perform_async(*args)
        if (wait = @options.delete("wait"))
          return perform_in(wait, *args)
        end
        if (wait_until = @options.delete("wait_until"))
          return perform_at(wait_until, *args)
        end
        if @options.delete("sync")
          return perform_inline(*args)
        end

        via_pool { @klass.client_push(item(args)) }
      end

      # The client turns +interval+ (seconds, or a time) into a timestamp;
      # times in the past enqueue the job right away.
      def perform_in(interval, *args)
        via_pool { @klass.client_push(item(args).merge({"at" => interval})) }
      end
      alias_method :perform_at, :perform_in

      # +spread_interval+ (seconds) spreads the jobs evenly over that long,
      # across every slice of +batch_size+.
      def perform_bulk(args_list, batch_size: BULK_BATCH_SIZE, spread_interval: nil)
        client = Client.new(config: @klass.robin_config, pool: @pool)
        ats = Client.spread(args_list.size, spread_interval) if spread_interval
        args_list.each_slice(batch_size).with_index.flat_map do |slice, n|
          bulk = item(nil).merge({"args" => slice})
          bulk["at"] = ats[n * batch_size, batch_size] if ats
          client.push_bulk(bulk)
        end
      end

      def perform_inline(*args)
        payload = Client.new(config: @klass.robin_config).normalize(item(args))
        payload = Robin.load_json(Robin.dump_json(payload))
        job = @klass.new
        job.jid = payload.fetch("jid")
        job.payload = payload
        job.perform(*payload.fetch("args"))
      end

      private

      def via_pool(&)
        @pool ? Client.via(@pool, &) : yield
      end

      # The client merges in the class's robin_options underneath these.
      def item(args)
        @options.merge({"class" => @klass, "args" => args})
      end
    end
  end
end
