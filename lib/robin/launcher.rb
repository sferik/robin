# frozen_string_literal: true

require "socket"

module Robin
  # Runs a Robin server: worker threads for every capsule, the scheduler,
  # and a heartbeat thread that publishes process state, flushes metrics,
  # takes part in leader election and reacts to remote control signals
  # sent from the web UI.
  class Launcher
    # How long a stopping:<identity> marker outlives the shutdown timeout:
    # long enough for the process's heartbeat to expire and the leader to
    # recover its jobs if it's killed before it finishes stopping.
    STOPPING_MARGIN = 3600

    # Seconds interrupted jobs get to wind down, after the shutdown timeout.
    HARD_SHUTDOWN_GRACE = 3

    # Heartbeat round trips slower than this (microseconds) get a warning.
    SLOW_REDIS_US = 50_000

    # Seconds without a job finishing before an idle process collects its
    # garbage (see Config#idle_gc).
    IDLE_GC_AFTER = 1
    # GVL contention (a percentage) that, kept up for GVL_HIGH_BEATS
    # heartbeats in a row, is worth a warning.
    GVL_HIGH = 50
    GVL_HIGH_BEATS = 3

    attr_reader :config, :identity, :managers, :collector, :leader, :started_at
    attr_accessor :on_stop_request

    def initialize(config, embedded: false)
      @config = config
      @embedded = embedded
      @identity = "#{Robin.hostname}:#{Process.pid}:#{SecureRandom.hex(4)}"
      @collector = Metrics::Collector.new
      @leader = Leader.new(config, @identity)
      @scheduler = Scheduler.new(config)
      @quiet = false
      @done = false
      @last = {}
      @managers = config.capsules.values.map { |cap| Manager.new(cap, self) }
      # Fetchers with acknowledgements left waiting (see #send_acks).
      @acks = Thread::Queue.new
      @managers.each { |m| m.fetcher.acker = @acks }
      @hooks = {leader: [], beat: []}
      @suspects = []
      @gvl = GVL.new
      @gvl_high = 0
      @wake_mutex = Mutex.new
      @wake = ConditionVariable.new
    end

    def quiet? = @quiet

    # How many workers it runs, in every capsule.
    def concurrency = @managers.sum(&:concurrency)

    # Has capsule +name+ run +count+ workers from now on (see
    # Manager#resize), growing the Redis pool to fit them. Returns false,
    # changing nothing, when the process is quiet (its workers are
    # stopping), or when the pool's size was set (:pool_size) and it can't
    # serve them all.
    def resize(count, capsule: "default")
      raise ArgumentError, "a capsule needs a concurrency above 0, not #{count.inspect}" unless count.instance_of?(Integer) && count.positive?

      manager = @managers.find { |m| m.capsule.name == capsule }
      raise ArgumentError, "no capsule named #{capsule.inspect}" unless manager

      if quiet?
        config.logger.warn("not resizing capsule #{capsule.inspect} to #{count}: the process is quiet")
        return false
      end
      before = manager.concurrency
      workers = concurrency - before + count
      unless config.fit_redis_pool(workers)
        config.logger.warn("not resizing capsule #{capsule.inspect} to #{count}: #{workers} workers need a Redis pool of " \
          "#{workers + 2} connections, but :pool_size is #{config.redis_pool.size}")
        return false
      end
      manager.resize(count)
      config.logger.info("capsule #{capsule.inspect} now runs #{count} workers (was #{before})")
      Events.emit(config, "workers.resized", capsule: capsule, from: before, to: count)
      true
    end

    def stopping? = @done

    # Housekeeping hooks run on every heartbeat (:beat) or only on the
    # leader (:leader). Used by cron, batches and other subsystems.
    def every_beat(&block) = @hooks.fetch(:beat) << block

    def every_leader_beat(&block) = @hooks.fetch(:leader) << block

    def run
      @started_at = Robin.now_ms
      check!
      config.freeze_capsules!
      # First, so a port that's taken fails the boot before anything starts.
      start_health_server
      Warmup.run(config) if config.jit_warmup
      Leader.register(config, @leader)
      # Recover before the first heartbeat registers this process's own
      # in-flight set, so recovery can't mistake it for a dead one.
      safely("startup recovery") { Recovery.run(config, pool: config.housekeeping_pool) }
      begin
        # A failing startup hook stops the boot before any work starts.
        config.fire_event(:startup, reraise: true)
      rescue
        Leader.unregister(config)
        @health&.stop
        raise
      end
      Periodic.attach(self) unless config.periodic_blocks.empty?
      @gvl.start if config.gvl_monitoring
      safely("heartbeat") { beat }
      @managers.each(&:start)
      @scheduler.start
      @heartbeat = housekeeping_thread("robin.heartbeat") { beat }
      @chores = housekeeping_thread("robin.leader") { leader_chores }
      @acker = Thread.new { send_acks }
      @acker.name = "robin.acks"
      @acker.priority = 1 # outranks worker threads, like housekeeping
      Systemd.notify("READY=1") unless @embedded
      self
    end

    # Stop fetching new jobs; running jobs finish.
    def quiet
      return if @quiet

      @quiet = true
      config.logger.info("quieting: no new jobs will be started")
      @managers.each(&:quiet)
      config.fire_event(:quiet, reverse: true)
    end

    # Graceful shutdown: quiet, wait up to config.timeout for running jobs,
    # interrupt the rest and put their jobs back on the queue.
    def stop
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + config.timeout
      Systemd.notify("STOPPING=1") unless @embedded
      safely("mark stopping") { mark_stopping }
      quiet
      @done = true
      wake_up # housekeeping threads stop now
      @scheduler.stop
      # Interrupted jobs get one shared grace period to wind down.
      @managers.each { |m| m.stop(deadline, deadline + HARD_SHUTDOWN_GRACE) }
      safely("final metrics flush") { config.redis { |c| @collector.flush(config, c) } }
      if config.shutdown_requeue
        safely("requeue in-flight jobs") do
          config.redis do |conn|
            count = Recovery.drain(config, conn, inflight_key, count: false)
            config.logger.info("pushed #{count} unfinished job(s) back to their queues") if count > 0
          end
        end
      end
      safely("unregister") do
        config.redis do |conn|
          @leader.resign(conn)
          conn.pipelined do |p|
            p.call("SREM", config.key("processes"), identity)
            p.call("SREM", config.key("inflights"), inflight_key)
            p.call("DEL", proc_key, "#{proc_key}:work", "#{proc_key}-signals", stopping_key)
          end
        end
      end
      Leader.unregister(config)
      # Let a heartbeat or chore that's already running finish, so it can't
      # re-register this process after it has unregistered.
      @heartbeat&.join(1)
      @chores&.join(1)
      @acks << nil # the workers are done
      @acker&.join(1)
      @health&.stop
      @gvl.stop
      config.fire_event(:shutdown, reverse: true)
      config.logger.info("bye!")
    end

    # This process's health, as served by Robin::HealthServer: healthy
    # while its heartbeat reaches Redis and it isn't shutting down. A quiet
    # process is still healthy (it's finishing its jobs).
    def health
      age = @beat_at && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @beat_at)
      status = if @done then "stopping"
      elsif age.nil? || age > config.process_ttl then "stale"
      elsif @quiet then "quiet"
      else "ok"
      end
      {"healthy" => %w[ok quiet].include?(status), "status" => status, "identity" => identity,
       "heartbeat_age" => age&.round(3), "busy" => busy, "concurrency" => concurrency}
    end

    def inflight_key = config.key("inflight", identity)

    def proc_key = config.process_key(identity)

    def stopping_key = config.key("stopping", identity)

    # -- worker callbacks ----------------------------------------------------

    # Records what a worker is running, for the heartbeat (and its
    # in-flight key, for the sweep). Only the job's raw payload, exactly
    # as fetched, is kept: the live payload hash is being changed by the
    # job (and holds decrypted arguments).
    # Each worker keeps the job it's running to itself (Processor#work),
    # so starting and finishing jobs share no lock: with real threads
    # (JRuby) a shared one would serialize every worker twice per job.
    def work_started(processor, unit)
      processor.work = [unit.queue, unit.raw, Robin.now_ms, unit.key]
    end

    def work_finished(processor, payload, elapsed_ms, ok)
      processor.work = nil
      processor.finished_at = monotonic
      processor.finished += 1
      klass = Robin.display_class(payload)
      @collector.record(klass, elapsed_ms, ok)
      statsd = config.statsd
      statsd.distribution("jobs.perform_dist", elapsed_ms, tags: {class: klass}) if ok && statsd&.distributions?
    end

    def work_finished_cleanup(processor)
      processor.work = nil
    end

    def busy = running.size

    # [processor, [queue, raw, run_at, in-flight key]] for every job
    # running now.
    def running
      @managers.flat_map(&:processors).filter_map do |processor|
        work = processor.work
        [processor, work] if work
      end
    end

    def process_info
      {
        "identity" => identity, "hostname" => Robin.hostname, "pid" => Process.pid,
        "tag" => config.tag, "labels" => config.labels, "started_at" => @started_at && Robin.epoch_seconds(@started_at),
        "version" => VERSION, "ruby" => RUBY_DESCRIPTION, "env" => config.environment,
        "embedded" => @embedded, "concurrency" => concurrency,
        "queues" => config.capsules.values.flat_map(&:queues).uniq,
        "weights" => config.capsules.values.map(&:weights),
        "capsules" => @managers.to_h do |m|
          c = m.capsule
          [c.name, {"concurrency" => m.concurrency, "mode" => c.strict? ? "strict" : "weighted", "weights" => c.weights}]
        end
      }
    end

    # One heartbeat, in one round trip: publish state, flush metrics, renew
    # leadership, run housekeeping hooks and handle remote signals.
    def beat
      now = Robin.now_ms
      work = running.map do |processor, (queue, raw, run_at)|
        [processor.thread&.name || processor.object_id, work_json(queue, raw, run_at)]
      end
      held = held_keys
      ttl = config.process_ttl
      gvl = @gvl.sample
      candidate = config.leader_candidate
      sweep = due?(60, :sweep)
      config.housekeeping_pool.with do |conn|
        rtt_start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
        at = {} #: Hash[Symbol, Integer]
        metrics = nil #: Metrics::drained?
        replies = begin
          conn.multi do |tx|
            tx.call("EXISTS", proc_key)
            tx.call("SADD", config.key("processes"), identity)
            tx.call("SADD", config.key("inflights"), inflight_key)
            # Recovery unregisters the in-flight keys of a process whose
            # heartbeat lapsed; they're registered again as soon as it's back.
            tx.call("SADD", inflight_key, *held) unless held.empty?
            # The round trip time is the last heartbeat's: this one's is
            # only known once it's back.
            tx.call("HSET", proc_key, "info", Robin.dump_json(process_info), "beat", Robin.epoch_seconds(now),
              "busy", work.size, "concurrency", concurrency, "quiet", @quiet, "rss", rss_kb,
              # (Steep doesn't take splatting nil, which adds no arguments.)
              "leader", @leader.leader? ? "1" : "0", *(["rtt_us", @rtt] if @rtt), *(["gvl", gvl] if gvl)) # steep:ignore ArgumentTypeMismatch
            tx.call("EXPIRE", proc_key, ttl)
            tx.call("DEL", "#{proc_key}:work")
            tx.call("HSET", "#{proc_key}:work", *work.flatten) unless work.empty?
            tx.call("EXPIRE", "#{proc_key}:work", ttl)
            at[:signals] = tx.commands.size
            tx.call("LRANGE", "#{proc_key}-signals", 0, -1)
            tx.call("DEL", "#{proc_key}-signals")
            tx.call(*Cancellation.listing(config))
            tx.call("SMEMBERS", config.key("paused"))
            at[:lease] = tx.commands.size
            @leader.lease(tx) if candidate
            at[:sweep] = tx.commands.size
            tx.call("SMEMBERS", inflight_key) if sweep
            metrics = @collector.queue(config, tx)
          end
        rescue
          @collector.restore(metrics) if metrics
          raise
        end
        # (The transaction went through, so metrics is set.)
        @collector.flushed(config, metrics) # steep:ignore ArgumentTypeMismatch
        warn_about_lapse if @beaten && replies.first.zero?
        @beaten = true
        @beat_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        signals, _, cancelled, paused = replies.drop(at.fetch(:signals)) #: [Array[String], Integer, Array[String], Array[String]]
        @rtt = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond) - rtt_start
        warn_about_slow_redis(@rtt) if @rtt > SLOW_REDIS_US
        check_gvl(gvl) if gvl

        @leader.settle(replies.fetch(at.fetch(:lease))) if candidate
        Cancellation.store(config, cancelled)
        hand_back_stale(conn, paused)
        @hooks.fetch(:beat).each { |h| safely("beat hook") { h.call(conn) } }
        safely("sweep") { sweep_inflight(conn, replies.fetch(at.fetch(:sweep))) } if sweep
        signals.reverse_each { |sig| handle_signal(sig) } # pushed onto the head: oldest last
      end
      check_memory
      unless @embedded
        collect_idle_garbage
        Process.setproctitle(title)
        Systemd.notify("WATCHDOG=1") if Systemd.watchdog?
      end
      config.fire_event(:heartbeat)
    end

    # Runs a full GC once the process has gone idle (see Config#idle_gc):
    # no job running, none finished for IDLE_GC_AFTER seconds, and at
    # least config.idle_gc finished since the last time. Each worker
    # counts its own jobs (Processor#finished), so finishing one takes no
    # lock; the counts at the last collection are kept by worker.
    def collect_idle_garbage
      least = config.idle_gc
      return unless least && running.empty?

      processors = @managers.flat_map(&:processors)
      last = processors.filter_map(&:finished_at).max
      return unless last && monotonic - last >= IDLE_GC_AFTER

      counted = @collected_counts || {}
      return if processors.sum { |p| p.finished - counted.fetch(p, 0) } < least

      collect_garbage
      @collected_counts = processors.to_h { |p| [p, p.finished] }
    end

    def collect_garbage = GC.start

    # Puts back the jobs every capsule fetched for its workers that are
    # from a queue paused since, or that no worker took in time (see
    # Fetcher#stale), in one round trip.
    def hand_back_stale(conn, paused)
      stale = @managers.map { |m| [m.fetcher, m.fetcher.stale(paused)] } #: Array[[Fetcher, Array[Fetcher::UnitOfWork]]]
      stale.reject! { |_fetcher, units| units.empty? }
      return if stale.empty?

      conn.multi { |tx| stale.each { |fetcher, units| fetcher.hand_back(tx, units) } }
      stale.each { |fetcher, units| fetcher.freed(units) }
    end

    # The process title (as ps shows it) of a standalone server.
    def title
      state = if @done then " stopping"
      elsif @quiet then " quiet"
      end
      "robin #{VERSION} #{config.tag} [#{busy} of #{concurrency} busy]#{state}"
    end

    # Remote signals are named like the Unix signals that do the same.
    def handle_signal(signal)
      case signal
      when "TSTP" then quiet
      when "TERM" then request_stop
      when "TTIN" then dump_threads
      # (The match sets $1 and $2.)
      when /\ARESIZE (\d+) (.+)\z/m then safely("resize") { resize(Integer($1, 10), capsule: $2) } # steep:ignore ArgumentTypeMismatch
      else config.logger.warn("ignoring unknown remote signal #{signal.inspect}")
      end
    end

    def request_stop
      if on_stop_request
        on_stop_request.call
      else
        Thread.new { stop }
      end
    end

    def dump_threads
      Thread.list.each do |t|
        config.logger.warn("Thread #{t.name || t.object_id} (#{t.status})")
        config.logger.warn((t.backtrace || ["<no backtrace>"]).join("\n"))
      end
    end

    private

    # {"queue", "run_at" (epoch seconds), "payload" (the job's JSON, as
    # fetched)} as JSON.
    def work_json(queue, raw, run_at)
      Robin.dump_json({"queue" => queue, "payload" => raw, "run_at" => Robin.epoch_seconds(run_at)})
    end

    MINIMUM_REDIS = [6, 2].freeze

    # Refuses settings and servers Robin can't run correctly with, and
    # warns about ones that risk losing data.
    def check!
      config.capsules.each_value do |capsule|
        raise ArgumentError, "capsule #{capsule.name.inspect} needs a concurrency above 0" unless capsule.concurrency.positive?
      end
      raise ArgumentError, "the shutdown timeout must be above 0 seconds" unless config.timeout.positive?
      raise ArgumentError, "the fetch timeout must be above 0 seconds" unless config.fetch_timeout.positive?

      needed = config.total_concurrency + 2
      if config.redis_pool.size < needed
        raise ArgumentError, "the Redis pool has #{config.redis_pool.size} connections but #{config.total_concurrency} " \
          "worker threads need at least #{needed}; raise :pool_size or leave it unset"
      end

      info, conn = config.redis { |c| [c.call("INFO"), c] }
      version = info[/^redis_version:(\S+)/, 1]
      if (version.split(".").map(&:to_i) <=> MINIMUM_REDIS).negative?
        raise ArgumentError, "Robin needs Redis #{MINIMUM_REDIS.join(".")} or later; this server runs #{version}"
      end
      config.logger.info(connected(conn, version))

      policy = info[/^maxmemory_policy:(\S+)/, 1]
      return if policy.nil? || policy == "noeviction"

      config.logger.warn("Redis maxmemory-policy is #{policy}; set it to noeviction, or Redis may evict " \
        "jobs and process heartbeats when memory runs low")
    end

    # Where this process's jobs are, so connecting to the wrong Redis (the
    # default 127.0.0.1:6379, say) is plain to see: the server (never its
    # password) and the key prefixes.
    def connected(conn, version)
      tls = " over TLS" if conn.options.fetch(:ssl)
      own = config.internal_key_prefix
      own = (", Robin's own under #{own.inspect}" unless own == config.key_prefix)
      "Redis #{version} at #{conn.id}#{tls}; keys under #{config.key_prefix.inspect}#{own}"
    end

    # Swarm children listen on the configured port plus their index.
    def start_health_server
      return unless config.health_port

      port = config.health_port + Integer(ENV.fetch("ROBIN_SWARM_INDEX", 0))
      @health = HealthServer.new(self, port: port, bind: config.health_bind)
      config.logger.info("health check listening on #{config.health_bind}:#{@health.port}")
    end

    # Jobs interrupted by this shutdown aren't poison pills, even if the
    # process is killed before it can requeue them itself.
    def mark_stopping
      config.redis { |conn| conn.call("SET", stopping_key, "1", "EX", (config.timeout + STOPPING_MARGIN).ceil) }
    end

    # A thread that runs the block every heartbeat interval until stopping.
    # It outranks worker threads, so busy jobs can't starve it.
    def housekeeping_thread(name)
      Thread.new do
        Thread.current.name = name
        Thread.current.priority = 1
        until @done
          nap(config.heartbeat_interval)
          safely(name.delete_prefix("robin.")) { yield } unless @done
        end
      end
    end

    # Sleeps up to +seconds+, or until #wake_up (called by #stop).
    # mutant:disable -- the lock and the @done check only close a lost-wakeup
    # race (a stop landing between the loop's check and the wait) that tests
    # can't provoke deterministically; test_stop_wakes_sleeping_housekeeping_threads
    # covers the behavior.
    def nap(seconds)
      @wake_mutex.synchronize { @wake.wait(@wake_mutex, seconds) unless @done }
    end

    # mutant:disable -- see #nap
    def wake_up
      @wake_mutex.synchronize { @wake.broadcast }
    end

    # Sends the acknowledgements fetchers leave waiting, ACK_WAIT after
    # they put themselves on @acks (see Fetcher#acker), until a nil comes
    # off it. Only the first failure of a run of them is reported (workers
    # report a Redis outage too); those acknowledgements wait again.
    # mutant:disable -- Thread::Queue#shift is an alias of #pop.
    def send_acks
      failing = false
      loop do
        fetchers = [@acks.pop]
        break unless fetchers.first

        sleep Fetcher::ACK_WAIT
        fetchers << @acks.pop until @acks.empty? # this thread is the only taker
        fetchers.compact.each do |fetcher|
          fetcher.send_acks
          failing = false
        rescue => e
          config.handle_exception(e, {context: "acknowledging jobs"}) unless failing
          failing = true
        end
        break if fetchers.include?(nil)
      end
    end

    # Cluster-wide duties of the leader, on their own thread so slow ones
    # (recovery after a big crash) never delay this process's heartbeat.
    def leader_chores
      return unless @leader.leader?

      config.housekeeping_pool.with do |conn|
        every(60, :sample_queues) { Metrics.sample_queues(config, conn) }
        every(30, :recovery) { Recovery.run(config, pool: config.housekeeping_pool) }
        every(60, :prune) { prune_processes(conn) }
        @hooks.fetch(:leader).each { |h| safely("leader hook") { h.call(conn) } }
      end
    end

    # The heartbeat key had expired: for a while this process looked dead, so
    # the leader may have recovered (and another process re-run) jobs that
    # were still running here.
    # At most every 10 minutes: a slow Redis slows every job down.
    def warn_about_slow_redis(rtt_us)
      every(600, :slow_redis) do
        config.logger.warn(format("Redis round trips take %.1fms; jobs will be slow (is Redis far away, or overloaded?)", rtt_us / 1000.0))
        Events.emit(config, "redis.slow", rtt_us: rtt_us)
      end
    end

    # Contention is reported every heartbeat (StatsD's gvl.contention);
    # contention kept high warns, at most every 10 minutes.
    def check_gvl(percent)
      config.statsd&.gauge("gvl.contention", percent)
      @gvl_high = (percent >= GVL_HIGH) ? @gvl_high + 1 : 0
      return if @gvl_high < GVL_HIGH_BEATS

      every(600, :gvl) do
        config.logger.warn("GVL contention is #{percent}%: threads spend most of their time waiting for each other; " \
          "fewer threads per process (and more processes) would run CPU-heavy jobs faster")
        Events.emit(config, "gvl.contended", percent: percent)
      end
    end

    def warn_about_lapse
      config.logger.warn("heartbeat lapsed (more than #{config.process_ttl}s without one); jobs running here " \
        "may have been recovered and run again elsewhere. Is the process starved of CPU or Redis connections?")
      Events.emit(config, "heartbeat.lapsed")
    end

    # The in-flight keys this process's workers hold: those of running
    # jobs, of finished jobs whose acknowledgement waits for a later
    # fetch, of jobs fetched for a worker that hasn't asked yet, and free
    # ones. Running jobs are read first, so one finishing meanwhile is seen
    # either way.
    def held_keys
      held = running.map { |_processor, work| work.fetch(3) } #: Array[String?]
      held.concat(@managers.flat_map { |m| m.processors.map(&:unacked) + m.fetcher.held })
      held.compact
    end

    # Puts back jobs that sit in this process's in-flight keys without any
    # worker holding them (e.g. one died after the job finished but before
    # acknowledging it, or a round trip failed after filling them), and
    # unregisters keys left empty that way. A key must be unheld, with the
    # same job (or none) in it, on two sweeps in a row, so one that's just
    # being fetched or acknowledged (or was used again since) is never
    # taken.
    # +registered+ are the keys registered for this process, as the
    # heartbeat read them.
    def sweep_inflight(conn, registered)
      unheld = registered - held_keys
      sightings = unheld.zip(conn.pipelined { |p| unheld.each { |key| p.call("LINDEX", key, 0) } })
      orphans = sightings & @suspects
      @suspects = sightings - orphans
      orphans.select! { |key, _raw| @managers.all? { |m| m.fetcher.forget(key) } }
      requeued = conn.pipelined do |p|
        orphans.each do |key, raw|
          # An empty key (raw nil) is only unregistered.
          queue = raw ? Robin.load_json(raw).fetch("queue") : ""
          p.evalsha(Scripts::REQUEUE_ONE, [key, config.key("queue", queue), config.key("queues"), inflight_key], [raw.to_s, queue])
        end
      end.sum
      return unless requeued.positive?

      config.logger.warn("put back #{requeued} orphaned in-flight job(s)")
      config.statsd&.increment("jobs.orphaned", requeued)
      Events.emit(config, "jobs.orphaned", count: requeued)
    end

    def every(seconds, name)
      safely(name.to_s) { yield } if due?(seconds, name)
    end

    # Whether +seconds+ have passed since +name+ was last due (or it never
    # was); it's due again +seconds+ from now if so.
    def due?(seconds, name)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      last = @last[name]
      return false if last && now - last < seconds

      @last[name] = now
    end

    # mutant:disable -- Connection#evalsha splats ARGV, so passing the
    # prefix bare or wrapped in an Array is identical.
    def prune_processes(conn) = conn.evalsha(Scripts::PRUNE, [config.key("processes")], [config.key_prefix])

    def check_memory
      limit = config.memory_limit_mb
      return unless limit && !@done

      rss_mb = rss_kb / 1024
      return if rss_mb < limit

      config.logger.warn("RSS #{rss_mb}MB exceeds memory_limit_mb #{limit}MB; restarting gracefully")
      Events.emit(config, "memory.exceeded", rss_mb: rss_mb, limit_mb: limit)
      request_stop
    end

    def rss_kb
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return @rss if @rss && now - @rss_at < 15

      @rss_at = now
      @rss = if File.readable?("/proc/self/status")
        Integer(File.read("/proc/self/status")[/^VmRSS:\s*(\d+)/, 1])
      else
        Integer(`ps -o rss= -p #{Process.pid}`)
      end
    rescue
      @rss = 0
    end

    def safely(what)
      yield
    rescue => e
      config.handle_exception(e, {context: what})
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
