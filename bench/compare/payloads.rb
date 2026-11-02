# frozen_string_literal: true

# Large payloads: jobs whose one argument is a 10 KB or 100 KB string.
# load.rb's measurement (push with the bulk push, then time an in-process
# server running them all) with big arguments: push and processing rates,
# Ruby CPU per job and Redis CPU per job for each phase.
#
#   BUNDLE_GEMFILE=bench/compare/Gemfile ruby bench/compare/payloads.rb
#
# Each measurement is a fresh process (this script with --child SYSTEM
# SIZE). Every job gets the same random alphanumeric string, so neither
# JSON escaping nor compressibility favors anyone. Jobs are pushed in
# batches of about 4 MB (at most 1,000 jobs). As many jobs again go first,
# pushed and run untimed, so the JIT (JRuby's, or YJIT) is warm when the
# measurement starts.
#
# Environment:
#   SYSTEMS    robin,sidekiq
#   SIZES      10240,102400  argument sizes in bytes
#   MB         256         payload megabytes per measurement: COUNT
#                          defaults to MB / size (25,600 and 2,621 jobs)
#   COUNT      (from MB)   jobs per measurement, for every size
#   THREADS    10          server threads
#   RUNS       3           measurements per cell (the median is reported)
#   REDIS_URL  redis://127.0.0.1:6379/12 (emptied before and after)

require_relative "support"
require "securerandom"

THREADS = Integer(ENV.fetch("THREADS", 10))

def count_for(size) = Integer(ENV.fetch("COUNT", Integer(ENV.fetch("MB", 256)) * 1024 * 1024 / size))

def child(system, size)
  sys = Bench.system(system)
  label = sys.boot
  sys.job(:BigJob) { |_string| Bench::Jobs.done }
  count = count_for(size)
  Bench::Jobs.expect(2 * count, warmup: count)
  string = SecureRandom.alphanumeric(size)
  batch = (4 * 1024 * 1024 / size).clamp(1, 1_000)
  push = -> { count.times.each_slice(batch) { |slice| sys.push_bulk(BigJob, Array.new(slice.size) { [string] }) } }
  push.call # the warmup jobs

  GC.start
  before = Bench.redis_usage
  cpu = Bench.cpu
  start = Bench.now
  push.call
  push_secs = Bench.now - start
  push_cpu = Bench.cpu - cpu
  pushed = Bench.redis_usage
  used_mb = Integer(Bench.redis.call("INFO", "memory")[/^used_memory:(\d+)/, 1]) / 1024 / 1024

  GC.start
  server = sys.server(threads: THREADS)
  server.run
  Bench::Jobs.wait_warm
  # From here on, with the JIT warm: the jobs run since, and what they cost.
  ran = Bench::Jobs.count
  before_run = Bench.redis_usage
  cpu = Bench.cpu
  start = Bench.now
  Bench::Jobs.wait
  run_secs = Bench.now - start
  measured = (2 * count) - ran
  run_cpu = Bench.cpu - cpu
  after = Bench.redis_usage
  server.stop

  {system: system, label: label, size: size, count: count, threads: THREADS, redis_used_memory_mb: used_mb,
   push_secs: push_secs.round(3), push_per_sec: (count / push_secs).round,
   push_cpu_us_per_job: (push_cpu * 1e6 / count).round(1),
   push_redis_cpu_us_per_job: ((pushed[:cpu] - before[:cpu]) * 1e6 / count).round(1),
   run_secs: run_secs.round(3), measured: measured, jobs_per_sec: (measured / run_secs).round,
   cpu_us_per_job: (run_cpu * 1e6 / measured).round(1),
   redis_cpu_us_per_job: ((after[:cpu] - before_run[:cpu]) * 1e6 / measured).round(1),
   redis_commands_per_job: ((after[:commands] - before_run[:commands]).to_f / measured).round(2)}
end

if ARGV.first == "--child"
  puts JSON.generate(child(ARGV.fetch(1), Integer(ARGV.fetch(2))))
  exit
end

SIZES = Bench.env_list("SIZES", "10240,102400")
RUNS = Integer(ENV.fetch("RUNS", 3))
Bench.claim_database!
raw = []
rows = []
SIZES.each do |size|
  results = Hash.new { |h, k| h[k] = [] }
  RUNS.times do |run|
    Bench.order(run).each do |system|
      Bench.flush
      result = Bench.run_json("payloads.rb", "--child", system, size)
      raw << result
      results[system] << result
      warn format("%6d B %-7s pushed %7d jobs/s, ran %7d jobs/s", size, system, result["push_per_sec"], result["jobs_per_sec"])
    end
  end
  results.each do |_, runs|
    med = ->(key) { Bench.median(runs.map { |r| r.fetch(key) }) }
    rows << [runs.first.fetch("label"), "#{size / 1024} KB", runs.first.fetch("count"), med.call("push_per_sec"),
      "#{med.call("push_cpu_us_per_job")} µs", "#{med.call("push_redis_cpu_us_per_job")} µs", med.call("jobs_per_sec"),
      "#{med.call("cpu_us_per_job")} µs", "#{med.call("redis_cpu_us_per_job")} µs", med.call("redis_commands_per_job")]
  end
end

Bench.report("Large payloads: #{THREADS} threads, median of #{RUNS}",
  ["system", "argument", "jobs", "pushed jobs/s", "Ruby CPU/job (push)", "Redis CPU/job (push)",
    "processed jobs/s", "Ruby CPU/job (run)", "Redis CPU/job (run)", "Redis commands/job (run)"],
  rows, [:left] + [:right] * 9, raw)
