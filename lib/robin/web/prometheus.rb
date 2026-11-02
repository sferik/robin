# frozen_string_literal: true

module Robin
  class Web
    # Prometheus text exposition at GET /metrics, one sample set per
    # configured cluster (labelled cluster="...").
    class Prometheus
      # name, type, help, Robin::Stats reader
      STATS = [
        ["robin_jobs_processed_total", "counter", "Jobs processed since stats were last reset", :processed],
        ["robin_jobs_failed_total", "counter", "Jobs that raised since stats were last reset", :failed],
        ["robin_jobs_enqueued", "gauge", "Jobs waiting in all queues", :enqueued],
        ["robin_scheduled_jobs", "gauge", "Jobs in the schedule set", :scheduled_size],
        ["robin_retry_jobs", "gauge", "Jobs waiting to be retried", :retry_size],
        ["robin_dead_jobs", "gauge", "Jobs in the dead set", :dead_size],
        ["robin_processes", "gauge", "Live Robin server processes", :processes_size],
        ["robin_busy_workers", "gauge", "Worker threads currently running a job", :workers_size]
      ].freeze #: Array[[String, String, String, Symbol]]

      QUEUE_SIZE = ["robin_queue_size", "gauge", "Jobs waiting in a queue"].freeze #: [String, String, String]
      QUEUE_LATENCY = ["robin_queue_latency_seconds", "gauge", "Age of the oldest job in a queue"].freeze #: [String, String, String]
      GVL = ["robin_process_gvl_contention_percent", "gauge",
        "Share of the time a process's threads could wait for the GVL that they did"].freeze #: [String, String, String]

      def initialize(env)
        @env = env
      end

      def call
        return [403, {"content-type" => "text/plain"}, ["Forbidden"]] unless Permissions.allowed?(@env, :read, "/metrics")

        clusters = Web.clusters.map { |name, config| [name, config, Stats.new(config: config)] } #: Array[[String, Config, Stats]]
        out = +""
        STATS.each do |name, type, help, reader|
          header(out, name, type, help)
          clusters.each { |cluster, _, stats| sample(out, name, {"cluster" => cluster}, stats.public_send(reader)) }
        end
        queues = clusters.flat_map { |cluster, config, stats| queue_samples(cluster, config, stats) }
        # (Steep can't splat a tuple into arguments, here and below.)
        header(out, *QUEUE_SIZE) # steep:ignore ArgumentTypeMismatch
        queues.each { |labels, size, _| sample(out, QUEUE_SIZE.fetch(0), labels, size) }
        header(out, *QUEUE_LATENCY) # steep:ignore ArgumentTypeMismatch
        queues.each { |labels, _, latency| sample(out, QUEUE_LATENCY.fetch(0), labels, latency) }
        header(out, *GVL) # steep:ignore ArgumentTypeMismatch
        clusters.each do |cluster, config, _|
          ProcessSet.new(config: config).each do |process|
            next unless process.gvl_contention

            sample(out, GVL.fetch(0), {"cluster" => cluster, "process" => process.identity}, process.gvl_contention)
          end
        end
        [200, {"content-type" => "text/plain; version=0.0.4; charset=utf-8", "cache-control" => "no-store"}, [out]]
      end

      private

      # [labels, size, latency] for every queue in one cluster.
      def queue_samples(cluster, config, stats)
        names = stats.queues.keys
        oldest = config.redis { |c| c.pipelined { |p| names.each { |n| p.call("LINDEX", config.key("queue", n), -1) } } }
        names.zip(oldest).map do |queue, raw|
          [{"cluster" => cluster, "queue" => queue}, stats.queues.fetch(queue), Queue.latency_of(raw)]
        end
      end

      def header(out, name, type, help)
        out << "# HELP #{name} #{help}\n# TYPE #{name} #{type}\n"
      end

      def sample(out, name, labels, value)
        out << "#{name}{#{labels.map { |k, v| "#{k}=\"#{escape(v)}\"" }.join(",")}} #{value}\n"
      end

      def escape(value)
        value.gsub("\\", "\\\\\\\\").gsub("\n", "\\n").gsub('"', '\\"')
      end
    end
  end
end
