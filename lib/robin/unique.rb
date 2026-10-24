# frozen_string_literal: true

require "digest/sha2"

module Robin
  # Unique jobs: suppress pushes of a job identical (same class, queue and
  # arguments) to one that's still pending.
  #
  #   class SyncAccount
  #     include Robin::Job
  #     robin_options unique_for: 600                  # seconds
  #     robin_options unique_until: :start             # default :success
  #
  #     # Optional: decide which arguments make a job unique.
  #     def self.robin_unique_args(args) = args.first(1)
  #   end
  #
  #   SyncAccount.perform_async(1) # => "jid..."
  #   SyncAccount.perform_async(1) # => nil (duplicate)
  #
  # The lock lives until the job starts (:start) or succeeds (:success), or
  # until unique_for seconds pass — whichever is first. For scheduled jobs
  # the lock also covers the wait until the scheduled time. Failed jobs
  # keep the lock while they wait for a retry; it is released when they
  # die or are discarded.
  module Unique
    # Locks taken ahead for a bulk push (see Unique.claiming).
    CLAIMS = :robin_unique_claims

    class << self
      def digest(klass_name, queue, args)
        klass = constant(klass_name)
        args = klass.robin_unique_args(args) if klass.respond_to?(:robin_unique_args)
        Digest::SHA256.hexdigest(Robin.dump_json([klass_name, queue, canonical(args)]))
      end

      # Hashes become key-sorted pairs (string keys), so argument hashes
      # that differ only in key order or key type have the same digest.
      def canonical(obj)
        case obj
        when Hash then obj.map { |k, v| [k.to_s, canonical(v)] }.sort_by(&:first)
        when Array then obj.map { |v| canonical(v) }
        else obj
        end
      end

      def lock_key(config, digest) = config.key("unique", digest)

      # Does a job take a lock when it's pushed? Not without a positive
      # unique_for, nor once it has its lock (e.g. a retry).
      def lockable?(payload)
        ttl = payload["unique_for"]
        ttl&.positive? && !payload.key?("unique_digest")
      end

      # Runs the block (a bulk push of +payloads+, which share their
      # options) with their unique locks taken beforehand, in one round
      # trip, when +chain+ (client middleware) starts with
      # ClientMiddleware: nothing before it can change a job or stop its
      # push then. Only a lock's first job in +payloads+ claims it ahead:
      # another with the same lock tries when its turn comes, as it would
      # have, after the first one's push went through or was stopped.
      # Locks taken for jobs the block never got to (it raised) are given
      # back.
      def claiming(chain, payloads)
        entry = chain.first
        first = payloads.first
        return yield unless first && entry&.klass.equal?(ClientMiddleware) && lockable?(first)

        # (entry&.klass.equal? above means entry is there, and that it builds
        # a ClientMiddleware; Steep can't tell.)
        middleware = entry.build # steep:ignore NoMethod
        claims = middleware.claim_all(payloads)
        previous = Thread.current[CLAIMS]
        Thread.current[CLAIMS] = claims
        begin
          yield
        ensure
          Thread.current[CLAIMS] = previous
          left = claims.select { |_payload, (_digest, _key, won)| won }
          unless left.empty?
            middleware.redis { |c| c.pipelined { |p| left.each { |payload, (_, key)| compare_and_delete(p, key, payload.fetch("jid")) } } }
          end
        end
      end

      # Is a lock currently held for these arguments?
      def locked?(klass_name, args, queue: "default", config: Robin.config)
        config.redis { |c| c.call("EXISTS", lock_key(config, digest(klass_name, queue, args))) } == 1
      end

      def release(config, payload) = payload["unique_digest"] && config.redis { |c| eval_release(c, config, payload) }

      # Releases +payload+'s lock, if it has one and still holds it, on
      # +redis+: a connection (returns the reply), or a pipeline or
      # transaction to queue it in.
      def eval_release(redis, config, payload)
        digest = payload["unique_digest"]
        compare_and_delete(redis, lock_key(config, digest), payload.fetch("jid")) if digest
      end

      private

      # mutant:disable -- Connection#evalsha splats ARGV, so passing the
      # owner bare or wrapped in an Array is identical.
      def compare_and_delete(redis, key, owner) = redis.evalsha(Scripts::RELEASE, [key], [owner])

      # mutant:disable -- `const_get` on Robin::Unique instead of Object
      # differs only for constants nested in Robin::Unique, none of which
      # are job classes.
      def constant(name)
        Object.const_get(name)
      rescue NameError
        nil
      end
    end

    class ClientMiddleware
      include Middleware::ConfigAware
      include Middleware::Stateless

      def self.applies?(_job_class, payload, _queue, _redis) = Unique.lockable?(payload)

      def call(job_class, payload, queue, _redis)
        return yield unless Unique.lockable?(payload)

        digest, key, won = Thread.current[CLAIMS]&.delete(payload) || claim(job_class, payload, queue)
        unless won
          logger.debug { "suppressed duplicate #{job_class} #{payload.fetch("args")}; locked by #{redis { |c| c.call("GET", key) }}" }
          return
        end

        payload["unique_digest"] = digest
        result = yield
        Unique.release(config, payload) unless result # a later middleware stopped the push
        result
      end

      # Takes the locks of +payloads+ (see Unique.claiming) in one round
      # trip; returns {payload => [digest, lock key, won?]}, by identity.
      def claim_all(payloads)
        locks = {} #: Hash[String, [job_hash, [String, String, Integer]]]
        payloads.each do |payload|
          next unless Unique.lockable?(payload)

          lock = lock_for(payload.fetch("class"), payload, payload.fetch("queue"))
          locks[lock[1]] ||= [payload, lock]
        end
        replies = redis { |c| c.pipelined { |p| locks.each_value { |payload, (_, key, expires_at)| p.call(*set_command(payload, key, expires_at)) } } }
        locks.values.zip(replies).to_h { |(payload, (digest, key, _)), won| [payload, [digest, key, won]] }.compare_by_identity #: Hash[job_hash, claim]
      end

      private

      # Takes the lock for one job: [digest, lock key, won?].
      def claim(job_class, payload, queue)
        digest, key, expires_at = lock_for(job_class, payload, queue)
        [digest, key, redis { |c| c.call(*set_command(payload, key, expires_at)) }]
      end

      # [digest, lock key, expiry (epoch ms)] for a job.
      def lock_for(job_class, payload, queue)
        digest = Unique.digest(job_class, queue, payload.fetch("args"))
        # Scheduled jobs stay locked until unique_for after their run time.
        expires_at = [payload["at"]&.then { |at| Robin.epoch_ms(at) }, Robin.now_ms].compact.max + Integer(payload.fetch("unique_for") * 1000)
        [digest, Unique.lock_key(config, digest), expires_at]
      end

      def set_command(payload, key, expires_at) = ["SET", key, payload.fetch("jid"), "NX", "PXAT", expires_at]
    end

    class ServerMiddleware
      include Middleware::ConfigAware
      include Middleware::Stateless

      def self.applies?(_job, payload, _queue) = payload.key?("unique_digest")

      def call(_job, payload, _queue)
        # With unique_until: :start the lock goes before the job runs, and
        # nothing takes it again for this jid, so that's the only release.
        if payload["unique_until"].to_s == "start"
          Unique.release(config, payload)
          return yield
        end

        begin
          result = yield
        rescue Robin::Discard
          Unique.release(config, payload)
          raise
        end
        # An interrupted iterable job was requeued and is still pending.
        Unique.release(config, payload) unless payload["iteration_interrupted"]
        result
      end
    end
  end
end
