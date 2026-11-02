# frozen_string_literal: true

module Robin
  # Per-job-class execution metrics.
  #
  # Workers aggregate counts, total time and a latency histogram in memory;
  # the heartbeat flushes them to Redis once every few seconds, so recording
  # costs no extra round-trips per job.
  #
  # Storage (UTC):
  #   robin:m:<YYYYMMDDHHMM>       hash  "<Class>|s|f|ms" counts, 8h TTL
  #   robin:h:<Class>:<YYYYMMDDHHMM> hash bucket index => count, 8h TTL
  #   robin:mh:<YYYYMMDDHH>        hash  hourly rollup, kept metrics_retention_days
  #   robin:qh:<YYYYMMDDHH>        hash  "<queue>|size" / "<queue>|latency" hourly maxima
  #   robin:qm:<YYYYMMDDHHMM>      hash  the same, per minute, 8h TTL
  module Metrics
    # Upper bounds (ms) of the histogram buckets; the last is open-ended.
    BUCKETS = [5, 10, 20, 35, 50, 75, 100, 150, 250, 400, 600, 1_000, 1_500, 2_500, 4_000,
      6_000, 10_000, 15_000, 25_000, 40_000, 60_000, 120_000, 300_000, 600_000, Float::INFINITY].freeze

    MINUTE_TTL = 8 * 3600

    # The daily job totals (stat:processed:<YYYY-MM-DD>, stat:failed:...)
    # are two small keys a day, kept five years.
    DAILY_TOTALS_TTL = 5 * 365 * 86_400

    class << self
      def bucket_for(ms)
        BUCKETS.bsearch_index { |b| ms <= b } #: Integer
      end

      def minute_stamp(time) = time.getutc.strftime("%Y%m%d%H%M")

      def hour_stamp(time) = time.getutc.strftime("%Y%m%d%H")

      # Records queue sizes and latencies (leader only, once a minute), in
      # two round trips.
      # mutant:disable -- Connection#evalsha splats ARGV, so passing the
      # prefix bare or wrapped in an Array is identical.
      def sample_queues(config, conn, time = Time.now)
        found = conn.evalsha(Scripts::QUEUE_SAMPLES, [config.key("queues")], ["#{config.key("queue")}:"])
        return if found.empty?

        samples = found.each_slice(3).to_h { |q, size, oldest| [q, {size: size, latency: Queue.latency_of(oldest)}] }
        fields = samples.flat_map { |q, s| ["#{q}|size", s.fetch(:size), "#{q}|latency", s.fetch(:latency)] }
        retention = config.metrics_retention_days * 86_400
        conn.pipelined do |p|
          p.evalsha(Scripts::HMAX, [config.key("qm", minute_stamp(time))], [MINUTE_TTL, *fields])
          p.evalsha(Scripts::HMAX, [config.key("qh", hour_stamp(time))], [retention, *fields])
        end
        config.statsd&.queue_metrics(samples)
      end
    end

    # Each thread records into a stripe of its own, so workers never wait
    # on each other (with real threads, as on JRuby, one shared lock would
    # serialize every job); draining merges the stripes.
    class Collector
      # One thread's counts.
      class Stripe
        attr_reader :thread

        def initialize(thread)
          @thread = thread
          @mutex = Mutex.new
          reset
        end

        def record(klass, ms, ok)
          @mutex.synchronize do
            entry = Collector.entry(@jobs, klass)
            # Timings cover successful runs only: a job failing fast (or
            # timing out) would skew the averages and the histogram.
            if ok
              entry[:s] += 1
              entry[:ms] += ms
              entry.fetch(:hist)[Metrics.bucket_for(ms)] += 1
            else
              entry[:f] += 1
            end
            @processed += 1
            @failed += 1 unless ok
          end
        end

        # Adds counts drained earlier.
        def add(drained)
          jobs, processed, failed = drained
          @mutex.synchronize do
            Collector.merge(@jobs, jobs)
            @processed += processed
            @failed += failed
          end
        end

        def drain
          @mutex.synchronize do
            snapshot = [@jobs, @processed, @failed] #: Metrics::drained
            reset
            snapshot
          end
        end

        private

        def reset
          @jobs = {}
          @processed = 0
          @failed = 0
        end
      end

      def self.entry(jobs, klass) = (jobs[klass] ||= {s: 0, f: 0, ms: 0.0, hist: Hash.new(0)})

      # Adds +from+'s per-class counts to +into+'s.
      def self.merge(into, from)
        from.each do |klass, data|
          entry = entry(into, klass)
          entry[:s] += data.fetch(:s)
          entry[:f] += data.fetch(:f)
          entry[:ms] += data.fetch(:ms)
          data.fetch(:hist).each { |b, c| entry.fetch(:hist)[b] += c }
        end
      end

      def initialize
        @mutex = Mutex.new
        @stripes = []
        @key = :"robin_metrics_#{object_id}"
      end

      def record(klass, ms, ok) = stripe.record(klass, ms, ok)

      # [per-class counts, processed, failed] since the last drain. Stripes
      # of threads that have finished go once they're drained.
      def drain
        stripes = @mutex.synchronize do
          all = @stripes
          @stripes = all.select { |s| s.thread.alive? }
          all
        end
        jobs = {} #: Metrics::jobs
        processed = failed = 0
        stripes.each do |stripe|
          stripe_jobs, stripe_processed, stripe_failed = stripe.drain
          Collector.merge(jobs, stripe_jobs)
          processed += stripe_processed
          failed += stripe_failed
        end
        [jobs, processed, failed]
      end

      # Puts drained data back (used when a flush fails).
      def restore(drained) = stripe.add(drained)

      # Writes what was recorded since the last flush in one pipeline.
      def flush(config, conn, time = Time.now)
        drained = nil #: Metrics::drained?
        conn.pipelined { |p| drained = queue(config, p, time) }
        # (Pipelined runs the block, so drained is set.)
        flushed(config, drained) # steep:ignore ArgumentTypeMismatch
      rescue
        restore(drained) if drained
        raise
      end

      # Queues the commands that write what was recorded since the last
      # flush on +pipe+ (a pipeline or transaction about to be sent), and
      # returns what they write: pass it to #flushed once they're sent, or
      # to #restore if sending them failed.
      def queue(config, pipe, time = Time.now)
        drained = drain
        write(config, pipe, time, drained) unless drained.fetch(1).zero?
        drained
      end

      # Reports queued metrics to StatsD once they're written.
      def flushed(config, drained)
        jobs, processed, _failed = drained
        config.statsd&.job_metrics(jobs) unless processed.zero?
      end

      private

      # This thread's stripe, made on first use.
      def stripe
        Thread.current[@key] ||= Stripe.new(Thread.current).tap do |s|
          @mutex.synchronize { @stripes << s }
        end
      end

      def write(config, p, time, drained)
        jobs, processed, failed = drained
        minute = Metrics.minute_stamp(time)
        hour = Metrics.hour_stamp(time)
        day = time.getutc.strftime("%Y-%m-%d")
        mkey = config.key("m", minute)
        hkey = config.key("mh", hour)
        p.call("INCRBY", config.key("stat", "processed"), processed)
        p.call("INCRBY", config.key("stat", "processed", day), processed)
        p.call("EXPIRE", config.key("stat", "processed", day), DAILY_TOTALS_TTL)
        if failed > 0
          p.call("INCRBY", config.key("stat", "failed"), failed)
          p.call("INCRBY", config.key("stat", "failed", day), failed)
          p.call("EXPIRE", config.key("stat", "failed", day), DAILY_TOTALS_TTL)
        end
        jobs.each do |klass, d|
          [mkey, hkey].each do |key|
            if d.fetch(:s) > 0
              p.call("HINCRBY", key, "#{klass}|s", d.fetch(:s))
              p.call("HINCRBYFLOAT", key, "#{klass}|ms", d.fetch(:ms).round(1))
            end
            p.call("HINCRBY", key, "#{klass}|f", d.fetch(:f)) if d.fetch(:f) > 0
          end
          hist = config.key("h", klass, minute)
          d.fetch(:hist).each { |bucket, count| p.call("HINCRBY", hist, bucket, count) }
          p.call("EXPIRE", hist, MINUTE_TTL)
        end
        p.call("EXPIRE", mkey, MINUTE_TTL)
        p.call("EXPIRE", hkey, config.metrics_retention_days * 86_400)
      end
    end

    # Query helpers for the web UI and API.
    class Query
      GRANULARITIES = {minute: [60, "qm", :minute_stamp], hour: [3600, "qh", :hour_stamp]} #: Hash[Symbol, [Integer, String, Symbol]]
        .freeze

      def initialize(config = Robin.config)
        @config = config
      end

      # Per-class totals over the last +minutes+ minutes, plus a per-minute
      # series for charting. Returns {"classes" => {...}, "series" => [...]}
      def recent(minutes: 60, now: Time.now)
        stamps = (0...minutes).map { |i| Metrics.minute_stamp(now - i * 60) }.reverse
        rows = @config.redis do |c|
          c.pipelined { |p| stamps.each { |s| p.call("HGETALL", @config.key("m", s)) } }
        end
        summarize(stamps, rows)
      end

      # Hourly history over the last +hours+ hours (historical metrics).
      def history(hours: 24 * 7, now: Time.now)
        stamps = (0...hours).map { |i| Metrics.hour_stamp(now - i * 3600) }.reverse
        rows = @config.redis do |c|
          c.pipelined { |p| stamps.each { |s| p.call("HGETALL", @config.key("mh", s)) } }
        end
        summarize(stamps, rows)
      end

      # Queue size/latency maxima, per minute (granularity :minute) or per
      # hour (granularity :hour). Other granularities raise KeyError.
      def queue_history(granularity: :minute, points: 60, now: Time.now)
        step, prefix, fmt = GRANULARITIES.fetch(granularity)
        stamps = (0...points).map { |i| Metrics.public_send(fmt, now - i * step) }.reverse
        rows = @config.redis do |c|
          c.pipelined { |p| stamps.each { |s| p.call("HGETALL", @config.key(prefix, s)) } }
        end
        stamps.zip(rows).map do |stamp, row|
          data = Hash.new { |h, k| h[k] = {} }
          row.each_slice(2) do |field, value|
            queue, _, kind = field.rpartition("|")
            data[queue][kind] = value.to_i
          end
          {"t" => stamp, "queues" => data}
        end
      end

      # Latency histogram for one class over the last +minutes+ minutes.
      def histogram(klass, minutes: 60, now: Time.now)
        stamps = (0...minutes).map { |i| Metrics.minute_stamp(now - i * 60) }
        rows = @config.redis do |c|
          c.pipelined { |p| stamps.each { |s| p.call("HGETALL", @config.key("h", klass, s)) } }
        end
        totals = Array.new(BUCKETS.size, 0)
        rows.each { |row| row.each_slice(2) { |b, n| totals[Integer(b)] += Integer(n) } }
        BUCKETS.each_with_index.map { |limit, i| {"le" => (limit unless limit.infinite?), "count" => totals.fetch(i)} }
      end

      private

      def summarize(stamps, rows)
        classes = Hash.new { |h, k| h[k] = {"s" => 0, "f" => 0, "ms" => 0.0} } #: Hash[String, Hash[String, Numeric]]
        series = stamps.zip(rows).map do |stamp, row|
          point = {"t" => stamp, "s" => 0, "f" => 0, "ms" => 0.0} #: Hash[String, untyped]
          row.each_slice(2) do |field, value|
            klass, _, kind = field.rpartition("|")
            v = (kind == "ms") ? Float(value) : Integer(value)
            classes[klass][kind] += v
            point[kind] += v
          end
          point
        end
        classes.each_value do |c|
          n = c.fetch("s") # "ms" only counts successful runs
          c["avg_ms"] = n.zero? ? 0 : (c.fetch("ms") / n).round(1)
        end
        {"classes" => classes, "series" => series}
      end
    end
  end
end
