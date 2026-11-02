# frozen_string_literal: true

# Robin vs Sidekiq: the same workload in fresh processes, several times
# each, reporting the median.
#
#   cd bench/compare && bundle install
#   BUNDLE_GEMFILE=bench/compare/Gemfile ruby bench/compare/run.rb
#
# Environment (lists are comma-separated):
#   SYSTEMS    robin,sidekiq
#   THREADS    10,25        server concurrency
#   LATENCY    0,1          ms added each way by bench/compare/latency_proxy.rb
#   RUNS       3            measurements per cell (the median is reported)
#   COUNT      500000       jobs per measurement
#   REDIS_URL  redis://127.0.0.1:6379/12 (emptied before and after each run)
#   HEAP       512m         JRuby only: each measured process's maximum JVM
#                           heap (-Xmx), the same for both systems, so RSS
#                           growth compares memory used rather than how far
#                           each JVM chose to grow its heap (empty: no cap)
#
# Runs alternate between systems so drift on the machine hits both alike.

require "json"
require "uri"

HERE = __dir__
SYSTEMS = ENV.fetch("SYSTEMS", "robin,sidekiq").split(",")
THREADS = ENV.fetch("THREADS", "10,25").split(",").map { |v| Integer(v) }
LATENCIES = ENV.fetch("LATENCY", "0,1").split(",").map { |v| Integer(v) }
RUNS = Integer(ENV.fetch("RUNS", 3))
REDIS = URI(ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/12"))
PROXY_PORT = 16_379
HEAP = ENV.fetch("HEAP", "512m")

def median(values) = values.sort[values.size / 2]

# Starts the latency proxy (when there's latency) and yields the URL to use.
def with_latency(millis)
  return yield(REDIS.to_s) if millis.zero?

  io = IO.popen([RbConfig.ruby, File.join(HERE, "latency_proxy.rb"), PROXY_PORT.to_s, "#{REDIS.host}:#{REDIS.port}", millis.to_s])
  io.gets # "ready"
  url = REDIS.dup
  url.host = "127.0.0.1"
  url.port = PROXY_PORT
  yield url.to_s
ensure
  if io
    Process.kill("TERM", io.pid)
    io.close
  end
end

def measure(system, threads, url)
  env = {"THREADS" => threads.to_s, "REDIS_URL" => url}
  env["JRUBY_OPTS"] = [ENV["JRUBY_OPTS"], "-J-Xmx#{HEAP}"].compact.join(" ") if RUBY_ENGINE == "jruby" && !HEAP.empty?
  out = IO.popen(env, [RbConfig.ruby, File.join(HERE, "load.rb"), system], &:read)
  raise "#{system} run failed" unless $?.success?

  JSON.parse(out.lines.last)
end

rows = []
LATENCIES.each do |latency|
  with_latency(latency) do |url|
    THREADS.each do |threads|
      results = Hash.new { |h, k| h[k] = [] }
      RUNS.times do |run|
        order = run.even? ? SYSTEMS : SYSTEMS.reverse
        order.each do |system|
          result = measure(system, threads, url)
          results[system] << result
          warn format("latency %dms, %2d threads, %-7s %7d jobs/s", latency, threads, system, result.fetch("jobs_per_sec"))
        end
      end
      results.each do |system, runs|
        rows << {
          "label" => runs.first.fetch("label"), "latency" => latency, "threads" => threads,
          "jobs_per_sec" => median(runs.map { |r| r.fetch("jobs_per_sec") }),
          "push_per_sec" => median(runs.map { |r| (r.fetch("count") / r.fetch("push_secs")).round }),
          "rss_growth_mb" => median(runs.map { |r| (r.fetch("rss_after_kb") - r.fetch("rss_before_kb")) / 1024 }),
          "cpu_us" => median(runs.map { |r| r.fetch("cpu_us_per_job") }),
          "redis_cpu_us" => median(runs.map { |r| r.fetch("redis_cpu_us_per_job") }),
          "redis_commands" => median(runs.map { |r| r.fetch("redis_commands_per_job") })
        }
      end
    end
  end
end

puts RUBY_DESCRIPTION
puts "#{ENV.fetch("COUNT", 500_000)} jobs per run, median of #{RUNS}"
puts
puts "| system | latency (each way) | threads | processed jobs/s | pushed jobs/s | Ruby CPU/job | Redis CPU/job | Redis commands/job | RSS growth |"
puts "|---|--:|--:|--:|--:|--:|--:|--:|--:|"
rows.each do |r|
  puts "| #{r["label"]} | #{r["latency"]} ms | #{r["threads"]} | #{r["jobs_per_sec"]} | #{r["push_per_sec"]} | " \
    "#{r["cpu_us"]} µs | #{r["redis_cpu_us"]} µs | #{r["redis_commands"]} | #{r["rss_growth_mb"]} MB |"
end
