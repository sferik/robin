# frozen_string_literal: true

require "digest/sha2"

module Robin
  # Deploy markers: the dashboard's metrics charts draw a line at each, so
  # a change in throughput or failures can be matched to the deploy that
  # caused it.
  #
  #   Robin::Deploy.mark!("v42 #{`git rev-parse --short HEAD`.strip}")
  #
  # or `bundle exec robin deploy "v42"` from a deploy script. Every process
  # may mark the same deploy (e.g. at boot): a label marked in the last
  # hour isn't marked again. Markers are kept as long as hourly metrics
  # (Config#metrics_retention_days).
  module Deploy
    DEDUP_SECONDS = 3600
    MAX_LABEL = 200

    # Adds a deploy mark, unless its label was marked in the last hour,
    # and drops marks older than the retention. Returns 1, or 0 when the
    # label was marked already.
    #
    # KEYS: the marks' sorted set, the label's dedup key (none for no
    # label). ARGV: when (epoch ms), the mark, the oldest time kept (ms),
    # the dedup TTL (seconds).
    MARK = Redis::Script.new(<<~LUA)
      if KEYS[2] and not redis.call('SET', KEYS[2], ARGV[1], 'NX', 'EX', ARGV[4]) then return 0 end
      redis.call('ZADD', KEYS[1], ARGV[1], ARGV[2])
      redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', '(' .. ARGV[3])
      return 1
    LUA

    class << self
      # Records a deploy at +at+, in one round trip. Returns false when
      # +label+ was already marked in the last hour, true otherwise.
      def mark!(label = nil, at: Time.now, config: Robin.config)
        label = label&.to_s&.[](0, MAX_LABEL)
        at_ms = ms(at)
        retention_ms = config.metrics_retention_days * 86_400_000
        keys = [key(config), *(dedup_key(config, label) if label)]
        mark = Robin.dump_json({"at" => at_ms, "label" => label})
        # EVAL, not EVALSHA: the connection may be another library's (a
        # compatibility layer's, say), and deploys are rare.
        config.redis { |c| c.call("EVAL", MARK.source, keys.size, *keys, at_ms, mark, at_ms - retention_ms, DEDUP_SECONDS) } == 1
      end

      # Deploys from +from+ to +to+ (Times), oldest first: hashes with
      # "at" (epoch ms) and "label" (or nil).
      def list(from:, to: Time.now, config: Robin.config)
        range = [ms(from), ms(to)]
        config.redis { |c| c.call("ZRANGE", key(config), *range, "BYSCORE") }.map { |raw| Robin.load_json(raw) }
      end

      def key(config) = config.key("deploys")

      private

      # mutant:disable -- to_i, to_int and Integer() agree on Rationals.
      def ms(time) = (time.to_r * 1000).to_i

      def dedup_key(config, label) = config.key("deploy", Digest::SHA256.hexdigest(label))
    end
  end
end
