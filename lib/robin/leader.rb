# frozen_string_literal: true

module Robin
  # Cluster-wide leader election using a Redis lease.
  #
  # Every server process tries to acquire or renew the lease on each
  # heartbeat. Exactly one holds it at a time; if the leader dies, the
  # lease expires and another process takes over within ~TTL seconds.
  # The leader runs singleton duties such as cron jobs and in-flight job
  # recovery. Subscribe with config.on(:leader) / config.on(:follower).
  class Leader
    TTL_MS = 20_000

    @leaders = {}

    class << self
      # Whether this process currently leads the cluster behind +config+.
      def leader?(config = Robin.config)
        @leaders[config.object_id]&.leader? || false
      end

      def register(config, elector)
        @leaders[config.object_id] = elector
      end

      def unregister(config)
        @leaders.delete(config.object_id)
      end

      # Identity of the current leader, from Redis.
      def current(config = Robin.config)
        config.redis { |c| c.call("GET", config.key("leader")) }
      end
    end

    attr_reader :identity

    def initialize(config, identity)
      @config = config
      @identity = identity
      @leader = false
      @until = 0
    end

    def leader?
      @leader && monotonic < @until
    end

    # Queues a request to acquire or renew the lease on +pipe+ (a pipeline
    # about to be sent); pass its reply to #settle.
    def lease(pipe)
      @asked = monotonic
      pipe.evalsha(Scripts::LEASE, [@config.key("leader")], [@identity, TTL_MS])
    end

    # Takes the reply to #lease. Fires :leader / :follower on transitions.
    def settle(reply)
      won = reply == 1
      was = @leader
      @leader = won
      # Be conservative: assume the lease started when we sent the request.
      @until = @asked + (TTL_MS / 1000.0) * 0.9 if won
      if won && !was
        @config.logger.info("became cluster leader")
        @config.fire_event(:leader)
      elsif !won && was
        @config.logger.info("lost cluster leadership")
        @config.fire_event(:follower)
      end
      won
    end

    def resign(conn)
      return unless @leader

      conn.evalsha(Scripts::RELEASE, [@config.key("leader")], [@identity])
      @leader = false
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
