# frozen_string_literal: true

require "digest/sha1"

module Robin
  # Periodic (cron) jobs.
  #
  #   Robin.configure_server do |config|
  #     config.periodic do |cron|
  #       cron.register "*/5 * * * *", "CleanupJob"
  #       cron.register "0 3 * * *", "NightlyReport", queue: "low", args: ["daily"],
  #         tz: "America/Chicago", description: "Email the nightly report"
  #     end
  #   end
  #
  # Every server knows the schedule, but only the cluster leader enqueues.
  # Each tick is claimed with an atomic SET NX, so a tick runs exactly once
  # even while leadership changes hands; after a failover, the most recent
  # missed tick (only) is caught up.
  #
  # Storage:
  #   robin:periodic          hash  id => definition JSON (the registry)
  #   robin:periodic:armed    hash  id => ms when first registered
  #   robin:periodic:paused   set   paused ids
  #   robin:periodic:<id>:h   list  recent runs, newest first
  #   robin:periodic:<id>:t:<ms> claim key per tick
  module Periodic
    HISTORY = 100
    MAX_SLEEP = 5
    CLAIM_TTL = 7 * 86_400

    # Claims the ticks due now, of entries neither paused nor registered
    # after their tick, each with an atomic SET NX. Returns, for each, 1
    # (won), 0 (lost) or -1 (skipped).
    #
    # KEYS: armed hash, paused set
    # ARGV: claim key prefix ("<prefix>periodic:"), then per tick its
    # entry's id, due time (ms) and claim TTL (seconds)
    CLAIM = Redis::Script.new(<<~LUA)
      local results = {}
      for i = 2, #ARGV, 3 do
        local id, due = ARGV[i], tonumber(ARGV[i + 1])
        local result = -1
        if redis.call('SISMEMBER', KEYS[2], id) == 0 and due >= tonumber(redis.call('HGET', KEYS[1], id) or '0') then
          result = redis.call('SET', ARGV[1] .. id .. ':t:' .. ARGV[i + 1], '1', 'NX', 'EX', ARGV[i + 2]) and 1 or 0
        end
        results[#results + 1] = result
      end
      return results
    LUA

    # Raised by Periodic.verify! with every problem it found.
    class Invalid < Robin::Error; end

    # Collects registrations from config.periodic blocks.
    class Registry
      attr_reader :entries

      # With a +problems+ array, a bad registration is noted there instead
      # of raising, so every one can be reported.
      def initialize(problems = nil)
        @entries = {}
        @problems = problems
      end

      # Returns the entry's id: a digest of its schedule, class, queue,
      # arguments and zone, so it stays the same across deploys.
      def register(cron, klass, queue: nil, args: [], tz: nil, description: nil, **options)
        # @type ivar @problems: Array[String]
        begin
          Cron.new(cron, tz: tz) # validate early
        rescue Cron::ParseError => e
          raise unless @problems

          @problems << "#{klass}: #{e}"
          return
        end
        klass = klass.to_s
        queue = queue&.to_s
        id = Digest::SHA1.hexdigest(Robin.dump_json([cron, klass, queue, args, tz]))[0, 12] #: String
        @entries[id] = {"cron" => cron, "class" => klass, "queue" => queue, "args" => args, "tz" => tz,
                        "description" => description, "options" => options.transform_keys(&:to_s)}
        id
      end
    end

    class << self
      # Checks periodic registrations, for an app's test suite. Pass the
      # block given to config.periodic, or a config to check all of its
      # blocks (those registered by configure_server only run in servers):
      #
      #   SCHEDULE = ->(cron) { cron.register "0 3 * * *", "NightlyReport" }
      #   config.periodic(&SCHEDULE)          # the initializer
      #   Robin::Periodic.verify!(&SCHEDULE)  # a test
      #
      # Raises Invalid listing every bad cron expression or time zone,
      # class that doesn't exist or isn't a job, and arguments that JSON
      # would change. Returns the entries otherwise.
      def verify!(config = Robin.config, &block)
        problems = [] #: Array[String]
        registry = Registry.new(problems)
        (block ? [block] : config.periodic_blocks).each { |b| b.call(registry) }
        registry.entries.each_value { |entry| problems.concat(entry_problems(entry)) }
        raise Invalid, "periodic jobs have problems:\n#{problems.map { |p| "  #{p}" }.join("\n")}" unless problems.empty?

        registry.entries
      end

      # Called by Launcher#run when config.periodic blocks exist.
      def attach(launcher)
        config = launcher.config
        registry = Registry.new
        config.periodic_blocks.each { |block| block.call(registry) }
        entries = registry.entries
        return if entries.empty?

        write_registry(config, entries)
        crons = entries.transform_values { |e| Cron.new(e.fetch("cron"), tz: e.fetch("tz")) }
        Thread.new do
          Thread.current.name = "robin.periodic"
          run_loop(launcher, entries, crons)
        end
      end

      # Every periodic job, in two round trips. With +history+ (a count),
      # each also has its job options and up to that many of its latest
      # runs, newest first (see #history).
      def list(config: Robin.config, history: nil)
        defs, armed, paused = config.redis do |c|
          c.pipelined do |p|
            p.call("HGETALL", config.key("periodic"))
            p.call("HGETALL", config.key("periodic", "armed"))
            p.call("SMEMBERS", config.key("periodic", "paused"))
          end
        end #: Array[untyped]
        defs = defs.each_slice(2).to_h
        armed = armed.each_slice(2).to_h
        ids = defs.keys.sort
        runs = config.redis do |c|
          c.pipelined do |p|
            ids.each do |id|
              key = config.key("periodic", id, "h")
              history ? p.call("LRANGE", key, 0, history - 1) : p.call("LINDEX", key, 0)
            end
          end
        end
        ids.zip(runs).map do |id, reply|
          d = Robin.load_json(defs.fetch(id))
          # The latest runs, or the latest run (or nil).
          recent = Array(reply).map { |raw| Robin.load_json(raw) }
          last = recent.first
          cron = parse(d)
          next_time = cron&.next_time
          {"id" => id, "cron" => d.fetch("cron"), "class" => d.fetch("class"), "queue" => d["queue"] || "default",
           "args" => d.fetch("args"), "tz" => d["tz"], "description" => d["description"] || cron&.description || d.fetch("cron"),
           "next_at" => next_time && Integer(next_time) * 1000, "last_at" => last&.fetch("at"), "last_jid" => last&.fetch("jid"),
           "paused" => paused.include?(id), "armed_at" => armed[id]&.to_i} #: listing
            .tap { |job| job.merge!({"options" => d.fetch("options"), "history" => recent}) if history }
        end
      end

      def history(id, config: Robin.config, limit: 25)
        raw = config.redis { |c| c.call("LRANGE", config.key("periodic", id, "h"), 0, limit - 1) }
        raw.map { |r| Robin.load_json(r) }
      end

      # Enqueues the job right away (outside its schedule). Returns the jid.
      def enqueue_now(id, config: Robin.config)
        raw = config.redis { |c| c.call("HGET", config.key("periodic"), id) }
        raise ArgumentError, "no periodic job #{id.inspect}" unless raw

        jid = push_job(config, id, Robin.load_json(raw))
        record(config, [[id, Robin.now_ms, jid]], manual: true)
        jid
      end

      def pause!(id, config: Robin.config)
        config.redis { |c| c.call("SADD", config.key("periodic", "paused"), id) }
        true
      end

      def unpause!(id, config: Robin.config)
        config.redis { |c| c.call("SREM", config.key("periodic", "paused"), id) }
        true
      end

      # Checks every entry and enqueues the ones whose latest tick hasn't
      # been claimed yet. Safe to call from several processes at once.
      #
      # +claimed+ remembers, per entry, the latest tick this process tried
      # to claim (won or lost): that tick's claim key outlives the time it
      # stays the latest, so trying again could only fail. Passing the same
      # hash on every call spares those round trips; the claim in Redis
      # still decides who enqueues.
      def tick(config, entries, crons, now = Time.now, claimed = {})
        # The ticks due, minus those tried already.
        dues = entries.each_key.filter_map do |id|
          cron = crons.fetch(id)
          due = cron.match?(now) ? Integer(now) : cron.previous_time(now)&.to_i
          [id, due * 1000] if due
        end - claimed.to_a #: Array[tick]
        return [] if dues.empty?

        won = claim(config, dues, crons, now, claimed)
        pushed = Client.together { won.map { |id, due_ms| [id, due_ms, push_job(config, id, entries.fetch(id))] } } #: Array[[String, Integer, String?]]
        record(config, pushed)
        pushed.map(&:last)
      end

      # Writes +entries+ (Registry#entries) to Redis as the periodic jobs,
      # arming the new ones from now: what #attach does as a server starts.
      def write_registry(config, entries)
        now = Robin.now_ms
        config.redis do |c|
          c.multi do |tx|
            tx.call("DEL", config.key("periodic"))
            tx.call("HSET", config.key("periodic"), *entries.flat_map { |id, e| [id, Robin.dump_json(e)] })
            entries.each_key { |id| tx.call("HSETNX", config.key("periodic", "armed"), id, now) }
          end
        end
      end

      private

      # Claims the ticks +dues+ ([id, due (ms)] each) of entries not paused
      # or registered after them, in one round trip; returns the ones won.
      # A claim outlives the tick's time as the entry's latest (until its
      # next tick) by CLAIM_TTL, so a tick long ago is never claimed twice.
      def claim(config, dues, crons, now, claimed)
        args = dues.flat_map { |id, due_ms| [id, due_ms, CLAIM_TTL + Integer(crons.fetch(id).next_time(now) || now) - Integer(now)] }
        results = config.redis do |c|
          c.evalsha(CLAIM, [config.key("periodic", "armed"), config.key("periodic", "paused")], ["#{config.key("periodic")}:", *args])
        end
        dues.zip(results).filter_map do |(id, due_ms), result|
          next if result.negative?

          claimed[id] = due_ms
          [id, due_ms] if result == 1
        end
      end

      def run_loop(launcher, entries, crons)
        config = launcher.config
        claimed = {} #: Hash[String, Integer]
        until launcher.stopping?
          begin
            tick(config, entries, crons, Time.now, claimed) if launcher.leader.leader?
          rescue => e
            config.handle_exception(e, {context: "periodic jobs"})
          end
          sleep(seconds_until_next(crons, Time.now))
        end
      end

      # Sleeps until the next tick is due, waking at least every MAX_SLEEP
      # seconds to notice leadership changes and shutdown.
      def seconds_until_next(crons, now)
        soonest = crons.each_value.filter_map { |c| c.next_time(now) }.min
        soonest ? (soonest - now).clamp(0.05, MAX_SLEEP) : MAX_SLEEP
      end

      # A loaded class contributes its robin_options (queue, retry...);
      # otherwise the name is pushed as is.
      # mutant:disable -- `const_get` on Robin::Periodic instead of Object
      # differs only for constants nested in Robin::Periodic, none of which
      # are job classes.
      def entry_problems(entry)
        name = entry.fetch("class")
        args = entry.fetch("args")
        klass = begin
          Object.const_get(name)
        rescue NameError
          nil
        end
        problems = [] #: Array[String]
        if klass.nil?
          problems << "#{name}: no such class"
        elsif !(klass.instance_of?(Class) && (klass.method_defined?(:perform) || klass.respond_to?(:perform_later)))
          problems << "#{name}: not a job class"
        end
        problems << "#{name}: args must be an Array" unless args.instance_of?(Array)
        problems << "#{name}: args #{args.inspect} change in JSON" unless Robin.load_json(Robin.dump_json(args)) == args
        problems
      end

      # mutant:disable -- `const_get` on Robin::Periodic instead of Object
      # differs only for constants nested in Robin::Periodic, none of which
      # are job classes.
      def job_class(name)
        Object.const_get(name)
      rescue NameError
        name
      end

      def push_job(config, id, entry)
        klass = job_class(entry.fetch("class"))
        item = entry.fetch("options").merge({"class" => klass, "args" => entry.fetch("args"), "periodic" => id})
        queue = entry.fetch("queue")
        item["queue"] = queue if queue
        Client.new(config: config).push(item)
      end

      # Adds the pushes of ticks ([id, at (ms), jid] each) to their
      # entries' histories, in one round trip.
      def record(config, pushed, manual: false)
        config.redis do |c|
          c.pipelined do |p|
            pushed.each do |id, at_ms, jid|
              entry = {"at" => at_ms, "jid" => jid} #: Hash[String, untyped]
              entry["manual"] = true if manual
              key = config.key("periodic", id, "h")
              p.call("LPUSH", key, Robin.dump_json(entry))
              p.call("LTRIM", key, 0, HISTORY - 1)
            end
          end
        end
      end

      # nil for definitions this version can't parse.
      def parse(entry)
        Cron.new(entry.fetch("cron"), tz: entry["tz"])
      rescue Cron::ParseError
        nil
      end
    end
  end
end
