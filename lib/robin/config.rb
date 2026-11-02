# frozen_string_literal: true

module Robin
  # A capsule is a named group of worker threads with its own queues and
  # concurrency. Every config has a "default" capsule; add more to isolate
  # work, e.g. a single-threaded capsule for jobs that must run serially.
  class Capsule
    attr_reader :name, :config, :weights

    # The capsule whose worker is running this thread's code (a job, say),
    # or nil outside a server's workers (perform_inline, a console).
    def self.current = Thread.current[:robin_capsule]

    def initialize(name, config)
      @name = name
      @config = config
      # A box, so a running capsule (frozen; see Config#freeze_capsules!)
      # can still be resized.
      @workers = {count: 5}
      self.queues = "default"
    end

    # How many workers the capsule runs: as configured, and once it runs,
    # as Launcher#resize last set it.
    def concurrency = @workers.fetch(:count)

    def concurrency=(count)
      raise FrozenError.new("can't modify frozen #{self.class}: #{inspect}", receiver: self) if frozen?

      @workers[:count] = count
    end

    # A running capsule's new worker count (see Manager#resize).
    def resized(count)
      @workers[:count] = count
    end

    # Accepts plain names ("critical"), weighted names ("critical,3" or
    # ["critical", 3]). With no weights the order is strict priority; with
    # weights a queue is checked first proportionally to its weight.
    def queues=(list)
      @weights = {}
      Array(list).each do |entry|
        name, weight = entry.instance_of?(Array) ? entry : entry.to_s.split(",", 2)
        name = name.to_s.strip
        raise ArgumentError, "queue #{name.inspect} is listed twice; give it one weight instead" if @weights.key?(name)

        # (Steep loses track of weight's type through Array(list).)
        @weights[name] = Integer(weight || 0) # steep:ignore ArgumentTypeMismatch
      end
      @strict = @weights.values.all?(&:zero?)
      @expanded = @weights.flat_map { |q, w| [q] * [w, 1].max }
    end

    def queues
      @weights.keys
    end

    def strict?
      @strict
    end

    # Queue names in the order they should be checked for the next fetch.
    def queue_order
      return queues if @strict

      @expanded.shuffle.uniq
    end

    def freeze
      @weights.freeze
      super
    end
  end

  class Config
    # Logs the error, its context and the top of its backtrace as one
    # entry, so they stay together in a combined log stream.
    DEFAULT_ERROR_HANDLER = lambda do |ex, context, config|
      config.logger.warn do
        ["#{ex.class}: #{ex.message}", (Robin.dump_json(context) unless context.empty?), *ex.backtrace&.first(20)]
          .compact.join("\n")
      end
    end

    # Robin's connections name themselves (CLIENT SETNAME), so they're easy
    # to tell apart in CLIENT LIST. A +name:+ in the Redis options wins.
    CONNECTION_DEFAULTS = {name: "robin"}.freeze

    # Whether servers warm up the JIT by default (see #jit_warmup): off
    # CRuby.
    JIT_WARMUP = !RUBY_ENGINE.eql?("ruby")

    LIFECYCLE_EVENTS = %i[startup quiet shutdown leader follower heartbeat exit fork].freeze

    attr_accessor :timeout, :poll_interval, :max_retries, :dead_max_jobs, :dead_timeout,
      :strict_args, :key_prefix, :tag, :labels, :environment,
      :heartbeat_interval, :process_ttl, :max_recoveries, :backtrace_lines,
      :encryption_keys, :max_rate_limit_retries, :statsd, :memory_limit_mb,
      :metrics_retention_days, :reliable_push, :shutdown_requeue, :job_wrapper,
      :health_bind

    # How long to wait before running a job again that hit a rate limit:
    # a callable taking (count, error, payload), where count is how many
    # times the job has hit a limit and error the Robin::Limiter::OverLimit,
    # returning seconds (or nil for the default backoff). A limiter's own
    # +backoff:+ comes first.
    attr_accessor :rate_limit_backoff

    # The class of the batch status batch callbacks get (default
    # Robin::Batch::Status): a subclass, taking (bid, config:) and
    # answering exists?, may add methods of its own.
    attr_writer :batch_status_class

    def batch_status_class = @batch_status_class || Batch::Status

    # Whether this process may become the cluster's leader (default true).
    # Servers that shouldn't run the leader's duties (periodic jobs, crash
    # recovery) set it false.
    attr_accessor :leader_candidate

    # Callables run with each job recovered from a crashed process: its
    # payload, and whether it was a poison pill moved to the dead set
    # (see max_recoveries) rather than put back on its queue.
    attr_reader :recovery_handlers

    # Callables run with each of Robin's events, such as "job.expired" or
    # "redis.slow": the event's name and a Hash about it. Robin::Events
    # lists them.
    attr_reader :event_handlers

    # Whether a server measures GVL contention (see Robin::GVL; default
    # true). Where it can (with the C extension), each heartbeat
    # records it in the process's record, for the dashboard.
    attr_accessor :gvl_monitoring

    # Replaces the retry backoff: a callable (failures, exception, payload,
    # custom) returning the seconds before a failed job's retry, where
    # failures counts from 1 and custom is the job class's robin_retry_in
    # answer in seconds (or nil). Robin adds no jitter to what it returns.
    # nil (the default) is Robin's own backoff.
    attr_accessor :retry_backoff

    # Whether a standalone server collects its garbage once it has gone
    # idle: false (the default), or the fewest jobs that must have
    # finished since the last collection (true is 1). Once no job is
    # running and none has finished for a second, the next heartbeat runs
    # a full GC, so the next burst of jobs doesn't pay for the last one's
    # garbage. A full GC stops every thread of the process while it runs
    # (tens of milliseconds for a large heap; on JRuby, the whole JVM), a
    # job that comes meanwhile waits for it, and it costs CPU every time
    # the process goes quiet, which for bursty work may be every few
    # seconds. Embedded servers never do, as they share their process
    # with the app.
    attr_reader :idle_gc

    def idle_gc=(least)
      least = 1 if least == true
      if least && !(least.instance_of?(Integer) && least >= 1)
        raise ArgumentError, "idle_gc must be true, false or a number of jobs (at least 1), not #{least.inspect}"
      end

      @idle_gc = least || false
    end

    # Whether a server warms up the JIT before it starts its workers (see
    # Robin::Warmup; default false on CRuby, where YJIT warms up quickly
    # anyway, and true elsewhere: on JRuby it takes about a second and a
    # half).
    attr_accessor :jit_warmup

    # Seconds an idle worker blocks waiting for a job (default 2). Longer
    # means fewer idle round trips; shorter means idle workers notice a
    # shutdown sooner, and (with more queues than workers) a job waits less
    # in a queue no worker is blocked on.
    attr_accessor :fetch_timeout

    # The most jobs one fetch takes from Redis (default 10): a worker
    # fetching takes one for every worker of its capsule waiting for one,
    # up to this, in a single round trip. 1 fetches one job at a time.
    attr_reader :fetch_batch

    def fetch_batch=(count)
      count = Integer(count)
      raise ArgumentError, "fetch_batch must be at least 1, not #{count}" if count < 1

      @fetch_batch = count
    end

    # Seconds an iterable job runs before it checkpoints and requeues
    # itself so other jobs get a turn (nil, the default: no limit). A job's
    # max_iteration_runtime robin_option overrides it.
    attr_accessor :max_iteration_runtime

    # Trims the backtraces stored with failed jobs, e.g. dropping gem
    # frames: called with the backtrace (an array of lines), returns the
    # lines to keep. The Rails integration uses Rails.backtrace_cleaner.
    #
    #   config.backtrace_cleaner = ->(lines) { lines.reject { |l| l.include?("/gems/") } }
    attr_accessor :backtrace_cleaner

    # How long the jid index remembers a job's queue when it's just true.
    JID_INDEX_TTL = 7 * 86_400

    # Seconds the queue each pushed job went to is remembered (true means
    # a week; nil, the default, turns it off), so finding a job by jid
    # (Robin::JobLocator, the web UI) searches that queue first instead of
    # every queue. Costs a small key per job.
    attr_reader :jid_index

    def jid_index=(value)
      @jid_index = value.equal?(true) ? JID_INDEX_TTL : value && Integer(value)
    end

    # The port of a server's health check endpoint (see Robin::HealthServer);
    # nil (the default, unless ROBIN_HEALTH_PORT is set) means none.
    attr_reader :health_port

    def health_port=(port)
      @health_port = port && Integer(port)
    end

    # A callable that may defer delivering pushed jobs, e.g. until a
    # database transaction commits (the Rails integration uses it for
    # Active Record). It receives the normalized payloads and a block that
    # delivers them, and returns truthy when it took over delivery
    # (calling the block later, or right away); falsy means "deliver now".
    # Jobs pushed inside a batch are never deferred.
    #
    #   config.push_deferrer = lambda do |_payloads, &deliver|
    #     next false unless MyDB.in_transaction?
    #     MyDB.after_commit(&deliver)
    #     true
    #   end
    attr_accessor :push_deferrer

    attr_writer :logger, :redis_pool
    attr_reader :capsules, :error_handlers, :death_handlers, :lifecycle, :periodic_blocks

    def initialize
      @redis_options = {}
      @capsules = {}
      @timeout = 25
      @poll_interval = 5
      @max_retries = 20
      @dead_max_jobs = 10_000
      @dead_timeout = 180 * 86_400
      @strict_args = :raise
      @key_prefix = "robin:"
      @labels = []
      @environment = ENV["APP_ENV"] || ENV["RACK_ENV"] || "development"
      @heartbeat_interval = 5
      @fetch_timeout = 2
      @fetch_batch = 10
      @process_ttl = 60
      @max_recoveries = 3
      @backtrace_lines = 30
      @max_rate_limit_retries = 20
      @metrics_retention_days = 90
      @reliable_push = false
      @shutdown_requeue = true
      @gvl_monitoring = true
      @idle_gc = false
      @jit_warmup = JIT_WARMUP
      self.health_port = ENV["ROBIN_HEALTH_PORT"]
      @health_bind = "0.0.0.0"
      @error_handlers = [DEFAULT_ERROR_HANDLER]
      @death_handlers = []
      @recovery_handlers = []
      @event_handlers = []
      @leader_candidate = true
      @lifecycle = LIFECYCLE_EVENTS.to_h { |e| [e, []] }
      @periodic_blocks = []
      @client_chain = Middleware::Chain.new(self)
      @server_chain = Middleware::Chain.new(self)
      @capsules["default"] = Capsule.new("default", self)
      install_default_middleware
    end

    # Built-in middleware powering per-job options (unique_for, debounce,
    # encrypt, expires_in, batches, rate limits, profile). Each is a no-op for jobs
    # that don't use its option.
    def install_default_middleware
      @client_chain.add(Unique::ClientMiddleware)
      @client_chain.add(Debounce::ClientMiddleware)
      @client_chain.add(Batch::ClientMiddleware)
      @client_chain.add(Encryption::ClientMiddleware) # last: sees plaintext args
      @server_chain.add(Encryption::ServerMiddleware) # first: decrypts for everyone
      @server_chain.add(Expiry::ServerMiddleware)
      @server_chain.add(Limiter::ServerMiddleware)
      @server_chain.add(Unique::ServerMiddleware)
      @server_chain.add(Debounce::ServerMiddleware)
      @server_chain.add(Batch::ServerMiddleware)
      @server_chain.add(Profiler::ServerMiddleware) # last: profiles just the job
    end

    def default_capsule
      @capsules.fetch("default")
    end

    def concurrency = default_capsule.concurrency

    def concurrency=(n)
      default_capsule.concurrency = n
    end

    def queues = default_capsule.queues

    def queues=(list)
      default_capsule.queues = list
    end

    def capsule(name)
      cap = (@capsules[name.to_s] ||= Capsule.new(name.to_s, self))
      yield cap if block_given?
      cap
    end

    def total_concurrency
      @capsules.values.sum(&:concurrency)
    end

    # Called when a server boots. Capsules (their queues and concurrency)
    # only take effect then, so changing them afterwards raises FrozenError
    # instead of silently doing nothing.
    def freeze_capsules!
      @capsules.each_value(&:freeze)
      @capsules.freeze
    end

    def redis=(options)
      @redis_options = options.transform_keys(&:to_sym)
      @redis_pool&.shutdown
      @redis_pool = nil
      @housekeeping_pool&.shutdown
      @housekeeping_pool = nil
    end

    attr_reader :redis_options

    # The shared connection pool. Servers size it to fit every worker
    # thread plus the housekeeping threads.
    def redis_pool
      @redis_pool ||= begin
        opts = @redis_options.dup
        size = opts.delete(:pool_size) || default_pool_size(total_concurrency)
        pool_timeout = opts.delete(:pool_timeout) || 3.0
        idle_timeout = opts.delete(:idle_timeout)
        Redis::Pool.new(size: size, timeout: pool_timeout, idle_timeout: idle_timeout) { Redis::Connection.new(**CONNECTION_DEFAULTS, **opts) }
      end
    end

    # Makes the shared pool big enough for +workers+ worker threads: one
    # Robin sized grows; one whose size was set (:pool_size) doesn't.
    # Returns whether it's big enough.
    def fit_redis_pool(workers)
      redis_pool.grow(default_pool_size(workers)) unless @redis_options.key?(:pool_size)
      redis_pool.size >= workers + 2
    end

    # A small pool reserved for a server's own housekeeping (heartbeat,
    # leader chores), so busy workers can never starve the heartbeat of a
    # connection and get the process mistaken for dead.
    def housekeeping_pool
      @housekeeping_pool ||= begin
        opts = @redis_options.except(:pool_size, :pool_timeout, :idle_timeout)
        Redis::Pool.new(size: 2) { Redis::Connection.new(**CONNECTION_DEFAULTS, **opts) }
      end
    end

    def redis(&)
      redis_pool.with(&)
    end

    # The keys a job's life runs through, which other tools may read (or
    # share): queues, the schedule, retry and dead sets, the paused set,
    # the process list and the job counters. Their names start with
    # key_prefix; every other key's, with internal_key_prefix.
    SHARED_KEYS = %w[queue queues schedule retry dead paused processes stat].freeze

    # The prefix of Robin's own keys (batches, limiters, metrics, in-flight
    # lists...): key_prefix unless set. With key_prefix "" (keys named
    # like other tools' with no prefix) this keeps Robin's own apart.
    attr_writer :internal_key_prefix

    def internal_key_prefix = @internal_key_prefix || @key_prefix

    def key(*parts)
      "#{SHARED_KEYS.include?(parts.first) ? @key_prefix : internal_key_prefix}#{parts.join(":")}"
    end

    # A running process's record (a hash), named by its identity alone;
    # its running jobs are at "<key>:work" and signals for it at
    # "<key>-signals".
    def process_key(identity) = "#{@key_prefix}#{identity}"

    def logger
      @logger ||= Logger.new($stdout, level: Logger::INFO).tap do |l|
        l.formatter = JobLogger::Formatter.new
      end
    end

    def client_middleware
      yield @client_chain if block_given?
      @client_chain
    end

    def server_middleware
      yield @server_chain if block_given?
      @server_chain
    end

    # Register a lifecycle callback: :startup, :quiet, :shutdown, :leader,
    # :follower, :heartbeat or :exit.
    def on(event, &block)
      raise ArgumentError, "unknown event #{event.inspect}" unless @lifecycle.key?(event)

      @lifecycle.fetch(event) << block
    end

    # Runs the callbacks for +event+. Errors are reported; with +reraise+
    # (used for :startup, so a server never runs half set up) they're also
    # raised.
    def fire_event(event, reverse: false, reraise: false)
      blocks = @lifecycle.fetch(event)
      blocks = blocks.reverse if reverse
      blocks.each do |block|
        block.call
      rescue => e
        handle_exception(e, {context: "lifecycle event #{event}"})
        raise if reraise
      end
    end

    # Register periodic (cron) jobs. The block receives a Robin::Periodic
    # registry; only the elected leader enqueues them.
    #
    #   config.periodic do |cron|
    #     cron.register "*/5 * * * *", "CleanupJob"
    #   end
    def periodic(&block)
      @periodic_blocks << block
    end

    def handle_exception(ex, context = {})
      @error_handlers.each do |handler|
        handler.call(ex, context, self)
      rescue => e
        logger.error "!!! error handler raised: #{e.class}: #{e}"
      end
    end

    def inspect
      "#<Robin::Config concurrency=#{total_concurrency} capsules=#{@capsules.keys} prefix=#{@key_prefix.inspect}>"
    end

    private

    def default_pool_size(workers) = Robin.server? ? workers + 5 : 10
  end
end
