# frozen_string_literal: true

module Robin
  # Keeps pushes from failing while Redis is briefly unreachable.
  #
  #   Robin.configure { |c| c.reliable_push = true } # or a buffer size
  #
  # When a push fails with a connection error, its jobs are buffered in
  # memory and pushed (in order) once Redis is back: by a background
  # thread retrying with backoff, or by the next successful push. The
  # buffer is bounded (1000 jobs by default); when it's full the oldest
  # jobs are dropped. When the process exits, it tries once more to push
  # what's buffered; jobs it can't push are lost. Dropped and lost jobs are
  # reported to config.error_handlers (as Dropped and Lost errors) and as
  # push.dropped and push.lost events.
  class ReliablePush
    DEFAULT_LIMIT = 1_000
    DRAIN_CHUNK = 100 # jobs per pipelined push while draining
    ERRORS = [Redis::ConnectionError, Redis::Pool::TimeoutError].freeze

    # Jobs dropped because the buffer was full.
    class Dropped < Error; end

    # Jobs still buffered when the process exited.
    class Lost < Error; end

    @instances = {}
    @lock = Mutex.new
    AT_EXIT = ->(reliable_push) { Kernel.at_exit { reliable_push.finish } }
    @exit_hook = AT_EXIT

    class << self
      # Called with each instance the first time it buffers, to have it
      # #finish when the process exits.
      attr_accessor :exit_hook
    end

    # One buffer per config and Redis pool (see Client.via), so buffered
    # jobs go back to the Redis they were meant for.
    def self.for(config, pool = nil)
      @lock.synchronize { @instances[[config.object_id, pool.object_id]] ||= new(config, pool: pool) }
    end

    attr_reader :limit

    def initialize(config, limit: nil, pool: nil)
      @config = config
      @pool = pool
      @limit = limit || (config.reliable_push.instance_of?(Integer) ? config.reliable_push : DEFAULT_LIMIT)
      @buffer = []
      @mutex = Mutex.new
    end

    def size = @mutex.synchronize { @buffer.size }

    # Yields to push +payloads+; buffers them if Redis is unreachable.
    def push(payloads)
      if @buffer.empty?
        begin
          return yield
        rescue *ERRORS => e
          @config.logger.warn("Redis unavailable (#{e}); buffering #{payloads.size} job(s) for later")
          Events.emit(@config, "push.buffered", jobs: payloads, error: e)
        end
      end
      dropped = @mutex.synchronize { append(payloads) }
      # Reported outside the lock: an error handler may push a job itself.
      report_dropped(dropped) unless dropped.empty?
      drain
      nil
    end

    # Pushes buffered jobs, oldest first. Returns true if the buffer is empty.
    def drain
      pushed = 0
      done = @mutex.synchronize do
        loop do
          break true if @buffer.empty?

          chunk = @buffer.first(DRAIN_CHUNK)
          begin
            push_chunk(chunk)
          rescue *ERRORS
            start_retrier
            break false
          end
          @buffer.shift(chunk.size)
          pushed += chunk.size
        end
      end
      report_pushed(pushed) if pushed > 0
      done
    end

    # Run when the process exits: one last try to push what's buffered.
    # Whatever is still buffered after it is lost, and reported.
    def finish
      return if drain

      lost = @mutex.synchronize { @buffer.tap { @buffer = [] } }
      @config.handle_exception(Lost.new("process exiting with #{lost.size} buffered job(s) not pushed: #{describe(lost)}"),
        {context: "reliable push"})
      Events.emit(@config, "push.lost", jobs: lost)
    end

    private

    # Returns the jobs it dropped to stay within the limit.
    def append(payloads)
      unless @hooked
        @hooked = true
        ReliablePush.exit_hook.call(self)
      end
      @buffer.concat(payloads)
      @buffer.shift([@buffer.size - @limit, 0].max)
    end

    def report_dropped(dropped)
      @config.handle_exception(Dropped.new("reliable push buffer full (#{@limit}); dropped #{dropped.size} job(s): #{describe(dropped)}"),
        {context: "reliable push"})
      Events.emit(@config, "push.dropped", jobs: dropped)
    end

    def report_pushed(count)
      @config.logger.info("Redis is reachable again; pushed #{count} buffered job(s)")
      @config.statsd&.increment("jobs.recovered.push", count)
      Events.emit(@config, "push.recovered", count: count)
    end

    def push_chunk(chunk) = Client.new(config: @config, pool: @pool).__send__(:raw_push, chunk)

    def describe(jobs) = jobs.map { |p| "#{p.fetch("class")} jid=#{p.fetch("jid")}" }.join(", ")

    # Must be called with @mutex held.
    def start_retrier
      return if @retrier&.alive?

      @retrier = Thread.new do
        Thread.current.name = "robin.reliable_push"
        delay = 0.5 #: seconds
        loop do
          pause(delay)
          break if drain

          delay = [delay * 2, 30].min
        end
        @retrier = nil
      end
    end

    def pause(seconds) = sleep(seconds)
  end
end
