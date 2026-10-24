# frozen_string_literal: true

module Robin
  # Moves due jobs from the schedule and retry sets onto their queues.
  #
  # Every server process runs one. The poll interval is randomized and
  # scaled by the number of live processes, so the cluster as a whole
  # checks about once every +poll_interval+ seconds no matter how many
  # processes there are.
  #
  # Each poll also learns when the next job is due. The cluster's leader
  # wakes up for it, if that's sooner than its next poll, so jobs known
  # ahead start on time rather than up to a poll late. Only the leader
  # does, so the cluster doesn't wake up as one. Jobs scheduled since the
  # last poll for sooner than the next known one wait for a poll.
  class Scheduler
    BATCH = 500
    SETS = %w[schedule retry].freeze

    # The least the leader sleeps between polls (seconds), so a steady
    # stream of jobs coming due costs at most 100 polls a second.
    MIN_WAIT = 0.01

    def initialize(config)
      @config = config
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      # Each set's earliest score (epoch seconds) as of its last poll, or
      # nil if it was empty.
      @next = {}
    end

    def start
      @thread = Thread.new do
        Thread.current.name = "robin.scheduler"
        sleep_for(rand * @config.poll_interval) # stagger process startup
        until @done
          begin
            enqueue_due
          rescue => e
            @config.handle_exception(e, {context: "scheduler"})
          end
          sleep_for(interval)
        end
      end
      self
    end

    def stop
      @done = true
      @mutex.synchronize { @cond.signal }
      @thread&.join(2)
    end

    # Enqueues all currently due jobs. Returns the number moved.
    #
    # One round trip covers both sets (and counts the live processes for
    # #interval); a set that filled a whole batch is drained with more.
    def enqueue_due(now = Robin.now_ms)
      @config.redis do |conn|
        sets = SETS
        total = 0
        until sets.empty?
          *replies, @processes = conn.pipelined do |p|
            sets.each do |set|
              p.evalsha(Scripts::ENQUEUE_DUE, [@config.key(set), @config.key("queues")],
                [Robin.epoch_seconds(now), "#{@config.key("queue")}:", BATCH, now])
            end
            p.call("SCARD", @config.key("processes"))
          end
          sets.zip(replies) { |set, (_, score)| @next[set] = score && Float(score) }
          moved = replies.map { |count, _score| count }
          total += moved.sum
          sets = @done ? [] : sets.zip(moved).filter_map { |set, n| set if n.equal?(BATCH) }
        end
        total
      end
    end

    # When the next job of either set is due (epoch seconds), as of the
    # last poll; nil if both were empty.
    def next_due = @next.values.compact.min

    # Seconds until the next poll: about +poll_interval+ times the live
    # processes as last counted by #enqueue_due (one if it never got an
    # answer), or, for the leader, until the next job is due if sooner.
    def interval
      poll = @config.poll_interval * [@processes.to_i, 1].max * (0.5 + rand)
      due = next_due
      return poll unless due && Leader.leader?(@config)

      wait = [due - Robin.epoch_seconds(Robin.now_ms), MIN_WAIT].max
      [wait, poll].min
    end

    private

    def sleep_for(seconds)
      @mutex.synchronize { @cond.wait(@mutex, seconds) unless @done }
    end
  end
end
