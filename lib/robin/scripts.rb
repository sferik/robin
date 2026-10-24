# frozen_string_literal: true

module Robin
  # Lua scripts used on hot paths. Each runs atomically on the server.
  module Scripts
    # Acknowledges finished jobs (deletes their in-flight keys), then
    # moves up to +count+ jobs into in-flight keys, one each, taking from
    # the first non-paused queue until it runs dry before moving on to the
    # next: one round trip for several jobs.
    #
    # KEYS: paused set, +count+ in-flight keys to fill, queue lists, then
    # the finished jobs' in-flight keys
    # ARGV: count, the queue names (same order as the queue list keys)
    # Returns: a flat list of queue name, payload pairs, in the order of
    # the in-flight keys they went to
    FETCH = Redis::Script.new(<<~LUA)
      local count = tonumber(ARGV[1])
      local acks = count + #ARGV + 1
      if acks <= #KEYS then redis.call('DEL', unpack(KEYS, acks)) end
      local taken = {}
      local filled = 0
      for i = 2, #ARGV do
        local name = ARGV[i]
        if redis.call('SISMEMBER', KEYS[1], name) == 0 then
          while filled < count do
            local job = redis.call('LMOVE', KEYS[count + i], KEYS[filled + 2], 'RIGHT', 'LEFT')
            if not job then break end
            filled = filled + 1
            taken[#taken + 1] = name
            taken[#taken + 1] = job
          end
        end
        if filled == count then break end
      end
      return taken
    LUA

    # Moves every due job from a sorted set (schedule or retry) onto its
    # queue, recording when as its enqueued_at. Stored jobs have none, so
    # it's appended to the JSON rather than re-encoding it, which could
    # change how numbers in it are written (were there one, the last
    # occurrence wins when it's parsed).
    #
    # Returns how many jobs it took (at most the max; some may have been
    # taken by another process meanwhile) and, if any job is left in the
    # set, the earliest one's score: {count[, score]}.
    #
    # KEYS: sorted set, queues set
    # ARGV: now (epoch seconds), queue key prefix ("<prefix>queue:"), max
    # jobs per call, now (epoch ms)
    ENQUEUE_DUE = Redis::Script.new(<<~LUA)
      local jobs = redis.call('ZRANGE', KEYS[1], '-inf', ARGV[1], 'BYSCORE', 'LIMIT', 0, tonumber(ARGV[3]))
      for _, job in ipairs(jobs) do
        if redis.call('ZREM', KEYS[1], job) == 1 then
          local ok, decoded = pcall(cjson.decode, job)
          local queue = 'default'
          if ok and type(decoded) == 'table' then
            if type(decoded['queue']) == 'string' then queue = decoded['queue'] end
            -- Only a non-empty JSON object ("{...}") gets the field.
            if string.byte(job, 1) == 123 and next(decoded) then
              job = string.sub(job, 1, -2) .. ',"enqueued_at":' .. ARGV[4] .. '}'
            end
          end
          redis.call('SADD', KEYS[2], queue)
          redis.call('LPUSH', ARGV[2] .. queue, job)
        end
      end
      return {#jobs, redis.call('ZRANGE', KEYS[1], 0, 0, 'WITHSCORES')[2]}
    LUA

    # Moves the jobs in a process's in-flight keys back onto the front of
    # their queues, oldest first, unregistering each key once it's empty.
    # Returns what it did to each job: status, job, status, job...
    # ("requeued" or "dead").
    #
    # When counting (crash recovery, not a graceful shutdown), each
    # recovery of a job bumps its orphan:<jid> counter, and a job orphaned
    # too many times (a "poison pill" that keeps crashing processes) goes
    # to the dead set instead. A counted job gets a "recovered" field so
    # the processor knows to clear its counter once it succeeds.
    #
    # KEYS: the process's in-flight set (or, from before in-flight sets,
    # the one list it kept its jobs in), queues set, dead set
    # ARGV: queue key prefix ("<prefix>queue:"), max recoveries, now (epoch
    # seconds, the dead set's score), count ("true" or "false"), orphan
    # counter key prefix
    RECOVER = Redis::Script.new(<<~LUA)
      local done = {}
      local function drain(key)
        while true do
          local job = redis.call('RPOP', key)
          if not job then return end
          local ok, decoded = pcall(cjson.decode, job)
          local queue, jid = 'default', nil
          if ok and type(decoded) == 'table' then
            if type(decoded['queue']) == 'string' then queue = decoded['queue'] end
            jid = decoded['jid']
          end
          local status = 'requeued'
          if jid and ARGV[4] == 'true' then
            local key = ARGV[5] .. jid
            local n = redis.call('INCR', key)
            redis.call('EXPIRE', key, 604800)
            if n > tonumber(ARGV[2]) then
              redis.call('ZADD', KEYS[3], ARGV[3], job)
              status = 'dead'
            -- Splice the field in rather than re-encoding, which could
            -- change how numbers in the payload are written.
            elseif decoded['recovered'] == nil then
              job = '{"recovered":true,' .. string.sub(job, 2)
            end
          end
          if status == 'requeued' then
            redis.call('SADD', KEYS[2], queue)
            redis.call('RPUSH', ARGV[1] .. queue, job)
          end
          done[#done + 1] = status
          done[#done + 1] = job
        end
      end
      if redis.call('TYPE', KEYS[1])['ok'] == 'list' then
        drain(KEYS[1])
      else
        for _, key in ipairs(redis.call('SMEMBERS', KEYS[1])) do
          drain(key)
          redis.call('SREM', KEYS[1], key)
        end
      end
      return done
    LUA

    # Forgets a dead process once its jobs are recovered: unregisters its
    # in-flight set and stopping marker, unless the set filled again (the
    # process only looked dead; its heartbeat had lapsed), and its
    # identity.
    #
    # KEYS: its in-flight set, the in-flight sets' set, its stopping
    # marker, the processes set
    # ARGV: its identity
    FORGET = Redis::Script.new(<<~LUA)
      if redis.call('EXISTS', KEYS[1]) == 0 then
        redis.call('SREM', KEYS[2], KEYS[1])
        redis.call('DEL', KEYS[3])
      end
      redis.call('SREM', KEYS[4], ARGV[1])
      return 1
    LUA

    # Unregisters the processes whose heartbeat key has expired. Returns
    # how many.
    #
    # KEYS: the processes set
    # ARGV: the heartbeat keys' prefix (a process's is it and its identity)
    PRUNE = Redis::Script.new(<<~LUA)
      local pruned = 0
      for _, identity in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        if redis.call('EXISTS', ARGV[1] .. identity) == 0 then
          redis.call('SREM', KEYS[1], identity)
          pruned = pruned + 1
        end
      end
      return pruned
    LUA

    # Every queue's size and oldest job: name, size, job, name, size,
    # job... (a job is false for an empty queue).
    #
    # KEYS: the queues set
    # ARGV: queue key prefix ("<prefix>queue:")
    QUEUE_SAMPLES = Redis::Script.new(<<~LUA)
      local samples = {}
      for _, queue in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        samples[#samples + 1] = queue
        samples[#samples + 1] = redis.call('LLEN', ARGV[1] .. queue)
        samples[#samples + 1] = redis.call('LINDEX', ARGV[1] .. queue, -1)
      end
      return samples
    LUA

    # Moves a job from an in-flight key back onto the front of its queue,
    # if it's still there (a worker may have finished it), then
    # unregisters the key if it's empty.
    #
    # KEYS: in-flight key, queue list, queues set, in-flight set
    # ARGV: raw job ("" for none), queue name
    REQUEUE_ONE = Redis::Script.new(<<~LUA)
      local moved = 0
      if ARGV[1] ~= '' and redis.call('LREM', KEYS[1], 1, ARGV[1]) == 1 then
        redis.call('SADD', KEYS[3], ARGV[2])
        redis.call('RPUSH', KEYS[2], ARGV[1])
        moved = 1
      end
      if redis.call('EXISTS', KEYS[1]) == 0 then redis.call('SREM', KEYS[4], KEYS[1]) end
      return moved
    LUA

    # Acquires or renews a lease.
    #
    # KEYS: lease key
    # ARGV: owner, ttl (ms)
    LEASE = Redis::Script.new(<<~LUA)
      local current = redis.call('GET', KEYS[1])
      if current == ARGV[1] then
        redis.call('PEXPIRE', KEYS[1], ARGV[2])
        return 1
      elseif not current then
        redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[2])
        return 1
      end
      return 0
    LUA

    # Deletes a key only if it still holds the given value.
    #
    # KEYS: key
    # ARGV: expected value
    RELEASE = Redis::Script.new(<<~LUA)
      if redis.call('GET', KEYS[1]) == ARGV[1] then
        return redis.call('DEL', KEYS[1])
      end
      return 0
    LUA

    # Looks for a job by jid in a slice of a queue, so a lookup doesn't
    # copy whole queues out of Redis. Entries are checked from the tail
    # (next to run) backwards; a cheap substring test comes before decoding.
    #
    # KEYS: queue list
    # ARGV: jid, start index, stop index (negative: counted from the tail)
    # Returns the job's JSON (or false) and the queue's length.
    FIND_JID = Redis::Script.new(<<~LUA)
      local items = redis.call('LRANGE', KEYS[1], ARGV[2], ARGV[3])
      local needle = '"' .. ARGV[1] .. '"'
      for i = #items, 1, -1 do
        local raw = items[i]
        if string.find(raw, needle, 1, true) then
          local ok, job = pcall(cjson.decode, raw)
          if ok and type(job) == 'table' and job['jid'] == ARGV[1] then
            return {raw, redis.call('LLEN', KEYS[1])}
          end
        end
      end
      return {false, redis.call('LLEN', KEYS[1])}
    LUA

    # Deletes the jobs of one class from a slice of a queue. The class is
    # the one the dashboard shows: display_class when set (an ActiveJob's
    # own class), else class.
    #
    # KEYS: queue list
    # ARGV: class name, start index, stop index (negative: from the tail)
    # Returns how many jobs it deleted and the queue's length after.
    DELETE_CLASS = Redis::Script.new(<<~LUA)
      local items = redis.call('LRANGE', KEYS[1], ARGV[2], ARGV[3])
      local needle = '"' .. ARGV[1] .. '"'
      local deleted = 0
      for i = #items, 1, -1 do
        local raw = items[i]
        if string.find(raw, needle, 1, true) then
          local ok, job = pcall(cjson.decode, raw)
          if ok and type(job) == 'table' then
            local name = job['display_class']
            if type(name) ~= 'string' then name = job['class'] end
            if name == ARGV[1] then
              deleted = deleted + redis.call('LREM', KEYS[1], -1, raw)
            end
          end
        end
      end
      return {deleted, redis.call('LLEN', KEYS[1])}
    LUA

    # The dashboard's counts: processed, failed, the schedule's, retry
    # set's and dead set's sizes, the default queue's oldest job (false
    # when empty), the queues and their sizes, and every live process's
    # busy count.
    #
    # KEYS: queues set, processed and failed counters, schedule, retry and
    # dead sets, processes set
    # ARGV: queue key prefix ("<prefix>queue:"), process key prefix
    STATS = Redis::Script.new(<<~LUA)
      local queues = redis.call('SMEMBERS', KEYS[1])
      local sizes = {}
      for i, queue in ipairs(queues) do sizes[i] = redis.call('LLEN', ARGV[1] .. queue) end
      local busy = {}
      for _, identity in ipairs(redis.call('SMEMBERS', KEYS[7])) do
        -- A process that died recently may still be listed without a hash.
        local count = redis.call('HGET', ARGV[2] .. identity, 'busy')
        if count then busy[#busy + 1] = count end
      end
      return {redis.call('GET', KEYS[2]), redis.call('GET', KEYS[3]), redis.call('ZCARD', KEYS[4]),
        redis.call('ZCARD', KEYS[5]), redis.call('ZCARD', KEYS[6]), redis.call('LINDEX', ARGV[1] .. 'default', -1),
        queues, sizes, busy}
    LUA

    # The hash of each member of a set: member, its hash's fields and
    # values (as HGETALL gives them), member, ... The hash of member m is
    # at ARGV[1] .. m .. ARGV[2].
    #
    # KEYS: the set
    MEMBER_HASHES = Redis::Script.new(<<~LUA)
      local found = {}
      for _, member in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        found[#found + 1] = member
        found[#found + 1] = redis.call('HGETALL', ARGV[1] .. member .. ARGV[2])
      end
      return found
    LUA

    # The hash of each member of +set+, in one round trip: [member, hash]
    # pairs, by member. Member m's hash is at +prefix+, m, +suffix+.
    def self.member_hashes(config, set, prefix, suffix = "")
      config.redis { |c| c.evalsha(MEMBER_HASHES, [set], [prefix, suffix]) }
        .each_slice(2).map { |member, row| [member, row.each_slice(2).to_h] }.sort_by(&:first)
    end

    # Raises hash fields to the given values if they are larger.
    #
    # KEYS: hash, ARGV: ttl seconds, field1, value1, field2, value2...
    HMAX = Redis::Script.new(<<~LUA)
      for i = 2, #ARGV, 2 do
        local cur = tonumber(redis.call('HGET', KEYS[1], ARGV[i]) or '-1')
        if tonumber(ARGV[i + 1]) > cur then
          redis.call('HSET', KEYS[1], ARGV[i], ARGV[i + 1])
        end
      end
      redis.call('EXPIRE', KEYS[1], ARGV[1])
      return 1
    LUA
  end
end
