# frozen_string_literal: true

require "zlib"

module Robin
  # Profiles single job runs with Vernier, a sampling profiler (add
  # `gem "vernier"`; CRuby only), to find out why a job is slow:
  #
  #   ReportJob.set(profile: true).perform_async(42)
  #   ReportJob.set(profile: "big export").perform_async(43) # with a label
  #
  # The profile, in the Firefox Profiler format, is kept in Redis for a
  # week (the newest KEEP of them). The dashboard lists them and opens them
  # in https://profiler.firefox.com; from Ruby:
  #
  #   Robin::Profiler.list             # newest first, without the data
  #   Robin::Profiler.data(jid)        # the profile JSON, or nil
  #
  # A process profiles one job at a time; others asking meanwhile run
  # unprofiled. Failed runs are profiled too.
  module Profiler
    TTL = 7 * 86_400
    KEEP = 100
    MAX_BYTES = 16 * 1024 * 1024 # compressed; bigger profiles are dropped
    LOCK = Mutex.new

    # Loads Vernier once, warning when it can't.
    def self.available?(config)
      return @available unless @available.nil?

      @available = begin
        require "vernier"
        true
      rescue LoadError
        config.logger.warn("profiling a job needs the vernier gem (CRuby); running it unprofiled")
        false
      end
    end

    # Runs the block under the profiler and stores the result. Returns the
    # block's value.
    def self.profile(config, payload)
      collector = start(config)
      return yield unless collector

      started = Robin.now_ms
      ok = false
      begin
        result = yield
        ok = true
        result
      ensure
        record(config, payload, collector, started, ok)
      end
    end

    # A running collector, or nil if one can't start (e.g. the app is
    # profiling something else).
    def self.start(config)
      Vernier::Collector.new(:wall, {}).tap(&:start)
    rescue => e
      config.logger.warn("couldn't start the profiler (#{e.class}: #{e.message}); running the job unprofiled")
      nil
    end

    def self.record(config, payload, collector, started, ok)
      duration = Robin.now_ms - started
      data = Zlib.gzip(collector.stop.to_gecko)
      jid = payload.fetch("jid")
      if data.bytesize > MAX_BYTES
        config.logger.warn("profile of #{payload.fetch("class")} jid=#{jid} is too big to keep (#{data.bytesize} bytes)")
        return
      end

      label = payload.fetch("profile")
      entry = {"jid" => jid, "class" => Robin.display_class(payload), "queue" => payload["queue"],
               "label" => label.equal?(true) ? nil : label.to_s, "started_at" => started,
               "duration_ms" => duration, "ok" => ok, "bytes" => data.bytesize}
      config.redis do |conn|
        conn.multi do |tx|
          tx.call("SET", config.key("profile", jid), data, "EX", TTL)
          tx.call("ZADD", config.key("profiles"), started, Robin.dump_json(entry))
          tx.call("ZREMRANGEBYSCORE", config.key("profiles"), "-inf", "(#{started - TTL * 1000}")
          tx.call("ZREMRANGEBYRANK", config.key("profiles"), 0, -KEEP - 1)
        end
      end
    rescue => e
      config.handle_exception(e, {context: "storing a job profile", job: payload})
    end

    # Stored profiles, newest first (without their data).
    def self.list(config: Robin.config)
      entries(config).map(&:last)
    end

    # The profile JSON for +jid+, or nil once it has expired.
    def self.data(jid, config: Robin.config)
      data = config.redis { |c| c.call("GET", config.key("profile", jid)) }
      data && Zlib.gunzip(data)
    end

    # Deletes the profile of +jid+; true if there was one.
    def self.delete(jid, config: Robin.config)
      raws = entries(config).filter_map { |raw, entry| raw if entry.fetch("jid") == jid }
      config.redis do |c|
        c.multi do |tx|
          tx.call("DEL", config.key("profile", jid))
          tx.call("ZREM", config.key("profiles"), *raws) unless raws.empty?
        end
      end
      !raws.empty?
    end

    # [raw, parsed] pairs, newest first.
    def self.entries(config)
      config.redis { |c| c.call("ZRANGE", config.key("profiles"), 0, -1, "REV") }.map { |raw| [raw, Robin.load_json(raw)] }
    end
    private_class_method :entries

    # Profiles jobs pushed with a "profile" option. Installed by default;
    # a no-op for every other job.
    class ServerMiddleware
      include Middleware::ConfigAware
      include Middleware::Stateless

      def self.applies?(_job, payload, _queue) = payload.key?("profile")

      def call(_job, payload, _queue, &)
        return yield unless payload["profile"] && Profiler.available?(config)
        return yield unless LOCK.try_lock

        begin
          Profiler.profile(config, payload, &)
        ensure
          LOCK.unlock
        end
      end
    end
  end
end
