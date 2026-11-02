# frozen_string_literal: true

module Robin
  # Reliable fetch: jobs are atomically moved from their queue into an
  # in-flight key of their process and only removed from it once they
  # finish (successfully, or after being recorded for retry). If a process
  # crashes or is killed, Robin::Recovery puts its in-flight jobs back.
  #
  # Each in-flight job has a key of its own, inflight:<identity>:<n>,
  # registered in the process's in-flight set (inflight:<identity>) before
  # a job is first moved into it. So a job is acknowledged (or put back)
  # by its key: its payload only ever travels from Redis to the process,
  # once. The key of an acknowledged job is used again once its
  # acknowledgement has gone through, so keys are registered once, not
  # for every job.
  class Fetcher
    # A fetched job.
    class UnitOfWork
      # +key+ is the job's in-flight key.
      attr_reader :queue, :raw, :fetcher, :key

      def initialize(queue, raw, fetcher, key)
        @queue = queue
        @raw = raw
        @fetcher = fetcher
        @key = key
      end

      # Removes the job from its in-flight key, right away or as part of
      # +conn+ (a pipeline or transaction). The key is retired with it.
      def acknowledge(conn = nil)
        return fetcher.config.redis { |c| c.pipelined { |p| acknowledge(p) } } unless conn

        fetcher.retire(conn, key)
      end

      # Puts the job back on the front of its queue.
      def requeue = fetcher.config.redis { |c| fetcher.put_back(c, [self]) }
    end

    # Seconds a job fetched for another worker may wait for one before
    # it goes back on its queue (checked every heartbeat), so jobs fetched
    # just before every worker got busy with long jobs can run elsewhere.
    STALE = 1

    # Seconds a finished job's acknowledgement waits for a round trip to
    # take it before a thread of the launcher sends it (see #acker). Under
    # load, a round trip comes sooner; but a worker that takes a job
    # fetched for it makes none, and long jobs can keep every worker busy.
    # A job finished but not yet acknowledged when its process crashes
    # runs again, so this bounds how long before a crash such a job may
    # have finished.
    ACK_WAIT = 0.002

    # Jobs larger than this (in bytes, judged by the first job of the last
    # round trip) make a batch from a single queue cheaper to take with
    # plain commands than with the script (see #take_from).
    LARGE = 2048

    @minted = 0
    @minting = Mutex.new

    # A number for a new in-flight key. They're unique within the process,
    # whichever capsule's fetcher uses them, as they share its in-flight
    # set.
    def self.mint = @minting.synchronize { @minted += 1 }

    attr_reader :config, :capsule, :inflight_key
    attr_accessor :paused

    # A queue the fetcher puts itself on when acknowledgements are left
    # waiting, once until #send_acks takes them: the launcher's thread pops
    # it, waits ACK_WAIT and calls #send_acks.
    attr_accessor :acker

    def initialize(capsule, identity)
      @capsule = capsule
      @config = capsule.config
      @inflight_key = config.key("inflight", identity)
      @paused_key = config.key("paused")
      @paused = []
      @lock = Mutex.new
      # [UnitOfWork, fetched at] for jobs fetched for other workers, oldest
      # first.
      @buffer = []
      # In-flight keys of finished jobs waiting to be acknowledged with the
      # next round trip, and (by thread) those being acknowledged in one
      # now.
      @acks = []
      @sending = {}
      @acker = Thread::Queue.new
      # In-flight keys known to be empty, and (by thread) those a round
      # trip is filling now.
      @free = []
      @filling = {}
      # Keys the sweep took over (see #forget), as hash keys.
      @lost = {}
      # Were the jobs of the last round trip large (see LARGE)?
      @large = false
      # Workers inside #fetch without a job yet.
      @wanting = 0
      # Workers (threads, as hash keys) that last waited on their capsule's
      # only queue and got nothing (see #fetch).
      @idle = {}
    end

    # Returns the next UnitOfWork, or nil after waiting briefly with no
    # work available. +ack+ is the in-flight key of the worker's last
    # finished job: it's acknowledged with the next round trip, or by
    # #send_acks (once it's passed in, it's the fetcher's to acknowledge).
    #
    # A round trip takes a job for every worker of the capsule fetching at
    # the same time, up to config.fetch_batch; the extras go to the next
    # workers to ask, without a round trip. They stay in flight meanwhile,
    # so a crash loses nothing. With nothing to take, the worker blocks on
    # a queue: +slot+ spreads idle workers across queues so every queue has
    # one blocked on it, giving instant pickup.
    def fetch(slot = 0, ack: nil)
      reserved = @lock.synchronize do
        @acks << ack if ack
        unit, = @buffer.shift
        if unit
          wake_acker unless @acks.empty?
          return unit
        end
        # A worker that just waited on its capsule's only queue for
        # nothing waits again: a round trip would find nothing there
        # either that blocking on it doesn't. (It finished no job, so it
        # has nothing to acknowledge.)
        unless @idle.delete(Thread.current)
          @wanting += 1
          [take_acks, reserve([@wanting, config.fetch_batch].min)]
        end
      end #: [Array[String], [Array[String], Array[String]]]?
      return wait(slot, capsule.queue_order) unless reserved

      acks, (keys, minted) = reserved

      begin
        order = capsule.queue_order
        units, unused = take(order, acks, keys, minted)
      ensure
        @lock.synchronize do
          @wanting -= 1
          @sending.delete(Thread.current)
          settle(unused)
          if units
            free(acks)
            keep(units.drop(1))
          else
            @acks.concat(acks) # for the next round trip
            wake_acker unless @acks.empty?
          end
        end
      end
      units.first || wait(slot, order)
    end

    # Called every heartbeat with the paused queues (the heartbeat reads
    # them once for every capsule): takes the jobs fetched for other
    # workers that are from a queue paused since, or that no worker took
    # within STALE seconds. The heartbeat hands back every capsule's in one
    # transaction (see #hand_back), then frees their keys (#freed).
    def stale(paused)
      @paused = paused
      cutoff = monotonic - STALE
      @lock.synchronize do
        back, @buffer = @buffer.partition { |unit, at| at < cutoff || @paused.include?(unit.queue) }
        back.map(&:first)
      end
    end

    # Frees the keys of jobs handed back.
    def freed(units) = free_keys(units.map(&:key))

    # Acknowledges the finished jobs waiting for a round trip, if any, in
    # one of its own (see ACK_WAIT). If that fails, they wait again, for a
    # round trip or for a worker to leave more waiting.
    def send_acks
      acks = @lock.synchronize do
        @ack_queued = false
        take_acks unless @acks.empty?
      end
      return unless acks

      begin
        config.redis { |conn| conn.call("DEL", *acks) }
        sent = true
      ensure
        @lock.synchronize do
          @sending.delete(Thread.current)
          sent ? free(acks) : @acks.concat(acks)
        end
      end
    end

    # In-flight keys this fetcher is responsible for: free ones, ones
    # being filled, those of jobs fetched but not handed out yet, and those
    # of finished jobs not acknowledged yet.
    def held = @lock.synchronize { holding }

    # Lets go of +key+, found sitting unheld with the same job (or none) in
    # it on two sweeps, so its job can be put back: it won't be used again
    # (were it acknowledged after all). False if it's held now.
    def forget(key)
      @lock.synchronize do
        held = holding.include?(key)
        @lost[key] = true unless held
        !held
      end
    end

    # Queues on +conn+ (a pipeline or transaction) the removal of the job
    # in +key+: the key is deleted and unregistered, and never used again
    # (so it can't be filled while its deletion may still be pending).
    def retire(conn, key)
      conn.call("DEL", key)
      conn.call("SREM", @inflight_key, key)
    end

    # Puts jobs (units of work) back on the front of their queues, the
    # first one first in line, and frees their keys; returns nil.
    def put_back(conn, units)
      send_back(conn, units)
      freed(units)
      nil
    end

    # Puts the jobs fetched but not handed out back on their queues, and
    # acknowledges the finished ones, e.g. when the workers stop: in one
    # transaction.
    def release
      units, acks = @lock.synchronize do
        taken = [@buffer.map(&:first), @acks] #: [Array[UnitOfWork], Array[String]]
        @buffer = []
        @acks = []
        taken
      end
      return if units.empty? && acks.empty?

      config.redis do |conn|
        conn.multi do |tx|
          hand_back(tx, units)
          tx.call("DEL", *acks) unless acks.empty?
        end
      end
      free_keys(units.map(&:key) + acks)
    end

    # Queues on +tx+ (a transaction) the commands moving jobs (units of
    # work) back from their in-flight keys onto the front of their queues,
    # the first one first in line. The caller frees their keys once it's
    # sent (see #freed).
    def hand_back(tx, units)
      units.reverse_each { |unit| tx.call("LMOVE", unit.key, config.key("queue", unit.queue), "RIGHT", "RIGHT") }
    end

    # Acknowledges the finished jobs in +keys+ in one round trip, then
    # frees the keys.
    def acknowledge(conn, keys)
      return if keys.empty?

      conn.call("DEL", *keys)
      free_keys(keys)
    end

    private

    # With the lock held: puts the fetcher on the acker queue, unless it's
    # there already (@ack_queued, until #send_acks).
    def wake_acker
      return if @ack_queued

      @ack_queued = true
      @acker << self
    end

    # With the lock held: takes the waiting acknowledgements for this
    # thread to send.
    def take_acks
      acks = @sending[Thread.current] = @acks
      @acks = []
      acks
    end

    # With the lock held: buffers +units+ for other workers.
    def keep(units)
      at = monotonic
      units.each { |unit| @buffer << [unit, at] }
    end

    # With the lock held: +count+ in-flight keys for this thread's round
    # trip to fill, free ones first, and the ones among them just minted
    # (the round trip registers them before filling them).
    def reserve(count)
      keys = @free.pop(count)
      minted = (keys.size...count).map { "#{@inflight_key}:#{Fetcher.mint}" }
      @filling[Thread.current] = keys.concat(minted)
      [keys, minted]
    end

    # With the lock held, once this thread's round trip is over: the keys
    # it didn't fill (+unused+) are free (they're empty). After a failure
    # (no +unused+) the round trip may have filled any of its keys without
    # the reply getting here, so they're let go of instead: the sweep puts
    # back whatever reached them (see Launcher#sweep_inflight).
    def settle(unused)
      @filling.delete(Thread.current)
      free(unused) if unused
    end

    # With the lock held: +keys+ are empty, so they can be filled again,
    # unless the sweep took them over.
    def free(keys)
      keys.each { |key| @free << key unless @lost.delete(key) }
    end

    # Frees +keys+, taking the lock.
    def free_keys(keys) = @lock.synchronize { free(keys) }

    # With the lock held: the keys this fetcher is responsible for right
    # now (see #held).
    def holding = @free + @filling.values.flatten + @buffer.map { |unit, _at| unit.key } + @acks + @sending.values.flatten

    # Acknowledges +acks+ and fills +keys+ with up to as many jobs; returns
    # the units of work and the keys left unused.
    def take(order, acks, keys, minted)
      units, unused = config.redis do |conn|
        if order.size == 1 && !@paused.include?(order.first) && (keys.size == 1 || @large)
          take_from(conn, order.first, acks, keys, minted)
        else
          script_keys = [@paused_key, *keys, *order.map { |q| config.key("queue", q) }, *acks]
          argv = [keys.size, *order]
          taken = if minted.empty?
            conn.evalsha(Scripts::FETCH, script_keys, argv)
          else
            conn.pipelined do |p|
              register(p, minted)
              p.evalsha(Scripts::FETCH, script_keys, argv)
            end.last
          end
          unused = keys.dup # filled in order
          [taken.each_slice(2).map { |queue, raw| UnitOfWork.new(queue, raw, self, unused.shift) }, unused]
        end
      end
      @large = units.first.raw.bytesize > LARGE unless units.empty?
      [units, unused]
    end

    # Scripts::FETCH for a single queue, as plain commands in one round
    # trip. For one job, Redis runs them faster than the script. For
    # several, they cost a command each, but the script copies every job
    # into Lua and back out, which costs more once jobs are large. Jobs
    # taken from a queue paused since the last refresh go straight back.
    def take_from(conn, queue, acks, keys, minted)
      source = config.key("queue", queue)
      replies = conn.pipelined do |p|
        p.call("DEL", *acks) unless acks.empty?
        register(p, minted)
        p.call("SISMEMBER", @paused_key, queue)
        keys.each { |key| p.call("LMOVE", source, key, "RIGHT", "LEFT") }
      end
      paused, *raws = replies.last(keys.size + 1)
      received(conn, queue, paused, raws, keys)
    end

    # Queues the registration of newly minted in-flight keys, ahead of the
    # commands that fill them.
    def register(pipe, minted)
      pipe.call("SADD", @inflight_key, *minted) unless minted.empty?
    end

    # The units for the jobs (+raws+, nil where there was nothing to take)
    # a round trip moved from +queue+ into +keys+, and the keys left
    # unused; all of them, the jobs handed straight back, if +paused+ (1)
    # says the queue was paused meanwhile.
    def received(conn, queue, paused, raws, keys)
      units = [] #: Array[UnitOfWork]
      unused = [] #: Array[String]
      # (raws and keys are the same size, so key is never nil.)
      raws.zip(keys) do |raw, key|
        if raw
          units << UnitOfWork.new(queue, raw, self, key) # steep:ignore ArgumentTypeMismatch
        else
          unused << key # steep:ignore ArgumentTypeMismatch
        end
      end
      return [units, unused] unless paused == 1

      send_back(conn, units)
      [[], keys]
    end

    # Blocks for up to config.fetch_timeout for the next job, unless
    # another worker fetched one for this one meanwhile.
    def wait(slot, order)
      active = order - @paused
      reserved = @lock.synchronize do
        unit, = @buffer.shift
        return unit if unit

        reserve(1) unless active.empty?
      end #: [Array[String], Array[String]]?

      wait = config.fetch_timeout
      unless reserved
        sleep wait
        return
      end

      keys, minted = reserved
      queue = active.fetch(slot % active.size)
      begin
        units, unused = config.redis do |conn|
          # The queue may have been paused while we were blocked: Redis runs
          # the SISMEMBER once the BLMOVE returns, so it answers for the
          # moment the job came, without a round trip of its own.
          raw, paused = conn.pipelined(timeout: wait) do |p|
            register(p, minted)
            p.call("BLMOVE", config.key("queue", queue), keys.first, "RIGHT", "LEFT", wait)
            p.call("SISMEMBER", @paused_key, queue)
          end.last(2)
          received(conn, queue, paused, [raw], keys)
        end
      ensure
        @lock.synchronize do
          settle(unused)
          @idle[Thread.current] = true if units&.empty? && order.size == 1
        end
      end
      units.first
    end

    # Hands back +units+ (see #hand_back) in a transaction of their own.
    def send_back(conn, units)
      conn.multi { |tx| hand_back(tx, units) } unless units.empty?
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
