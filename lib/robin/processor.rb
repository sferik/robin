# frozen_string_literal: true

require "timeout"

module Robin
  # A worker thread: fetch a job, run it through middleware, record the
  # outcome, repeat.
  class Processor
    # Seconds between fetch attempts while fetching fails (Redis is down,
    # failing over, loading, out of memory...): doubles from 0.2s up to 5s.
    MIN_BACKOFF = 0.1
    MAX_BACKOFF = 5

    attr_reader :capsule, :thread, :job

    # The in-flight key of the last finished job, until its
    # acknowledgement goes out with the next fetch (see Fetcher#fetch).
    attr_reader :unacked

    # [queue, raw payload, started at (ms), in-flight key] of the running
    # job, or nil; kept up to date by the launcher.
    attr_accessor :work

    # When (monotonic seconds) it last finished a job, or nil, and how
    # many it has finished; kept up to date by the launcher.
    attr_accessor :finished_at, :finished

    def initialize(manager, capsule, fetcher, slot)
      @manager = manager
      @capsule = capsule
      @config = capsule.config
      @fetcher = fetcher
      @slot = slot
      @retrier = Retrier.new(@config)
      @job_logger = JobLogger.new(@config)
      @wrapper = @config.job_wrapper
      @failures = 0
      @backoff = MIN_BACKOFF
      @retired = false
      @finished = 0
    end

    # Starts the worker thread, after +delay+ seconds.
    def start(delay)
      @thread = Thread.new do
        Thread.current.name = "robin.#{capsule.name}.#{@slot}"
        Thread.current.report_on_exception = false
        Thread.current[:robin_capsule] = capsule
        Events.emit(@config, "worker.started", capsule: capsule.name)
        # Robin::Shutdown (sent by #kill) only interrupts the job itself or
        # a sleep, never fetching, acknowledging or recording a failure.
        Thread.handle_interrupt({Shutdown => :never}) { run(delay) }
      rescue Shutdown
        nil # delivered after the loop ended; nothing left to interrupt
      end
      self
    end

    # Stop after the current job.
    def terminate
      @done = true
      @job&.interrupt_requested = true
    end

    # Stop after the current job, without interrupting it: the capsule
    # needs fewer workers (see Manager#resize).
    def retire
      @retired = true
      @done = true
    end

    def retired? = @retired

    def alive?
      @thread&.alive?
    end

    # Hard stop: interrupt the running job.
    def kill
      @done = true
      @thread&.raise(Shutdown) # a no-op for a thread that already finished
    end

    # Fetches the next job and runs it, on the calling thread, as the
    # worker thread does each time round (its acknowledgement goes out
    # with the next fetch, as there); what a benchmark measures. Returns
    # whether there was one.
    def work_once
      unit = fetch
      process(unit) if unit
      !unit.nil?
    end

    private

    def run(delay)
      interruptible { sleep(delay) } if delay.positive?
      until @done
        unit = fetch
        next unless unit

        # Quieted while blocked waiting for work: hand the job back.
        @done ? unit.requeue : process(unit)
      end
    rescue Shutdown
      nil
    rescue Exception => e # rubocop:disable Lint/RescueException
      died = e
    ensure
      acknowledge_unacked
      release_fetched if @done
      died ? @manager.processor_died(self, died) : @manager.processor_stopped(self)
    end

    # The next job, or nil. A failed fetch is reported (the first failure
    # of an outage, then every 30th) and followed by a backoff sleep, so a
    # Redis outage or error state never kills or spins the worker.
    def fetch
      ack = @unacked
      @unacked = nil
      unit = @fetcher.fetch(@slot, ack: ack)
      if (started = @outage_started)
        @config.logger.info(format("Redis is back after %.1fs", monotonic - started))
        @outage_started = nil
        @failures = 0
        @backoff = MIN_BACKOFF
      end
      unit
    rescue => e
      @outage_started ||= monotonic
      @failures += 1
      @config.handle_exception(e, {context: "fetch"}) if @failures == 1 || (@failures % 30).zero?
      @backoff = [@backoff * 2, MAX_BACKOFF].min
      interruptible { sleep @backoff } unless @done
      nil
    end

    def process(unit)
      payload = begin
        Robin.remember_raw(Robin.load_json(unit.raw), unit.raw)
      rescue JSON::ParserError => e
        @config.handle_exception(e, {context: "invalid JSON job payload", queue: unit.queue, raw: unit.raw[0, 200]})
        DeadSet.new(config: @config).kill(unit.raw, ack: unit)
        return
      end

      if Cancellation.skip?(@config, payload["jid"], payload["bid"])
        @config.logger.info { "skipping cancelled job #{payload["class"]} jid=#{payload.fetch("jid")}" }
        Events.emit(@config, "job.skipped", job: payload, reason: "cancelled")
        Batch.job_succeeded(@config, payload.fetch("bid"), payload.fetch("jid")) if payload["bid"]
        complete(unit, payload)
        return
      end

      @manager.work_started(self, unit)
      start = monotonic
      ok = false
      job_class = nil
      begin
        job_class = constantize(payload["class"])
        execute(job_class, payload, unit)
        ok = true
        complete(unit, payload)
      rescue Robin::Discard => e
        @config.logger.info { "discarded #{payload.fetch("class")} jid=#{payload["jid"]}: #{Retrier.message_of(e)}" }
        Events.emit(@config, "job.discarded", job: payload, error: e)
        ok = true
        complete(unit, payload)
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise if e.is_a?(SystemExit) || e.is_a?(NoMemoryError)
        # Interrupted by a shutdown (directly, or a job turned the interrupt
        # into its own error): leave the job in flight for the manager to
        # requeue.
        raise Shutdown if Robin.shutdown?(e)

        handle_failure(unit, payload, job_class, e)
        # Errors a job may raise (and its timeout) are recorded; anything
        # more severe (e.g. a signal) is recorded and then takes the worker
        # down with it.
        raise unless e.is_a?(StandardError) || e.is_a?(ScriptError) || e.is_a?(Job::Timeout)
      ensure
        elapsed_ms = ((monotonic - start) * 1000).round(1)
        @manager.work_finished(self, payload, elapsed_ms, ok)
      end
    end

    # Acknowledges a finished job: with the next fetch, which saves a
    # round trip. One that was recovered from a crashed process also has
    # its poison-pill counter cleared, so it's acknowledged right away, in
    # the same round trip as that.
    def complete(unit, payload)
      return @unacked = unit.key unless payload.key?("recovered")

      @config.redis do |conn|
        conn.pipelined do |p|
          unit.acknowledge(p)
          p.call("DEL", @config.key("orphan", payload.fetch("jid")))
        end
      end
    end

    # A stopping (or dying) worker won't fetch again, so its last finished
    # job is acknowledged on its own. If that fails, the job stays in
    # flight and is put back later (run again: at least once).
    def acknowledge_unacked
      unacked = @unacked or return

      @config.redis { |conn| @fetcher.acknowledge(conn, [unacked]) }
      @unacked = nil
    rescue => e
      @config.handle_exception(e, {context: "acknowledging a finished job"})
    end

    # A stopping worker hands back the jobs its capsule fetched for other
    # workers (they're stopping too), so they run elsewhere instead of
    # waiting for this process to stop. A job fetched afterwards by a
    # worker still finishing up is handed back when that one stops.
    def release_fetched
      @fetcher.release
    rescue => e
      @config.handle_exception(e, {context: "handing back fetched jobs"})
    end

    def execute(job_class, payload, unit)
      # @type ivar @batch_failure: Batch::HeldFailure
      job = job_class.new
      job.jid = payload["jid"] if job.respond_to?(:jid=)
      job.payload = payload if job.respond_to?(:payload=)
      @job = job
      run_job = lambda do
        @job_logger.call(payload) do
          @config.server_middleware.invoke(job, payload, unit.queue) do
            perform(job, payload)
          end
        end
      end
      return wrapped(payload, run_job) unless payload.key?("bid")

      # A batch job's failure is recorded with its retry (see
      # #handle_failure), or else on the way out, as its middleware would.
      @batch_failure = Batch::HeldFailure.new(payload)
      Batch.holding_failure(@batch_failure) { wrapped(payload, run_job) }
      record_batch_failure
    rescue Exception => e # rubocop:disable Lint/RescueException
      record_batch_failure unless retried?(e)
      raise
    ensure
      @job = nil
    end

    def wrapped(payload, run_job) = (wrapper = @wrapper) ? wrapper.call(payload, &run_job) : run_job.call

    # Does #process hand +exception+ to the retrier?
    def retried?(exception)
      !(exception.is_a?(Discard) || exception.is_a?(SystemExit) || exception.is_a?(NoMemoryError) || Robin.shutdown?(exception))
    end

    # The batch failure the retrier didn't take: the job's error was
    # swallowed, or turned into a discard or a shutdown, by an outer
    # middleware.
    def record_batch_failure
      held = take_batch_failure
      Batch.job_failed(@config, held.payload.fetch("bid"), held.payload.fetch("jid"), held.info) if held
    end

    # The held batch failure, if the job's batch middleware recorded one.
    def take_batch_failure
      held = @batch_failure
      @batch_failure = nil
      held if held&.info
    end

    def perform(job, payload)
      args = payload["args"]
      interruptible do
        if (limit = payload["timeout"])
          Timeout.timeout(limit.to_f, Job::Timeout) { job.perform(*args) }
        else
          job.perform(*args)
        end
      end
    end

    # Lets a pending or later Robin::Shutdown interrupt the block.
    def interruptible(&)
      Thread.handle_interrupt({Shutdown => :immediate}, &)
    end

    def handle_failure(unit, payload, job_class, exception)
      batch_failure = take_batch_failure&.info
      # In the job's logging context, like the job's own log lines.
      Context.with(JobLogger.context_for(payload)) do
        @config.handle_exception(exception, {context: "job raised", job: payload, queue: unit.queue})
      end
      @retrier.handle(unit, payload, job_class || Object, exception, batch_failure: batch_failure)
    rescue => e
      # Couldn't record the failure (e.g. Redis down). The job stays in
      # flight and will be put back later.
      @config.handle_exception(e, {context: "recording job failure", job: payload})
    end

    def constantize(name)
      Object.const_get(name)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
