# frozen_string_literal: true

module Robin
  # Distributed rate limiting, usable from jobs or any other Ruby code.
  #
  #   STRIPE = Robin::Limiter.concurrent("stripe", 10)          # at most 10 at once
  #   GITHUB = Robin::Limiter.bucket("github", 5_000, :hour)    # 5000 per calendar hour
  #   SMS    = Robin::Limiter.window("sms", 10, :minute)        # 10 in any 60s window
  #   EMAIL  = Robin::Limiter.leaky("email", 60, 60)            # drains 1/s, bursts to 60
  #   OPENAI = Robin::Limiter.points("openai", 90_000, 60)      # token budget per minute
  #
  #   STRIPE.within_limit { charge! }
  #   OPENAI.within_limit(points: tokens) { complete! }
  #   GITHUB.within_limit(used: 3) { sync_three_repos! }  # bucket and window
  #
  # Limiters keep their state in the configured Redis; Limiter.via sends a
  # thread's limiter calls to another one (e.g. a shard of their own):
  #
  #   Robin::Limiter.via(LIMITER_REDIS) { STRIPE.within_limit { charge! } }
  #
  # The web UI lists the limiters in the configured Redis only.
  #
  # #within_limit waits up to +wait_timeout+ seconds for capacity and
  # otherwise raises Robin::Limiter::OverLimit. Inside a job, Robin catches
  # OverLimit and reschedules the job with a backoff; that doesn't count as
  # a failure or use up retries.
  #
  # Every kind of limiter also takes:
  #
  # reschedule:: how many times a job that hits this limiter is rescheduled
  #              before the OverLimit counts as a failure (default
  #              config.max_rate_limit_retries; 0 fails at once)
  # backoff::    a callable (count, error, payload) returning the seconds to
  #              wait before running the job again, or nil for the default
  #              (see also config.rate_limit_backoff)
  # policy::     what #within_limit does when it can't get capacity in
  #              time: :raise (the default) raises OverLimit; :skip
  #              returns nil without running the block, for work that
  #              can be dropped (e.g. refreshing a cache)
  #
  # Robin::Limiter.unlimited never limits: swap it in where a limit
  # shouldn't apply, e.g. in tests.
  module Limiter
    class OverLimit < Robin::Error
      attr_reader :limiter, :retry_after

      def initialize(limiter, retry_after = nil)
        @limiter = limiter
        @retry_after = retry_after
        super("rate limiter #{limiter.name.inspect} (#{limiter.type}) is over its limit")
      end
    end

    # The end of every acquiring script (see Limiter.acquiring).
    COUNT_OVER = <<~LUA
      if taken == false or (type(taken) == 'number' and taken > 0) then
        if (taken or tonumber(ARGV[#ARGV - 1])) > tonumber(ARGV[#ARGV]) then
          redis.call('HINCRBY', KEYS[2], 'over', 1)
        end
      end
      return taken
    LUA

    # A limiter's acquiring script, from +body+: Lua that takes capacity
    # (KEYS[1] its state, KEYS[2] its definition) and returns 0, or a
    # token, when it took some, else how many ms until some frees up, or
    # false when it can't tell. The script also counts the limiter over
    # its limit when the wait is longer than the caller will wait. Its
    # last two ARGV, after the body's own: the wait (ms) to assume when
    # the body can't tell, and how long (ms) the caller will wait.
    def self.acquiring(body) = Redis::Script.new("local taken = (function()\n#{body}\nend)()\n#{COUNT_OVER}")

    INTERVALS = {second: 1, minute: 60, hour: 3_600, day: 86_400}.freeze
    TYPES = {"concurrent" => "Concurrent", "bucket" => "Bucket", "window" => "Window",
             "leaky" => "Leaky", "points" => "Points"}.freeze
    META_TTL = 30 * 86_400
    REGISTER_EVERY = 600

    # The definition each limiter name last wrote to each Redis, and when:
    # {[pool id, meta key] => [[type, limit, interval], monotonic time]}.
    # Shared by every limiter object, so one built inside perform doesn't
    # write its definition on every call.
    @registered = {}

    class << self
      attr_reader :registered # :nodoc:

      # Sends every limiter call this thread makes inside the block to
      # +pool+ (a Robin::Redis::Pool) instead of the configured Redis.
      def via(pool)
        previous = Thread.current[:robin_limiter_pool]
        Thread.current[:robin_limiter_pool] = pool
        yield
      ensure
        Thread.current[:robin_limiter_pool] = previous
      end

      # The pool set by an enclosing Limiter.via block, if any.
      def current_pool = Thread.current[:robin_limiter_pool]

      def concurrent(name, size, wait_timeout: 5, lock_timeout: 30, **)
        Concurrent.new(name, size, wait_timeout: wait_timeout, lock_timeout: lock_timeout, **)
      end

      def bucket(name, count, interval, **) = Bucket.new(name, count, interval, **)

      def window(name, count, interval, **) = Window.new(name, count, interval, **)

      def leaky(name, size, interval, **) = Leaky.new(name, size, interval, **)

      def points(name, points, interval, **) = Points.new(name, points, interval, **)

      def unlimited(name = "unlimited") = Unlimited.new(name)

      # Seconds for a :second/:minute/:hour/:day symbol (or string), a
      # number of seconds, or nil.
      def seconds(interval)
        case interval
        when Symbol, String then INTERVALS.fetch(interval.to_sym) { raise ArgumentError, "unknown interval #{interval.inspect}" }
        when nil then nil
        else Float(interval)
        end
      end

      # Every limiter used in the last 30 days, with current usage, in
      # two round trips.
      def list(config: Robin.config)
        metas = Scripts.member_hashes(config, config.key("limiters"), "#{config.key("lmtr")}:")
        expired, live = metas.partition { |_name, meta| meta.empty? }
        limiters = live.map { |name, meta| from_meta(name, meta, config) }
        usage = config.redis do |c|
          c.pipelined do |p|
            limiters.compact.each { |limiter| p.call(*limiter.used_command) }
            p.call("SREM", config.key("limiters"), *expired.map(&:first)) unless expired.empty?
          end
        end
        live.zip(limiters).map do |(name, meta), limiter|
          {
            "name" => name, "type" => meta.fetch("type"), "limit" => Integer(meta.fetch("limit")),
            "interval" => interval_from(meta), "used" => limiter ? limiter.used_from(usage.shift) : 0,
            "over_limit_count" => meta["over"].to_i, "last_used_at" => meta["last"]&.to_i
          }
        end
      end

      # Clears a limiter's state and over-limit counter, in two round trips.
      def reset!(name, config: Robin.config)
        clear(name, config) { |p, known| p.call("HSET", config.key("lmtr", name), "over", 0) if known }
        true
      end

      # Forgets a limiter: its state and its definition, in two round trips.
      def delete!(name, config: Robin.config)
        clear(name, config) do |p|
          p.call("DEL", config.key("lmtr", name))
          p.call("SREM", config.key("limiters"), name)
        end
        @registered.delete([config.redis_pool.object_id, config.key("lmtr", name)])
        true
      end

      private

      # Clears limiter +name+'s state, along with what the block queues
      # on the same pipeline; it's told whether the limiter has a
      # definition (one never used, or expired, has no state to clear).
      def clear(name, config)
        meta = config.redis { |c| c.call("HGETALL", config.key("lmtr", name)) }.each_slice(2).to_h
        limiter = from_meta(name, meta, config) unless meta.empty?
        config.redis do |c|
          c.pipelined do |p|
            p.call(*limiter.reset_command) if limiter
            yield p, !meta.empty?
          end
        end
      end

      def from_meta(name, meta, config)
        klass = TYPES[meta.fetch("type")]
        klass && const_get(klass).new(name, meta.fetch("limit"), interval_from(meta), config: config)
      end

      def interval_from(meta)
        raw = meta.fetch("interval")
        Float(raw) unless raw.empty?
      end
    end

    class Base
      POLICIES = %i[raise skip].freeze

      attr_reader :name, :limit, :interval, :interval_ms, :wait_timeout, :reschedule, :backoff, :policy

      def initialize(name, limit, interval, wait_timeout: 5, reschedule: nil, backoff: nil, policy: :raise, config: nil)
        @name = name.to_s
        raise ArgumentError, "limiter name can't be blank" if @name.empty?

        @limit = Integer(limit)
        raise ArgumentError, "limit must be positive" unless @limit.positive?

        @interval = seconds = Limiter.seconds(interval)
        @interval_ms = Integer(seconds * 1000) if seconds
        @wait_timeout = Float(wait_timeout)
        @reschedule = reschedule && Integer(reschedule)
        raise ArgumentError, "reschedule can't be negative" if @reschedule&.negative?
        raise ArgumentError, "backoff must respond to #call" unless backoff.nil? || backoff.respond_to?(:call)

        raise ArgumentError, "policy must be :raise or :skip, not #{policy.inspect}" unless POLICIES.include?(policy)

        @backoff = backoff
        @policy = policy
        @config = config
      end

      def config = @config || Robin.config

      def type = self.class.name.split("::").last.downcase

      # Runs the block once capacity is available. If it doesn't become
      # available within +wait_timeout+, raises OverLimit or (with policy:
      # :skip) returns nil without running the block.
      def within_limit(**opts)
        register
        token = wait_for_capacity(opts) or return
        begin
          yield self
        ensure
          release(token)
        end
      end

      def over_limit!
        redis { |c| c.call("HINCRBY", meta_key, "over", 1) }
      rescue
        nil
      end

      def reset_state
        redis { |c| c.call(*reset_command) }
      end

      # The command #reset_state sends.
      def reset_command = ["DEL", state_key]

      # How many uses are counted now: what the reply to each kind's
      # #used_command (Limiter.list sends them together) means.
      def used = used_from(redis { |c| c.call(*used_command) })

      def used_from(reply) = reply

      def to_h = {"name" => name, "type" => type, "limit" => limit, "interval" => interval, "used" => used}

      private

      def meta_key = config.key("lmtr", name)

      def state_key = config.key("lmtr", name, "s")

      def now_ms = Robin.now_ms

      def release(_token)
      end

      # Scripts return 0 when they took capacity, else how many ms until
      # some frees up. Returns [token, wait_ms].
      def outcome(wait) = [wait.zero?, wait]

      # Retries #acquire until it succeeds or waiting longer would pass the
      # deadline. Limiters that know when capacity frees up say so (in ms);
      # the others are polled with a short exponential backoff. Returns
      # the token, or nil when skipping.
      #
      # The script counts the limiter over its limit when it gives up, in
      # the same round trip: it's told the wait to assume (the backoff)
      # and how long is left (+wait+, in ms).
      def wait_for_capacity(opts)
        deadline = monotonic + @wait_timeout
        attempt = 0
        loop do
          guess = [0.01 * (2**attempt), 0.25].min * 1000
          left = (deadline - monotonic) * 1000
          token, wait_ms = acquire(**opts, wait: [guess, left])
          return token if token

          wait = wait_ms || guess
          if wait > left
            return if policy == :skip

            raise OverLimit.new(self, wait_ms && wait_ms / 1000.0)
          end
          attempt += 1
          sleep(wait / 1000.0 + rand * 0.005)
        end
      end

      # Writes the definition for the web UI, once per process and Redis
      # every 10 minutes, or as soon as a limiter of the same name with a
      # different definition writes its own.
      def register
        target = pool
        cache_key = [target.object_id, meta_key] #: [Integer, String]
        definition = [type, limit, interval] #: [String, Integer, Integer | Float | nil]
        written, at = Limiter.registered[cache_key]
        return if written == definition && monotonic - at < REGISTER_EVERY

        target.with do |c|
          c.pipelined do |p|
            p.call("HSET", meta_key, "type", type, "limit", limit, "interval", interval)
            p.call("EXPIRE", meta_key, META_TTL)
            p.call("SADD", config.key("limiters"), name)
          end
        end
        Limiter.registered[cache_key] = [definition, monotonic]
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def pool = Limiter.current_pool || config.redis_pool

      def redis(&) = pool.with(&)
    end

    # Lets one call count as several uses (+used:+), e.g. an API call that
    # covers a batch of records.
    module Uses
      def within_limit(used: 1, &)
        unless used.instance_of?(Integer) && used.between?(1, limit)
          raise ArgumentError, "used (#{used.inspect}) must be a whole number from 1 to the limit (#{limit})"
        end

        super
      end
    end

    # At most +size+ holders at once. Holders lease their slot for
    # +lock_timeout+ seconds so a crashed process can't leak capacity.
    class Concurrent < Base
      # Returns the lease token, or false when full.
      ACQUIRE = Limiter.acquiring(<<~LUA)
        local now = tonumber(ARGV[1])
        redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now)
        if redis.call('ZCARD', KEYS[1]) < tonumber(ARGV[2]) then
          redis.call('ZADD', KEYS[1], now + tonumber(ARGV[3]), ARGV[4])
          redis.call('PEXPIRE', KEYS[1], tonumber(ARGV[3]) + 60000)
          redis.call('HSET', KEYS[2], 'last', now)
          return ARGV[4]
        end
        return false
      LUA

      attr_reader :lock_timeout, :lock_timeout_ms

      def initialize(name, size, _interval = nil, lock_timeout: 30, **)
        super(name, size, nil, **)
        @lock_timeout = Float(lock_timeout)
        @lock_timeout_ms = Integer(@lock_timeout * 1000)
      end

      def used_command = ["ZCOUNT", state_key, "(#{now_ms}", "+inf"]

      private

      # The lease token, or nil when full (no wait is announced: holders
      # can release at any time, so callers poll).
      def acquire(wait:, **)
        redis { |c| c.evalsha(ACQUIRE, [state_key, meta_key], [now_ms, limit, lock_timeout_ms, Robin.generate_jid, *wait]) }
      end

      def release(token)
        redis { |c| c.call("ZREM", state_key, token) }
      end
    end

    # +limit+ uses per calendar interval (each second/minute/hour/day, or
    # any number of seconds, aligned to the epoch).
    class Bucket < Base
      include Uses

      # ARGV: limit, ttl (ms), now (ms), uses
      ACQUIRE = Limiter.acquiring(<<~LUA)
        local used = tonumber(ARGV[4])
        local n = redis.call('INCRBY', KEYS[1], used)
        if n == used then redis.call('PEXPIRE', KEYS[1], ARGV[2]) end
        if n > tonumber(ARGV[1]) then
          redis.call('DECRBY', KEYS[1], used)
          return math.max(redis.call('PTTL', KEYS[1]), 1)
        end
        redis.call('HSET', KEYS[2], 'last', ARGV[3])
        return 0
      LUA

      def initialize(name, limit, interval, **)
        super
        raise ArgumentError, "bucket limiters need an interval" unless interval_ms
      end

      def used_command = ["GET", bucket_key(now_ms)]

      def used_from(reply) = reply.to_i

      def reset_command = ["DEL", bucket_key(now_ms)]

      private

      def bucket_key(now) = config.key("lmtr", name, "b", now / interval_ms)

      def acquire(used:, wait:)
        now = now_ms
        ttl = interval_ms - (now % interval_ms)
        outcome(redis { |c| c.evalsha(ACQUIRE, [bucket_key(now), meta_key], [limit, ttl, now, used, *wait]) })
      end
    end

    # At most +limit+ uses in any rolling +interval+.
    class Window < Base
      include Uses

      # ARGV: now (ms), interval (ms), limit, unique id, uses. Each use is
      # a member; when they don't fit, the wait is until enough expire.
      ACQUIRE = Limiter.acquiring(<<~LUA)
        local now = tonumber(ARGV[1])
        local interval = tonumber(ARGV[2])
        local used = tonumber(ARGV[5])
        redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now - interval)
        local over = redis.call('ZCARD', KEYS[1]) + used - tonumber(ARGV[3])
        if over <= 0 then
          for i = 1, used do redis.call('ZADD', KEYS[1], now, ARGV[4] .. ':' .. i) end
          redis.call('PEXPIRE', KEYS[1], interval + 1000)
          redis.call('HSET', KEYS[2], 'last', now)
          return 0
        end
        local freeing = redis.call('ZRANGE', KEYS[1], over - 1, over - 1, 'WITHSCORES')
        return math.max(tonumber(freeing[2]) + interval - now, 1)
      LUA

      def initialize(name, limit, interval, **)
        super
        raise ArgumentError, "window limiters need an interval" unless interval_ms
      end

      def used_command = ["ZCOUNT", state_key, "(#{now_ms - interval_ms}", "+inf"]

      private

      def acquire(used:, wait:)
        outcome(redis { |c| c.evalsha(ACQUIRE, [state_key, meta_key], [now_ms, interval_ms, limit, Robin.generate_jid, used, *wait]) })
      end
    end

    # A bucket of capacity +limit+ that drains at limit/interval per second:
    # allows bursts up to +limit+, then a steady rate.
    class Leaky < Base
      # Fractions are written with %.14g, as Redis's Lua 5.1 does, so a
      # server with a newer Lua (Dragonfly writes 2 as "2.0") stores the
      # same text.
      ACQUIRE = Limiter.acquiring(<<~LUA)
        local now = tonumber(ARGV[1])
        local size = tonumber(ARGV[2])
        local interval = tonumber(ARGV[3])
        local level = tonumber(redis.call('HGET', KEYS[1], 'level') or '0')
        local last = tonumber(redis.call('HGET', KEYS[1], 'at') or ARGV[1])
        level = math.max(0, level - (now - last) * size / interval)
        if level + 1 <= size then
          redis.call('HSET', KEYS[1], 'level', string.format('%.14g', level + 1), 'at', now)
          redis.call('PEXPIRE', KEYS[1], interval + 1000)
          redis.call('HSET', KEYS[2], 'last', now)
          return 0
        end
        redis.call('HSET', KEYS[1], 'level', string.format('%.14g', level), 'at', now)
        return math.max(math.ceil((level + 1 - size) * interval / size), 1)
      LUA

      def initialize(name, limit, interval, **)
        super
        raise ArgumentError, "leaky limiters need an interval" unless interval_ms
      end

      # Current level; 0 when the limiter has never been used.
      def used_command = ["HMGET", state_key, "level", "at"]

      def used_from(reply)
        level, at = reply
        drained = (now_ms - at.to_i) * limit / interval_ms.to_f
        [level.to_f - drained, 0].max.ceil
      end

      private

      def acquire(wait:, **)
        outcome(redis { |c| c.evalsha(ACQUIRE, [state_key, meta_key], [now_ms, limit, interval_ms, *wait]) })
      end
    end

    # A token bucket holding +limit+ points, refilled continuously over
    # +interval+. Each call spends any number of points; use #refund (or a
    # negative #adjust) when the real cost turns out lower than estimated.
    class Points < Base
      # Fractions are written with %.14g, as Redis's Lua 5.1 does, so a
      # server with a newer Lua (Dragonfly writes 2 as "2.0") stores the
      # same text.
      ACQUIRE = Limiter.acquiring(<<~LUA)
        local now = tonumber(ARGV[1])
        local cap = tonumber(ARGV[2])
        local interval = tonumber(ARGV[3])
        local cost = tonumber(ARGV[4])
        local tokens = tonumber(redis.call('HGET', KEYS[1], 'tokens') or ARGV[2])
        local last = tonumber(redis.call('HGET', KEYS[1], 'at') or ARGV[1])
        tokens = math.min(cap, tokens + (now - last) * cap / interval)
        if tokens >= cost then
          redis.call('HSET', KEYS[1], 'tokens', string.format('%.14g', tokens - cost), 'at', now)
          redis.call('PEXPIRE', KEYS[1], interval * 2)
          redis.call('HSET', KEYS[2], 'last', now)
          return 0
        end
        redis.call('HSET', KEYS[1], 'tokens', string.format('%.14g', tokens), 'at', now)
        redis.call('PEXPIRE', KEYS[1], interval * 2)
        return math.max(math.ceil((cost - tokens) * interval / cap), 1)
      LUA

      ADJUST = Redis::Script.new(<<~LUA)
        local now = tonumber(ARGV[1])
        local cap = tonumber(ARGV[2])
        local interval = tonumber(ARGV[3])
        local tokens = tonumber(redis.call('HGET', KEYS[1], 'tokens') or ARGV[2])
        local last = tonumber(redis.call('HGET', KEYS[1], 'at') or ARGV[1])
        tokens = math.min(cap, math.min(cap, tokens + (now - last) * cap / interval) - tonumber(ARGV[4]))
        redis.call('HSET', KEYS[1], 'tokens', string.format('%.14g', tokens), 'at', now)
        redis.call('PEXPIRE', KEYS[1], interval * 2)
        return string.format('%.14g', tokens)
      LUA

      def initialize(name, limit, interval, **)
        super
        raise ArgumentError, "points limiters need an interval" unless interval_ms
      end

      def within_limit(points: 1, &)
        raise ArgumentError, "points (#{points}) exceed the limiter's capacity (#{limit})" if points > limit

        super
      end

      # Spends (positive) or returns (negative) points outside #within_limit.
      # Returns the points now available.
      def adjust(points)
        Float(redis { |c| c.evalsha(ADJUST, [state_key], [now_ms, limit, interval_ms, points]) })
      end

      def refund(points) = adjust(-points)

      # Points spent and not yet refilled; 0 when never used.
      def used_command = ["HMGET", state_key, "tokens", "at"]

      def used_from(reply)
        tokens, at = reply
        return 0 unless tokens

        available = Float(tokens) + (now_ms - Integer(at)) * limit / interval_ms.to_f
        (limit - available).ceil.clamp(0, limit)
      end

      private

      def acquire(points:, wait:)
        outcome(redis { |c| c.evalsha(ACQUIRE, [state_key, meta_key], [now_ms, limit, interval_ms, points, *wait]) })
      end
    end

    # A limiter that never limits (and never touches Redis).
    class Unlimited
      attr_reader :name

      def initialize(name) = @name = name.to_s

      def type = "unlimited"

      def within_limit(**) = yield(self)

      def used = 0

      # Like Points#adjust: as many points as anyone could want.
      def adjust(_points) = Float::INFINITY

      def refund(_points) = Float::INFINITY

      def to_h = {"name" => name, "type" => type, "limit" => nil, "interval" => nil, "used" => 0}
    end

    # Reschedules jobs whose limiter is over its limit instead of failing
    # them. After the limiter's +reschedule+ count (or
    # config.max_rate_limit_retries) the OverLimit error is raised, so normal
    # retry handling takes over.
    class ServerMiddleware
      include Middleware::ConfigAware
      include Middleware::Stateless

      def call(_job, payload, _queue)
        yield
      rescue OverLimit => e
        count = payload["limited"].to_i + 1
        raise if count > (e.limiter.reschedule || config.max_rate_limit_retries)

        delay = custom_delay(e, count, payload) || default_delay(e, count, payload)
        at = Robin.epoch_seconds(Robin.now_ms + Integer(delay * 1000))
        stored = Robin.pristine(payload).except("at", "enqueued_at").merge({"limited" => count})
        redis { |c| c.call("ZADD", config.key("schedule"), at, Robin.dump_json(stored)) }
        Events.emit(config, "job.rate_limited", job: payload, limiter: e.limiter.name, delay: delay)
        logger.info do
          "#{payload.fetch("class")} jid=#{payload.fetch("jid")} over limit #{e.limiter.name.inspect}; rescheduled in #{delay.round(1)}s"
        end
        nil
      end

      private

      # The limiter's backoff, else config.rate_limit_backoff: seconds, or
      # nil for the default. One that raises or returns something else is
      # reported, and the default used.
      def custom_delay(error, count, payload)
        backoff = error.limiter.backoff || config.rate_limit_backoff or return
        seconds = backoff.call(count, error, payload)
        return if seconds.nil?
        return seconds if seconds.is_a?(Numeric) && seconds.real? && seconds.finite? && !seconds.negative?

        raise ArgumentError, "rate limit backoff returned #{seconds.inspect}; expected seconds (>= 0) or nil"
      rescue => e
        config.handle_exception(e, {context: "rate limit backoff", job: payload})
        nil
      end

      # Grows with each reschedule, at least as long as the limiter says
      # capacity takes to free up, at most 5 minutes, with +/-15% jitter.
      def default_delay(error, count, payload)
        base = (payload["limiter_backoff"] || 5) * count
        [base, error.retry_after.to_f].max.clamp(..300.0) * (0.85 + rand * 0.3)
      end
    end
  end
end
