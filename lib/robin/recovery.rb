# frozen_string_literal: true

module Robin
  # Puts jobs held by crashed processes back on their queues.
  #
  # Each server registers its in-flight set (see Robin::Fetcher) in
  # robin:inflights. A process whose heartbeat key has expired is dead;
  # its in-flight jobs are moved back to the front of their queues. Jobs
  # that keep getting orphaned (they crash their process every time) are
  # moved to the dead set.
  #
  # A process that is shutting down writes a stopping:<identity> marker
  # first; if it dies before it finishes, its jobs were interrupted by the
  # shutdown, not crashing it, so recovering them doesn't count toward the
  # poison-pill limit.
  module Recovery
    class << self
      # Recovers every dead process's in-flight jobs, in three round trips
      # however many there are (four when one is a poison pill). Returns
      # the number of jobs recovered. +pool+ is where the Redis connection
      # comes from (a server uses its housekeeping pool).
      def run(config, pool: config.redis_pool)
        pool.with do |conn|
          # In order, so processes are logged (and recovered) in order.
          sets = conn.call("SMEMBERS", config.key("inflights")).sort
          prefix = "#{config.key("inflight")}:"
          identities = sets.map { |set| set.delete_prefix(prefix) }
          checks = conn.pipelined do |p|
            identities.each do |identity|
              p.call("EXISTS", config.process_key(identity))
              p.call("EXISTS", config.key("stopping", identity))
            end
          end
          dead = sets.zip(identities, checks.each_slice(2)).filter_map do |set, identity, (alive, stopping)|
            [set, identity, stopping.zero?] if alive.zero?
          end
          recover(config, conn, dead).sum
        end
      end

      # Moves all jobs in a process's in-flight keys (its in-flight set
      # +key+) back to their queues, in one round trip (two when one is a
      # poison pill), and unregisters the keys; returns how many. With
      # +count+ false (a graceful shutdown) the jobs don't count toward
      # the poison-pill limit.
      def drain(config, conn, key, count:)
        done = queue_recover(config, conn, key, count)
        settle(config, conn, [[done, count]]).sum
      end

      private

      # Recovers the jobs of +dead+ processes ([in-flight set, identity,
      # count?] each) and forgets the processes; returns how many jobs each
      # had.
      def recover(config, conn, dead)
        replies = conn.pipelined do |p|
          dead.each do |set, identity, count|
            queue_recover(config, p, set, count)
            forget(config, p, set, identity)
          end
        end
        counts = settle(config, conn, replies.each_slice(2).map(&:first).zip(dead.map(&:last)))
        counts.zip(dead) do |recovered, (_set, identity, _count)|
          next if recovered.zero?

          config.logger.warn("recovered #{recovered} in-flight job(s) from dead process #{identity}")
          config.statsd&.increment("jobs.recovered", recovered)
        end
        counts
      end

      # mutant:disable -- Connection#evalsha splats ARGV, so passing the
      # identity bare or wrapped in an Array is identical.
      def forget(config, pipe, set, identity)
        pipe.evalsha(Scripts::FORGET, [set, config.key("inflights"), config.key("stopping", identity), config.key("processes")], [identity])
      end

      # Runs RECOVER on +redis+ (a connection), or queues it (a pipeline).
      def queue_recover(config, redis, key, count)
        redis.evalsha(Scripts::RECOVER, [key, config.key("queues"), config.key("dead")],
          ["#{config.key("queue")}:", config.max_recoveries, Robin.epoch_seconds(Robin.now_ms), count, "#{config.key("orphan")}:"])
      end

      # Takes RECOVER's replies, each with whether its jobs count: marks
      # the poison pills among them (in one round trip) and runs the
      # recovery handlers. Returns how many jobs each reply had.
      def settle(config, conn, results)
        jobs = results.flat_map do |done, count|
          # (RECOVER's reply is pairs, so each_slice(2) never yields a nil raw.)
          done.each_slice(2).map { |status, raw| [status == "dead", raw, count] } # steep:ignore BlockBodyTypeMismatch
        end #: Array[[bool, String, bool?]]
        poison = jobs.select(&:first).map { |_dead, raw, _count| raw }
        mark_poison(config, conn, poison) unless poison.empty?
        jobs.each { |dead, raw, count| recovered_job(config, raw, dead) if count }
        results.map { |done, _count| done.size / 2 }
      end

      # Runs config.recovery_handlers for a job recovered after a crash.
      def recovered_job(config, raw, poison)
        return if config.recovery_handlers.empty? && config.event_handlers.empty?

        payload = Robin.load_json(raw)
        Events.emit(config, "job.recovered", job: payload, poison: poison)
        config.recovery_handlers.each do |handler|
          handler.call(payload, poison)
        rescue => e
          config.handle_exception(e, {context: "recovery handler", job: payload})
        end
      rescue JSON::ParserError
        nil
      end

      def mark_poison(config, conn, raws)
        payloads = raws.map do |raw|
          payload = Robin.load_json(raw).except("enqueued_at")
          payload["error_class"] = "Robin::PoisonPill"
          payload["error_message"] = "job was running when its process died #{config.max_recoveries + 1} times"
          payload["failed_at"] ||= Robin.now_ms
          payload
        end
        conn.multi do |tx|
          raws.zip(payloads) do |raw, payload|
            tx.call("ZREM", config.key("dead"), raw)
            tx.call("ZADD", config.key("dead"), Robin.epoch_seconds(Robin.now_ms), Robin.dump_json(payload))
          end
        end
        payloads.each do |payload|
          config.logger.error("moved poison-pill job #{payload["class"]} jid=#{payload.fetch("jid")} to the dead set")
          config.statsd&.increment("jobs.poison", tags: {class: payload["class"]})
        end
      end
    end
  end
end
