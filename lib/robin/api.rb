# frozen_string_literal: true

module Robin
  # Read and manage everything Robin keeps in Redis. Every class takes an
  # optional +config:+ so the web UI can point at several clusters.
  #
  #   Robin::Stats.new.processed
  #   Robin::Queue.new("default").each { |job| job.delete if job.args == [42] }
  #   Robin::RetrySet.new.retry_all
  #   Robin::ProcessSet.new.each(&:quiet!)
  class Stats
    def initialize(config: Robin.config)
      @config = config
      fetch
    end

    attr_reader :processed, :failed, :scheduled_size, :retry_size, :dead_size,
      :processes_size, :workers_size, :enqueued, :queues, :default_queue_latency

    # Reads them all, in one round trip.
    def fetch
      c = @config
      keys = [c.key("queues"), c.key("stat", "processed"), c.key("stat", "failed"), c.key("schedule"), c.key("retry"),
        c.key("dead"), c.key("processes")]
      processed, failed, @scheduled_size, @retry_size, @dead_size, oldest, queues, sizes, busy =
        c.redis { |r| r.evalsha(Scripts::STATS, keys, ["#{c.key("queue")}:", c.key_prefix]) }
      @processed = processed.to_i
      @failed = failed.to_i
      @default_queue_latency = Queue.latency_of(oldest)
      @queues = queues.zip(sizes).sort_by { |q, n| [-n, q] }.to_h
      @enqueued = @queues.values.sum
      @processes_size = busy.size
      @workers_size = busy.sum(&:to_i)
      self
    end

    def to_h
      {"processed" => processed, "failed" => failed, "scheduled" => scheduled_size, "retries" => retry_size,
       "dead" => dead_size, "processes" => processes_size, "busy" => workers_size, "enqueued" => enqueued,
       "default_latency" => default_queue_latency}
    end

    # Daily processed/failed counts for the last +days+ days.
    def history(days: 30, now: Time.now)
      dates = (0...days).map { |i| (now.getutc - i * 86_400).strftime("%Y-%m-%d") }
      c = @config
      processed, failed = c.redis do |r|
        r.pipelined do |p|
          p.call("MGET", *dates.map { |d| c.key("stat", "processed", d) })
          p.call("MGET", *dates.map { |d| c.key("stat", "failed", d) })
        end
      end #: Array[untyped]
      {"processed" => dates.zip(processed.map(&:to_i)).to_h, "failed" => dates.zip(failed.map(&:to_i)).to_h}
    end

    def reset(*names)
      names = %w[processed failed] if names.empty?
      @config.redis { |r| r.call("DEL", *names.map { |n| @config.key("stat", n) }) }
    end
  end

  class Queue
    include Enumerable

    PAGE = 100
    FIND_SLICE = 5_000

    def self.all(config: Robin.config)
      config.redis { |c| c.call("SMEMBERS", config.key("queues")) }.sort.map { |n| new(n, config: config) }
    end

    # Seconds the oldest job in a queue has been waiting.
    def self.latency_of(raw, now = Robin.now_ms)
      return 0.0 unless raw

      since = JobRecord.new(raw).waiting_since
      # (since is an Integer or a Float; Steep picks neither of Integer#-'s overloads.)
      since ? [(now - since) / 1000.0, 0.0].max : 0.0 # steep:ignore UnresolvedOverloading
    end

    attr_reader :name

    def initialize(name = "default", config: Robin.config)
      @name = name.to_s
      @config = config
      @key = config.key("queue", @name)
    end

    def size = @config.redis { |c| c.call("LLEN", @key) }

    def latency = Queue.latency_of(@config.redis { |c| c.call("LINDEX", @key, -1) })

    def paused? = @config.redis { |c| c.call("SISMEMBER", @config.key("paused"), name) } == 1

    def pause! = @config.redis { |c| c.call("SADD", @config.key("paused"), name) }

    def unpause! = @config.redis { |c| c.call("SREM", @config.key("paused"), name) }

    def self.paused(config: Robin.config) = config.redis { |c| c.call("SMEMBERS", config.key("paused")) }

    # Jobs from next-to-run to most recently pushed.
    def each
      return to_enum unless block_given?

      offset = 0
      last_size = nil #: Integer?
      loop do
        current, page = @config.redis do |c|
          c.pipelined do |p|
            p.call("LLEN", @key)
            p.call(*page_command(offset))
          end
        end #: Array[untyped]
        # Jobs removed since the last page (by the block, or by workers taking
        # them) shift the tail; step back so none are skipped (reading the
        # page again).
        back = [last_size - current, offset].min if last_size
        if back&.positive?
          offset -= back
          page = @config.redis { |c| c.call(*page_command(offset)) }
        end
        last_size = current
        break if page.empty?

        page.reverse_each { |raw| yield record(raw) }
        offset += PAGE
      end
    end

    # A page of jobs: page 1 holds the jobs that will run next.
    def page(number, per_page: 25)
      start = -(number * per_page)
      stop = -((number - 1) * per_page) - 1
      raws = @config.redis { |c| c.call("LRANGE", @key, start, stop) }
      raws.reverse.map { |raw| record(raw) }
    end

    # Finds a job by jid, searching the queue inside Redis a slice at a
    # time (next to run first). Jobs moving while it searches may be missed.
    def find_job(jid)
      offset = 0
      loop do
        stop = -1 - offset
        raw, length = @config.redis { |c| c.evalsha(Scripts::FIND_JID, [@key], [jid, stop - FIND_SLICE + 1, stop]) }
        return record(raw) if raw

        offset += FIND_SLICE
        return if offset >= length
      end
    end

    # Deletes every job of class +klass+ (as the dashboard names it, so an
    # ActiveJob's own class), searching the queue inside Redis a slice at
    # a time. Returns how many it deleted. Jobs moving while it searches
    # may be missed.
    def delete_by_class(klass)
      name = klass.to_s
      raise ArgumentError, "a class name is required" if name.empty?

      deleted = offset = 0
      loop do
        stop = -1 - offset
        removed, length = @config.redis { |c| c.evalsha(Scripts::DELETE_CLASS, [@key], [name, stop - FIND_SLICE + 1, stop]) }
        deleted += removed
        # What the slice lost, the jobs beyond it moved up to fill.
        offset += FIND_SLICE - removed
        return deleted if offset >= length
      end
    end

    # Deletes +jobs+ (JobRecords read from this queue), in one round trip;
    # returns how many it deleted.
    def delete_jobs(jobs)
      @config.redis { |c| c.pipelined { |p| jobs.each { |job| p.call("LREM", @key, 1, job.value) } } }.sum
    end

    def clear
      @config.redis do |c|
        c.multi do |tx|
          tx.call("UNLINK", @key)
          tx.call("SREM", @config.key("queues"), name)
          tx.call("SREM", @config.key("paused"), name)
        end
      end
      true
    end
    alias_method :delete, :clear

    # In one round trip.
    def to_h
      size, oldest, paused = @config.redis do |c|
        c.pipelined do |p|
          p.call("LLEN", @key)
          p.call("LINDEX", @key, -1)
          p.call("SISMEMBER", @config.key("paused"), name)
        end
      end #: Array[untyped]
      {"name" => name, "size" => size, "latency" => Queue.latency_of(oldest), "paused" => paused == 1}
    end

    private

    # The list grows at the head; pages are read from the tail.
    def page_command(offset)
      stop = -1 - offset
      ["LRANGE", @key, stop - PAGE + 1, stop]
    end

    # A job read from the queue (subclasses may return their own kind).
    def record(raw) = JobRecord.new(raw, name, config: @config)
  end

  # A job as stored in Redis.
  class JobRecord
    attr_reader :item, :value, :queue

    def initialize(value, queue = nil, config: Robin.config)
      @config = config
      if value.instance_of?(Hash)
        @item = value
        @value = Robin.dump_json(value)
      else
        @item = parse(value)
        @value = value
      end
      @queue = queue || self["queue"]
    end

    def [](key) = @item[key]

    def klass = self["class"]

    # The class users care about (unwraps ActiveJob).
    def display_class = Robin.display_class(@item)

    def args = self["args"]

    def display_args
      return Encryption.visible_args(@item) if self["encrypted"]
      return args.first.fetch("arguments") if self["wrapped"] && args&.first.instance_of?(Hash)

      args
    end

    def jid = self["jid"]

    def bid = self["bid"]

    def tags = Array(self["tags"])

    def error_class = self["error_class"]

    def error_message = self["error_message"]

    # The backtrace stored with the last failure (see Retrier.pack_backtrace).
    def error_backtrace = Retrier.unpack_backtrace(self["error_backtrace"])

    # How many times the job has failed (its retry_count counts from 0).
    def failures = self["retry_count"] ? Integer(self["retry_count"]) + 1 : 0

    def created_at = ms_time(self["created_at"])

    def enqueued_at = ms_time(self["enqueued_at"])

    def failed_at = ms_time(self["failed_at"])

    def retried_at = ms_time(self["retried_at"])

    # Epoch ms since when the job has been ready to run: the later of when
    # it was pushed and when it was scheduled for.
    def waiting_since = [Robin.ms_of(self["enqueued_at"]), self["at"] && Robin.epoch_ms(self["at"])].compact.max

    def latency = Queue.latency_of(value)

    def delete
      @config.redis { |c| c.call("LREM", @config.key("queue", queue), 1, value) } == 1
    end

    def to_h
      {"jid" => jid, "class" => klass, "display_class" => display_class, "args" => display_args, "queue" => queue,
       "item" => (self["encrypted"] ? @item.merge({"args" => Encryption.visible_args(@item)}) : @item)}
    end

    private

    def ms_time(time) = time && Time.at(Rational(Robin.ms_of(time), 1000))

    def parse(raw)
      Robin.load_json(raw)
    rescue JSON::ParserError
      {"class" => "<unparseable>", "args" => [], "raw" => raw}
    end
  end

  # A job in the schedule, retry or dead set.
  class SortedEntry < JobRecord
    attr_reader :score, :parent

    def initialize(parent, score, value)
      @parent = parent
      @score = score.to_f
      super(value, config: parent.config)
    end

    # When the job is due (or, in the dead set, died).
    def at = Time.at(Rational(Robin.epoch_ms(score), 1000))

    def id = "#{score}-#{jid}"

    def delete = parent.delete_entry(self)

    # Push the job onto its queue now.
    def add_to_queue
      remove_and { Client.new(config: @config).push(queued_item) }
    end
    alias_method :retry!, :add_to_queue

    # The job without its time in the set, as it's pushed again or killed.
    def bare_item = @item.except("at", "enqueued_at")

    # The job #add_to_queue pushes.
    def queued_item = bare_item

    def reschedule(at)
      score = Robin.epoch_seconds(Client.timestamp_ms(at))
      @config.redis do |c|
        c.multi do |tx|
          tx.call("ZREM", parent.key, value)
          tx.call("ZADD", parent.key, score, Robin.dump_json(@item.except("at")))
        end
      end
    end

    def kill!
      remove_and { |item| DeadSet.new(config: @config).kill(Robin.dump_json(item)) }
    end

    def to_h = super.merge({"score" => score, "at" => score, "id" => id, "set" => parent.name})

    private

    # Remove first so concurrent actions can't duplicate the job.
    def remove_and
      return false unless @config.redis { |c| c.call("ZREM", parent.key, value) } == 1

      yield bare_item
      true
    end
  end

  class JobSet
    include Enumerable

    PAGE = 100

    attr_reader :name, :key, :config

    def initialize(name, config: Robin.config)
      @name = name
      @config = config
      @key = config.key(name)
    end

    def size = @config.redis { |c| c.call("ZCARD", key) }

    def clear = @config.redis { |c| c.call("UNLINK", key) }

    # Adds a job (a payload hash or its JSON) due at +at+ (anything
    # Client.timestamp_ms takes).
    def schedule(at, payload)
      raw = payload.instance_of?(String) ? payload : Robin.dump_json(payload.except("at"))
      @config.redis { |c| c.call("ZADD", key, Robin.epoch_seconds(Client.timestamp_ms(at)), raw) }
    end

    # Iterates by score: soonest first, or latest first with +reverse+.
    def each(reverse: false)
      return to_enum(:each, reverse: reverse) unless block_given?

      offset = 0
      last_size = nil #: Integer?
      loop do
        current, raw = @config.redis do |c|
          c.pipelined do |p|
            p.call("ZCARD", key)
            p.call(*range_command(offset, PAGE, reverse))
          end
        end #: Array[untyped]
        # Entries removed since the last page (e.g. by the block) shift the
        # ranks; step back so none are skipped (reading the page again).
        back = [last_size - current, offset].min if last_size
        if back&.positive?
          offset -= back
          raw = @config.redis { |c| c.call(*range_command(offset, PAGE, reverse)) }
        end
        last_size = current
        entries = entries_from(raw)
        break if entries.empty?

        entries.each { |entry| yield entry }
        offset += PAGE
      end
    end

    def page(number, per_page: 25, reverse: false)
      range((number - 1) * per_page, per_page, reverse)
    end

    # A #page and the set's size, in one round trip.
    def page_and_size(number, per_page:, reverse:)
      raw, size = @config.redis do |c|
        c.pipelined do |p|
          p.call(*range_command((number - 1) * per_page, per_page, reverse))
          p.call("ZCARD", key)
        end
      end #: Array[untyped]
      [entries_from(raw), size]
    end

    # Finds entries whose JSON contains +term+ using ZSCAN (server-side
    # glob match, so it's fast even for large sets). Returns up to +limit+
    # matches, soonest first.
    def scan(term, limit: 500)
      return [] if term.to_s.empty?

      pattern = "*#{term.to_s.gsub(/[\\*?\[\]]/) { |m| "\\#{m}" }}*"
      results = [] #: Array[SortedEntry]
      cursor = "0"
      @config.redis do |c|
        loop do
          cursor, pairs = c.call("ZSCAN", key, cursor, "MATCH", pattern, "COUNT", 1000)
          pairs.each_slice(2) { |value, score| results << entry(score, value) }
          break if cursor == "0" || results.size >= limit
        end
      end
      results.first(limit).sort_by(&:score)
    end

    def find_job(jid)
      scan(jid).find { |e| e.jid == jid }
    end

    # Fetch entries with exactly this score (and optionally jid).
    def fetch(score, jid = nil)
      raw = @config.redis { |c| c.call("ZRANGE", key, score, score, "BYSCORE", "WITHSCORES") }
      entries = raw.each_slice(2).map { |value, s| entry(s, value) }
      jid ? entries.select { |e| e.jid == jid } : entries
    end

    # Look up by the "<score>-<jid>" ids used in the web UI.
    def find_by_id(id)
      score, jid = id.split("-", 2)
      fetch(score, jid).first
    end

    def delete_entry(entry)
      @config.redis { |c| c.call("ZREM", key, entry.value) } == 1
    end

    def delete_by_jid(score, jid)
      fetch(score, jid).each(&:delete).any?
    end

    # Looks up several "<score>-<jid>" ids in one round trip; returns the
    # entries found.
    def find_all_by_id(ids)
      wanted = ids.map { |id| id.split("-", 2) }
      rows = @config.redis { |c| c.pipelined { |p| wanted.each { |score, _jid| p.call("ZRANGE", key, score, score, "BYSCORE", "WITHSCORES") } } }
      wanted.zip(rows).flat_map do |(_score, jid), raw|
        raw.each_slice(2).map { |value, score| entry(score, value) }.select { |e| e.jid == jid }
      end
    end

    # Removes +entries+ (the ones still in the set), in one round trip,
    # and returns those it removed: removed first, so concurrent actions
    # can't duplicate a job.
    def take(entries)
      removed = @config.redis { |c| c.pipelined { |p| entries.each { |e| p.call("ZREM", key, e.value) } } }
      entries.zip(removed).filter_map { |entry, gone| entry if gone == 1 }
    end

    # Deletes +entries+ in one round trip; returns how many.
    def delete_entries(entries) = take(entries).size

    # Pushes +entries+ onto their queues now (as SortedEntry#add_to_queue
    # does), in two round trips; returns how many.
    def retry_entries(entries)
      taken = take(entries)
      Client.together { taken.each { |entry| Client.new(config: @config).push(entry.queued_item) } }
      taken.size
    end

    # Moves +entries+ to the dead set (as SortedEntry#kill! does), in two
    # round trips; returns how many.
    def kill_entries(entries)
      taken = take(entries)
      dead = DeadSet.new(config: @config)
      @config.redis { |c| c.multi { |tx| taken.each { |e| dead.queue_kill(tx, Robin.dump_json(e.bare_item), nil) } } } unless taken.empty?
      taken.size
    end

    # Yields the entries that are in the set now, soonest first, to a
    # block that removes each one (retry!, kill!, delete) and returns
    # truthy if it did. Unlike #each, this never holds the whole set in
    # memory, and it ignores entries added meanwhile. Returns how many the
    # block removed.
    def drain(&) = drain_pages { |page| page.count(&) }

    # Like #drain, a page at a time: the block gets a page of entries,
    # removes them (e.g. with #retry_entries) and returns how many it did.
    def drain_pages
      removed = 0
      kept = 0
      remaining = size
      while remaining.positive?
        page = range(kept, [PAGE, remaining].min, false)
        break if page.empty?

        done = yield(page)
        removed += done
        kept += page.size - done
        remaining -= page.size
      end
      removed
    end

    private

    def range(start, count, reverse) = entries_from(@config.redis { |c| c.call(*range_command(start, count, reverse)) })

    def range_command(start, count, reverse) = ["ZRANGE", key, start, start + count - 1, *("REV" if reverse), "WITHSCORES"]

    def entries_from(raw) = raw.each_slice(2).map { |value, score| entry(score, value) }

    # An entry read from the set (subclasses may return their own kind).
    def entry(score, value) = SortedEntry.new(self, score, value)
  end

  class ScheduledSet < JobSet
    def initialize(config: Robin.config) = super("schedule", config: config)
  end

  class RetrySet < JobSet
    def initialize(config: Robin.config) = super("retry", config: config)

    # Pushes every entry back onto its queue, a page at a time (three
    # round trips per page); returns how many.
    def retry_all = drain_pages { |page| retry_entries(page) }

    # Moves every entry to the dead set, a page at a time; returns how
    # many.
    def kill_all = drain_pages { |page| kill_entries(page) }
  end

  class DeadSet < JobSet
    def initialize(config: Robin.config) = super("dead", config: config)

    # Adds a payload to the dead set (trimming it by age and size), and
    # optionally acknowledges the unit of work in the same transaction.
    def kill(raw, ack: nil, notify: false)
      @config.redis { |c| c.multi { |tx| queue_kill(tx, raw, ack) } }
      if notify
        payload = Robin.load_json(raw)
        @config.death_handlers.each { |h| h.call(payload, nil) }
      end
      true
    end

    def retry_all = drain_pages { |page| retry_entries(page) }

    # Queues what #kill sends into +tx+ (a transaction), for a caller that
    # adds its own commands to it.
    def queue_kill(tx, raw, ack)
      now = Robin.epoch_seconds(Robin.now_ms)
      tx.call("ZADD", key, now, raw)
      tx.call("ZREMRANGEBYSCORE", key, "-inf", now - @config.dead_timeout)
      tx.call("ZREMRANGEBYRANK", key, 0, -(@config.dead_max_jobs + 1))
      ack&.acknowledge(tx)
    end
  end

  class ProcessRecord
    attr_reader :identity, :info, :busy, :beat, :rss, :rtt_us

    # GVL contention over its last heartbeat interval, as a percentage
    # (see Robin::GVL), or nil where it isn't measured.
    attr_reader :gvl_contention

    def initialize(identity, data, config: Robin.config)
      @config = config
      @identity = identity
      @info = Robin.load_json(data["info"] || "{}")
      @busy = data["busy"].to_i
      @beat = Robin.epoch_ms(data["beat"] || 0)
      @quiet = data["quiet"] == "true"
      @leader = data["leader"] == "1"
      @rss = data["rss"].to_i
      @rtt_us = data["rtt_us"].to_i
      @gvl_contention = data["gvl"]&.to_f
    end

    def [](key) = @info[key]

    # Epoch ms (the record keeps epoch seconds).
    def started_at = (at = self["started_at"]) && Robin.epoch_ms(at)

    def quiet? = @quiet

    def leader? = @leader

    def quiet! = signal("quiet")

    def stop! = signal("stop")

    def dump_threads = signal("dump")

    # Has the process run +count+ workers in capsule +capsule+ from its
    # next heartbeat on: new ones start, and ones no longer needed finish
    # their current job first. A process whose Redis pool was given a size
    # (:pool_size) too small for them logs a warning and changes nothing.
    def resize!(count, capsule: "default")
      raise ArgumentError, "a capsule needs a concurrency above 0, not #{count.inspect}" unless count.instance_of?(Integer) && count.positive?

      send_signal("RESIZE #{count} #{capsule}")
    end

    # With times as epoch ms, and each capsule's queue weights as
    # "queues".
    def to_h
      capsules = @info["capsules"]&.transform_values { |c| {"concurrency" => c["concurrency"], "queues" => c["weights"]} }
      @info.merge({"identity" => identity, "started_at" => started_at, "capsules" => capsules, "busy" => busy,
        "beat" => beat, "quiet" => quiet?, "leader" => leader?, "rss_kb" => rss, "rtt_us" => rtt_us,
        "gvl_contention" => gvl_contention}).compact
    end

    private

    # Remote signals are named like the Unix signals that do the same.
    SIGNALS = {"quiet" => "TSTP", "stop" => "TERM", "dump" => "TTIN"}.freeze

    def signal(name) = send_signal(SIGNALS.fetch(name))

    def send_signal(signal)
      key = "#{@config.process_key(identity)}-signals"
      @config.redis do |c|
        c.pipelined do |p|
          p.call("LPUSH", key, signal)
          p.call("EXPIRE", key, 60)
        end
      end
      true
    end
  end

  class ProcessSet
    include Enumerable

    def initialize(config: Robin.config)
      @config = config
    end

    def each(&block)
      return to_enum unless block

      Scripts.member_hashes(@config, @config.key("processes"), @config.key_prefix).each do |identity, data|
        # A process that died recently may still be listed without a hash.
        yield record(identity, data) unless data.empty?
      end
    end

    def size = count

    def total_concurrency = sum { |p| p["concurrency"].to_i }

    def total_rss_kb = sum(&:rss)

    def leader = Leader.current(@config)

    private

    # A process read from Redis (subclasses may return their own kind).
    def record(identity, data) = ProcessRecord.new(identity, data, config: @config)
  end

  # Jobs currently running across the cluster.
  # Finds where a job is by jid: running, in the schedule, retry or dead
  # set, or (only if none of those has it) waiting in a queue.
  #
  #   Robin::JobLocator.new.locate(jid)
  #   # => [{"where" => "retries", "job" => #<Robin::SortedEntry>}]
  #
  # With Config#jid_index on, the queue the job was pushed to is searched
  # first, and is the only queue searched when it's larger than
  # QUEUE_LIMIT.
  class JobLocator
    SETS = {"scheduled" => ScheduledSet, "retries" => RetrySet, "dead" => DeadSet}.freeze
    QUEUE_LIMIT = 1_000_000

    def initialize(config: Robin.config)
      @config = config
    end

    def locate(jid)
      found = busy(jid) + sets(jid)
      found.empty? ? queued(jid) : found
    end

    private

    def busy(jid)
      WorkSet.new(config: @config).filter_map do |identity, tid, work|
        payload = work.fetch("payload")
        next unless payload.fetch("jid") == jid

        {"where" => "busy", "identity" => identity, "thread" => tid,
         "job" => JobRecord.new(payload, work.fetch("queue"), config: @config)}
      end
    end

    def sets(jid)
      SETS.filter_map do |where, klass|
        entry = klass.new(config: @config).find_job(jid)
        {"where" => where, "job" => entry} if entry
      end
    end

    def queued(jid)
      hint = @config.redis { |c| c.call("GET", @config.key("jid", jid)) }
      hinted, others = Queue.all(config: @config).partition { |q| q.name == hint }
      (hinted + others.reject { |q| q.size > QUEUE_LIMIT }).each do |queue|
        job = queue.find_job(jid)
        return [{"where" => "queue", "queue" => queue.name, "job" => job}] if job
      end
      []
    end
  end

  class WorkSet
    include Enumerable

    def initialize(config: Robin.config)
      @config = config
    end

    # Yields (identity, thread name, {"queue", "payload" (the job hash),
    # "run_at" (epoch ms)}).
    def each
      return to_enum unless block_given?

      Scripts.member_hashes(@config, @config.key("processes"), @config.key_prefix, ":work").each do |identity, work|
        # Each process's jobs by thread, in the same order everywhere.
        work.sort_by(&:first).each do |tid, json|
          work = Robin.load_json(json)
          payload = work.fetch("payload")
          yield identity, tid, {"queue" => work.fetch("queue"), "run_at" => Robin.epoch_ms(work.fetch("run_at")),
                                "payload" => payload.instance_of?(String) ? Robin.load_json(payload) : payload}
        end
      end
    end

    def size = count
  end
end
