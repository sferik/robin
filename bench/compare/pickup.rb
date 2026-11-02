# frozen_string_literal: true

# Pickup latency on a quiet queue: one idle server, and jobs pushed one at
# a time at random intervals. Each job records how long after its push it
# started (wall clock: the pusher passes Time.now as the argument, the job
# subtracts it from Time.now when perform begins, both on this machine).
#
#   BUNDLE_GEMFILE=bench/compare/Gemfile ruby bench/compare/pickup.rb
#
# Per measurement: start a server (worker.rb), wait SETTLE seconds so it's
# idle (its workers blocked waiting for jobs), then a pusher process (this
# script with --push SYSTEM) pushes WARMUP jobs back to back and waits for
# them to run (untimed, so the JIT is warm on both sides), then pushes JOBS
# jobs with the system's single-job push, sleeping a random MIN_MS..MAX_MS
# between them. Percentiles are over
# all runs' jobs together. Both systems use their defaults apart from
# THREADS.
#
# Environment:
#   SYSTEMS    robin,sidekiq
#   JOBS       100         jobs per measurement
#   WARMUP     2000        untimed jobs first
#   MIN_MS     200         shortest pause between pushes
#   MAX_MS     500         longest pause between pushes
#   THREADS    10          server threads
#   SETTLE     3           seconds between server start and the first push
#   RUNS       2           measurements per system
#   REDIS_URL  redis://127.0.0.1:6379/12 (emptied before and after)

require_relative "support"

JOBS = Integer(ENV.fetch("JOBS", 100))
WARMUP = Integer(ENV.fetch("WARMUP", 2000))
MIN_MS = Integer(ENV.fetch("MIN_MS", 200))
MAX_MS = Integer(ENV.fetch("MAX_MS", 500))

def pusher(system)
  sys = Bench.system(system)
  sys.boot
  Bench::Jobs.define(sys)
  WARMUP.times { sys.push(PickupJob, [Time.now.to_f]) }
  deadline = Bench.now + 60
  sleep(0.01) until Bench.redis.call("LLEN", Bench::PICKUP_KEY) == WARMUP || Bench.now > deadline
  Bench.redis.call("DEL", Bench::PICKUP_KEY)
  JOBS.times do
    sleep(rand(MIN_MS..MAX_MS) / 1000.0)
    sys.push(PickupJob, [Time.now.to_f])
  end
  deadline = Bench.now + 10
  sleep(0.01) until Bench.redis.call("LLEN", Bench::PICKUP_KEY) == JOBS || Bench.now > deadline
  latencies = Bench.redis.call("LRANGE", Bench::PICKUP_KEY, 0, -1).map { |v| Float(v) }
  abort "only #{latencies.size} of #{JOBS} jobs ran" unless latencies.size == JOBS

  {system: system, latencies_ms: latencies.map { |s| (s * 1000).round(3) }}
end

if ARGV.first == "--push"
  puts JSON.generate(pusher(ARGV.fetch(1)))
  exit
end

THREADS = Integer(ENV.fetch("THREADS", 10))
SETTLE = Float(ENV.fetch("SETTLE", 3))
RUNS = Integer(ENV.fetch("RUNS", 2))
Bench.claim_database!
raw = []
labels = {}
RUNS.times do |run|
  Bench.order(run).each do |system|
    Bench.flush
    io, _, labels[system] = Bench.start_workers(system, {"THREADS" => THREADS.to_s, "REDIS_URL" => Bench::REDIS_URL})
    begin
      sleep(SETTLE)
      result = Bench.run_json("pickup.rb", "--push", system)
    ensure
      Bench.stop_workers(io)
    end
    raw << result
    warn format("%-7s p50 %.2f ms", system, Bench.percentile(result["latencies_ms"], 0.5))
  end
end

rows = raw.group_by { |r| r["system"] }.map do |system, runs|
  all = runs.flat_map { |r| r["latencies_ms"] }
  [labels.fetch(system), all.size, *[0.5, 0.9, 0.99].map { |p| format("%.2f ms", Bench.percentile(all, p)) },
    format("%.2f ms", all.max)]
end
Bench.report("Pickup latency on a quiet queue: one push every #{MIN_MS}–#{MAX_MS} ms, #{THREADS} threads, " \
  "#{RUNS} runs of #{JOBS} jobs",
  ["system", "jobs", "p50", "p90", "p99", "max"], rows, [:left] + [:right] * 5, raw)
