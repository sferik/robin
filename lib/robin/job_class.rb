# frozen_string_literal: true

module Robin
  # Pausing one job class across every queue (Robin-only).
  #
  #   Robin::JobClass.new(ReportJob).pause!
  #   Robin::JobClass.new("ReportJob").unpause!
  #
  # A paused class's jobs wait where they are (queued, scheduled, retrying)
  # until a worker fetches one: then, instead of running, it's parked. On
  # unpausing, the parked jobs go back on the front of their queues, the
  # oldest first in line. Jobs already running finish.
  #
  # Servers refresh their copy of the paused classes on every heartbeat, so
  # a pause takes effect within one, and checking a fetched job costs no
  # round trip. A fetched job is parked only if its class is still paused,
  # checked atomically as it's moved, so an unpause never strands one that
  # a server still thought paused.
  #
  # An Active Job job's class is the one it wraps.
  class JobClass
    # Parks a fetched job if its class is still paused: moves it from its
    # in-flight key onto the class's parked list, the newest on the left.
    #
    # KEYS: paused classes set, in-flight key, parked list
    # ARGV: class name
    PARK = Redis::Script.new(<<~LUA)
      if redis.call('SISMEMBER', KEYS[1], ARGV[1]) == 0 then return 0 end
      if redis.call('LMOVE', KEYS[2], KEYS[3], 'RIGHT', 'LEFT') then return 1 end
      return 0
    LUA

    # Moves up to ARGV[2] of a class's parked jobs back onto the front of
    # their queues: the newest first, so the oldest end up first in line.
    # Returns how many it moved and how many are still parked.
    #
    # KEYS: parked list, queues set
    # ARGV: queue key prefix, how many
    UNPARK = Redis::Script.new(<<~LUA)
      local moved = 0
      while moved < tonumber(ARGV[2]) do
        local raw = redis.call('LPOP', KEYS[1])
        if not raw then break end
        local queue = cjson.decode(raw)['queue'] or 'default'
        redis.call('SADD', KEYS[2], queue)
        redis.call('RPUSH', ARGV[1] .. queue, raw)
        moved = moved + 1
      end
      return {moved, redis.call('LLEN', KEYS[1])}
    LUA

    # The paused classes and how many of each one's jobs are parked: name,
    # count, name, count...
    #
    # KEYS: paused classes set
    # ARGV: parked list key prefix
    LIST = Redis::Script.new(<<~LUA)
      local out = {}
      for _, name in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        table.insert(out, name)
        table.insert(out, redis.call('LLEN', ARGV[1] .. name))
      end
      return out
    LUA

    @cache = {}

    class << self
      # The paused classes' names, sorted.
      def paused(config: Robin.config) = config.redis { |c| c.call("SMEMBERS", config.key("classes", "paused")) }.sort

      # Each paused class, by name: its name and how many of its jobs are
      # parked. One round trip.
      #
      # mutant:disable -- Connection#evalsha splats ARGV, so passing the
      # prefix bare or wrapped in an Array is identical.
      def list(config: Robin.config)
        flat = config.redis { |c| c.evalsha(LIST, [config.key("classes", "paused")], ["#{config.key("classes", "parked")}:"]) }
        flat.each_slice(2).map { |name, parked| {"name" => name, "parked" => parked} }.sort_by { |row| row.fetch("name") }
      end

      # The command that reads the paused classes, for a heartbeat to send
      # along with others; pass its reply to #store.
      def listing(config) = ["SMEMBERS", config.key("classes", "paused")]

      # Replaces the local copy of the paused classes.
      def store(config, names)
        @cache[config.object_id] = Set.new(names)
      end

      # Of +payload+'s classes (the one an Active Job job wraps, and the
      # job's), the one this process last saw paused, or nil. Allocates
      # nothing: every job is checked.
      def paused_class(config, payload)
        set = @cache[config.object_id] or return

        wrapped = payload["wrapped"]
        return wrapped if set.include?(wrapped)

        klass = payload["class"]
        klass if set.include?(klass)
      end

      # Parks +unit+, a fetched job of the paused class +name+, unless
      # +name+ was unpaused meanwhile; whether it did.
      #
      # mutant:disable -- Connection#evalsha splats ARGV, so passing the
      # name bare or wrapped in an Array is identical.
      def park(config, unit, name)
        keys = [config.key("classes", "paused"), unit.key, config.key("classes", "parked", name)]
        config.redis { |c| c.evalsha(PARK, keys, [name]) } == 1
      end

      # This process's own pauses and unpauses show in its copy at once,
      # before the next heartbeat.
      def noted(config, name, paused)
        set = @cache[config.object_id] or return

        paused ? set.add(name) : set.delete(name)
      end
    end

    attr_reader :name

    # +klass+: a job class, or its name.
    def initialize(klass, config: Robin.config)
      @name = klass.to_s
      @config = config
    end

    def paused? = @config.redis { |c| c.call("SISMEMBER", @config.key("classes", "paused"), name) } == 1

    # How many of its jobs are parked.
    def parked = @config.redis { |c| c.call("LLEN", @config.key("classes", "parked", name)) }

    def pause!
      @config.redis { |c| c.call("SADD", @config.key("classes", "paused"), name) }
      JobClass.noted(@config, name, true)
      true
    end

    # Unpauses the class and puts its parked jobs back on their queues,
    # +chunk+ of them a round trip; returns how many it put back. Once it's
    # unpaused no more are parked (see PARK), so none are left behind.
    def unpause!(chunk: 1000)
      @config.redis { |c| c.call("SREM", @config.key("classes", "paused"), name) }
      JobClass.noted(@config, name, false)
      keys = [@config.key("classes", "parked", name), @config.key("queues")]
      total = 0
      loop do
        moved, left = @config.redis { |c| c.evalsha(UNPARK, keys, ["#{@config.key("queue")}:", chunk]) }
        total += moved
        return total if left.zero?
      end
    end
  end
end
