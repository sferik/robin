# frozen_string_literal: true

require "socket"

module Robin
  # Sends job and queue metrics to StatsD or DogStatsD over UDP.
  #
  #   Robin.configure_server do |config|
  #     config.statsd = Robin::Statsd.new(host: "127.0.0.1", port: 8125,
  #       prefix: "robin", tags: {env: "production"}, dogstatsd: true)
  #   end
  #
  # Emitted (with a "class" or "queue" tag under DogStatsD, or folded into
  # the metric name for plain StatsD):
  #   jobs.success, jobs.failure (counters), jobs.perform (timing, ms avg)
  #   queue.size, queue.latency (gauges, seconds; sampled by the leader)
  #   jobs.recovered (counter: in-flight jobs put back from dead processes)
  #   jobs.orphaned (counter: in-flight jobs no worker held, put back)
  #   jobs.poison (counter, by class: jobs moved to the dead set for
  #     crashing their process too often)
  #   batch.created, batch.complete, batch.success, batch.death,
  #     batch.cancelled (counters), batch.duration (timing, ms from
  #     creation to completion); under DogStatsD, complete, success, death
  #     and duration carry the batch's tags ("tag:<tag>" for each)
  #
  # With +distributions: true+ (DogStatsD only), it also sends Datadog
  # distributions, for percentiles across every process:
  #   jobs.perform_dist (ms, by class; one packet per successful job)
  #   batch.duration_dist (ms)
  #
  # Sending never blocks and never raises into Robin.
  class Statsd
    MAX_PACKET = 1_432

    attr_reader :host, :port, :prefix, :tags

    def initialize(host: "127.0.0.1", port: 8125, prefix: "robin", tags: {}, dogstatsd: false, distributions: false)
      raise ArgumentError, "distributions need dogstatsd: true" if distributions && !dogstatsd

      @host = host
      @port = port
      @prefix = prefix.to_s.empty? ? "" : "#{prefix}."
      @tags = tags
      @dogstatsd = dogstatsd
      @distributions = distributions
      @mutex = Mutex.new
    end

    def dogstatsd? = @dogstatsd

    def distributions? = @distributions

    def increment(name, value = 1, tags: {}) = send_lines([line(name, value, "c", tags)])

    def gauge(name, value, tags: {}) = send_lines([line(name, value, "g", tags)])

    def timing(name, ms, tags: {}) = send_lines([line(name, ms.round(2), "ms", tags)])

    # A Datadog distribution sample (needs dogstatsd: true).
    def distribution(name, value, tags: {}) = send_lines([line(name, value.round(2), "d", tags)])

    # +jobs+: {class => {s:, f:, ms:, hist:}} as drained by Metrics::Collector.
    def job_metrics(jobs)
      lines = jobs.flat_map do |klass, d|
        tags = {class: klass}
        out = [] #: Array[String]
        success = d.fetch(:s)
        failure = d.fetch(:f)
        out << line("jobs.success", success, "c", tags) if success > 0
        out << line("jobs.failure", failure, "c", tags) if failure > 0
        # The collector times successful runs only.
        out << line("jobs.perform", (d.fetch(:ms) / success).round(2), "ms", tags) if success > 0
        out
      end
      send_lines(lines)
    end

    # +queues+: {name => {size:, latency:}}
    def queue_metrics(queues)
      lines = queues.flat_map do |name, q|
        tags = {queue: name}
        [line("queue.size", q.fetch(:size), "g", tags), line("queue.latency", q.fetch(:latency), "g", tags)]
      end
      send_lines(lines)
    end

    def close
      @mutex.synchronize do
        @socket&.close
        @socket = nil
      end
    end

    private

    def line(name, value, type, tags)
      if @dogstatsd
        out = "#{@prefix}#{name}:#{value}|#{type}"
        all = @tags.merge(tags)
        # An Array value repeats the tag once per element.
        pairs = all.flat_map { |k, v| Array(v).map { |each| "#{k}:#{each.to_s.tr("|,#", "___")}" } }
        out << "|#" << pairs.join(",") unless pairs.empty?
        out
      else
        extra = tags.values.map { |v| v.to_s.gsub(/[^A-Za-z0-9_-]/, "_") }
        "#{@prefix}#{[name, *extra].join(".")}:#{value}|#{type}"
      end
    end

    # Packs lines into datagrams below the safe UDP payload size.
    def send_lines(lines)
      return if lines.empty?

      packet = +""
      lines.each do |l|
        if !packet.empty? && packet.bytesize + l.bytesize + 1 > MAX_PACKET
          deliver(packet)
          packet = +""
        end
        packet << "\n" unless packet.empty?
        packet << l
      end
      deliver(packet)
      nil
    end

    def deliver(packet)
      @mutex.synchronize do
        (@socket ||= UDPSocket.new.tap { |s| s.connect(@host, @port) }).write_nonblock(packet)
      end
    rescue IOError, SystemCallError, SocketError
      @socket = nil
    end
  end
end
