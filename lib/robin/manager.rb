# frozen_string_literal: true

module Robin
  # Owns the worker threads of one capsule.
  class Manager
    # Worker deaths less than RESPAWN_WINDOW seconds apart count as a
    # streak; each one in a streak doubles the wait before the replacement
    # starts (1s, 2s, 4s... up to MAX_RESPAWN_DELAY), so a persistent fault
    # can't spin up threads in a hot loop.
    RESPAWN_WINDOW = 60
    MAX_RESPAWN_DELAY = 30

    attr_reader :capsule, :fetcher, :launcher

    def initialize(capsule, launcher)
      @capsule = capsule
      @config = capsule.config
      @launcher = launcher
      @fetcher = Fetcher.new(capsule, launcher.identity)
      @mutex = Mutex.new
      @slots = concurrency # the next new worker's number
      @processors = Array.new(@slots) { |i| Processor.new(self, capsule, @fetcher, i) }
    end

    # How many workers it runs: the capsule's concurrency, until #resize.
    def concurrency = @mutex.synchronize { capsule.concurrency }

    # Runs +count+ workers from now on. New ones start right away (or with
    # the others, before #start); ones no longer needed finish their
    # current job, then stop.
    def resize(count)
      @mutex.synchronize do
        return if @stopping

        active = @processors.reject(&:retired?)
        if count > active.size
          added = Array.new(count - active.size) { Processor.new(self, capsule, @fetcher, (@slots += 1) - 1) }
          @processors.concat(added)
          added.each { |processor| processor.start(0) } if @started
        else
          active.last(active.size - count).each(&:retire)
        end
        capsule.resized(count)
      end
    end

    def start
      @mutex.synchronize do
        @started = true
        @processors.each { |processor| processor.start(0) }
      end
    end

    def processors
      @mutex.synchronize { @processors.dup }
    end

    def quiet
      @stopping = true
      processors.each(&:terminate)
    end

    # Waits for running jobs until +deadline+ (monotonic seconds), then
    # interrupts whatever is still running and waits for it to wind down
    # until +hard_deadline+ (shared by every capsule).
    def stop(deadline, hard_deadline)
      quiet
      sleep 0.05 while processors.any?(&:alive?) && monotonic < deadline
      remaining = processors.select(&:alive?)
      return if remaining.empty?

      @config.logger.warn("interrupting #{remaining.size} job(s) still running after #{@config.timeout}s")
      Events.emit(@config, "jobs.interrupted", count: remaining.size)
      remaining.each(&:kill)
      remaining.each { |p| p.thread&.join([hard_deadline - monotonic, 0].max) }
    end

    def processor_stopped(processor)
      @mutex.synchronize { @processors.delete(processor) }
      @launcher.work_finished_cleanup(processor)
    end

    def processor_died(processor, exception)
      @config.handle_exception(exception, {context: "worker thread died"})
      @launcher.work_finished_cleanup(processor)
      delay = @mutex.synchronize do
        index = @processors.index(processor)
        @processors.delete(processor)
        unless @stopping || processor.retired?
          replacement = Processor.new(self, capsule, @fetcher, index || @processors.size)
          @processors << replacement
          respawn_delay.tap { |d| replacement.start(d) }
        end
      end
      Events.emit(@config, "worker.died", error: exception, delay: delay)
    end

    def work_started(processor, unit)
      @launcher.work_started(processor, unit)
    end

    def work_finished(processor, payload, elapsed_ms, ok)
      @launcher.work_finished(processor, payload, elapsed_ms, ok)
    end

    private

    # Seconds to wait before replacing a dead worker. Called with the
    # mutex held.
    def respawn_delay
      now = monotonic
      @deaths = (@last_death && now - @last_death < RESPAWN_WINDOW) ? @deaths + 1 : 0
      @last_death = now
      return 0 if @deaths.zero?

      delay = [2**(@deaths - 1), MAX_RESPAWN_DELAY].min #: Integer
      @config.logger.warn("worker thread died #{@deaths + 1} times in a row; restarting it in #{delay}s")
      delay
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
