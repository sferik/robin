# frozen_string_literal: true

require "digest/sha2"

module Robin
  # Debounced jobs: a burst of pushes with the same arguments collapses
  # into a single run, +debounce+ seconds after the last push.
  #
  #   class ReindexDocument
  #     include Robin::Job
  #     robin_options debounce: 30
  #   end
  #
  #   10.times { ReindexDocument.perform_async(doc.id) } # runs once, ~30s later
  #
  # Each push schedules the job and atomically removes the previously
  # scheduled one, in the round trip that sends it. If two pushes race, both may land in the schedule, but
  # ServerMiddleware only runs the job recorded as the latest push and
  # skips any superseded one, so the job still runs once.
  module Debounce
    # Records this push as the latest and removes the previous scheduled
    # job. KEYS: debounce key, schedule set. ARGV: "<at (its score)>|<jid>",
    # expiry (epoch ms).
    CLAIM = Redis::Script.new(<<~LUA)
      local prev = redis.call('GET', KEYS[1])
      if prev then
        local sep = string.find(prev, '|', 1, true)
        local at, jid = string.sub(prev, 1, sep - 1), string.sub(prev, sep + 1)
        local needle = '"jid":"' .. jid .. '"'
        for _, job in ipairs(redis.call('ZRANGE', KEYS[2], at, at, 'BYSCORE')) do
          if string.find(job, needle, 1, true) then redis.call('ZREM', KEYS[2], job) end
        end
      end
      redis.call('SET', KEYS[1], ARGV[1], 'PXAT', ARGV[2])
      return 1
    LUA

    # A push's claim waits on its payload (as an instance variable, which
    # JSON leaves out) until the push sends it: see Debounce.queue_claims.
    CLAIM_IVAR = :@robin_debounce_claim

    # Queues the claims of +payloads+ on +pipe+, ahead of the jobs, so
    # each is made in the round trip that pushes its job, and only if it
    # is pushed. A bulk push's claims are made in order before its jobs
    # are sent; nothing between a claim and the next job's reads them, so
    # the outcome is the same.
    def self.queue_claims(pipe, payloads)
      payloads.each do |payload|
        next unless payload.key?("debounce_key")

        keys, argv = payload.instance_variable_get(CLAIM_IVAR)
        pipe.evalsha(CLAIM, keys, argv) if keys
      end
    end

    # Moves the claim of +from+, a payload as a client middleware got it,
    # to +to+, the payload the middleware chain returned instead.
    def self.carry(from, to)
      return if to.nil? || !from.instance_variable_defined?(CLAIM_IVAR)

      to.instance_variable_set(CLAIM_IVAR, from.instance_variable_get(CLAIM_IVAR))
    end

    class ClientMiddleware
      include Middleware::ConfigAware
      include Middleware::Stateless

      def self.applies?(_job_class, payload, _queue, _redis) = payload.key?("debounce")

      def call(job_class, payload, queue, _redis)
        window = payload["debounce"]
        return yield unless window

        at = [payload["at"], Robin.epoch_seconds(Robin.now_ms + Integer(window * 1000))].compact.max
        payload["at"] = at
        digest = Digest::SHA256.hexdigest(Robin.dump_json([job_class, queue, Unique.canonical(payload.fetch("args"))]))
        # The run time, as the schedule's score, finds the job again.
        token = "#{at}|#{payload.fetch("jid")}"
        # Keep the claim ten minutes past the run time.
        payload.instance_variable_set(CLAIM_IVAR,
          [[config.key("debounce", digest), config.key("schedule")], [token, Robin.epoch_ms(at) + 600_000]])
        payload["debounce_key"] = digest
        yield
      end
    end

    # Skips debounced jobs superseded by a later push.
    class ServerMiddleware
      include Middleware::ConfigAware
      include Middleware::Stateless

      def self.applies?(_job, payload, _queue) = payload.key?("debounce_key")

      def call(_job, payload, _queue)
        digest = payload["debounce_key"]
        return yield unless digest

        latest = redis { |c| c.call("GET", config.key("debounce", digest)) }
        if latest && !latest.split("|", 2).last.eql?(payload.fetch("jid"))
          logger.info { "skipping #{payload.fetch("class")} jid=#{payload.fetch("jid")}: superseded by a later push" }
          Events.emit(config, "job.skipped", job: payload, reason: "superseded")
          return
        end
        yield
      end
    end
  end
end
