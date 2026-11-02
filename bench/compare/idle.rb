# frozen_string_literal: true

# Many idle processes: what K server processes with nothing to do cost
# Redis. Idle servers still poll: blocking fetches that time out
# (both: every 2 seconds per waiting fetch), heartbeats (Robin every 5 s,
# Sidekiq every 10 s), the scheduler (both scale their interval by the
# number of live processes, so the cluster polls about every 5 s), and
# Robin's leader chores.
#
#   BUNDLE_GEMFILE=bench/compare/Gemfile ruby bench/compare/idle.rb
#
# Each measurement forks K server processes from one preloaded parent
# (worker.rb; copy-on-write keeps memory down, but each still needs tens
# of MB), waits SETTLE seconds for startup work to pass (Sidekiq's
# scheduler first waits 10–15 s), then measures Redis CPU (INFO
# used_cpu_user + used_cpu_sys) and commands (total_commands_processed)
# over WINDOW seconds. Both systems use their defaults apart from THREADS.
# "summed RSS" adds up every process's RSS, counting shared pages in each.
#
# Environment:
#   SYSTEMS    robin,sidekiq
#   PROCS      50          idle processes (lower it on a small laptop)
#   THREADS    10          threads per process
#   SETTLE     20          seconds between startup and measuring
#   WINDOW     30          seconds measured
#   RUNS       2           measurements per system (the median is reported)
#   REDIS_URL  redis://127.0.0.1:6379/12 (emptied before and after)

require_relative "support"

PROCS = Integer(ENV.fetch("PROCS", 50))
THREADS = Integer(ENV.fetch("THREADS", 10))
SETTLE = Float(ENV.fetch("SETTLE", 20))
WINDOW = Float(ENV.fetch("WINDOW", 30))
RUNS = Integer(ENV.fetch("RUNS", 2))

def measure(system)
  Bench.flush
  io, pids, label = Bench.start_workers(system, {"FORKS" => PROCS.to_s, "THREADS" => THREADS.to_s, "REDIS_URL" => Bench::REDIS_URL})
  begin
    sleep(SETTLE)
    before = Bench.redis_usage
    start = Bench.now
    sleep(WINDOW)
    after = Bench.redis_usage
    secs = Bench.now - start
    rss = Bench.rss_kb(pids)
  ensure
    Bench.stop_workers(io)
  end
  {system: system, label: label, procs: PROCS, threads: THREADS, secs: secs.round(3),
   redis_cpu_ms_per_sec: ((after[:cpu] - before[:cpu]) * 1000 / secs).round(2),
   commands_per_sec: ((after[:commands] - before[:commands]) / secs).round(1),
   ops_per_sec_sample: after[:ops_per_sec], clients: after[:clients], rss_mb: rss / 1024}
end

Bench.claim_database!
raw = []
RUNS.times do |run|
  Bench.order(run).each do |system|
    result = measure(system)
    raw << result
    warn format("%-7s %d idle processes: Redis %.1f ms CPU/s, %.0f commands/s", system, PROCS,
      result[:redis_cpu_ms_per_sec], result[:commands_per_sec])
  end
end

rows = raw.group_by { |r| r[:system] }.map do |_, runs|
  med = ->(key) { Bench.median(runs.map { |r| r.fetch(key) }) }
  [runs.first[:label], PROCS, THREADS, "#{med.call(:redis_cpu_ms_per_sec)} ms",
    "#{(med.call(:redis_cpu_ms_per_sec) * 1000 / PROCS).round(1)} µs", med.call(:commands_per_sec),
    (med.call(:commands_per_sec) / PROCS).round(2), med.call(:clients), "#{med.call(:rss_mb)} MB"]
end
Bench.report("Idle processes: #{PROCS} processes, no jobs, #{WINDOW}s window after #{SETTLE}s, median of #{RUNS}",
  ["system", "processes", "threads each", "Redis CPU per second", "per process", "Redis commands/s", "per process",
    "Redis clients", "summed RSS"],
  rows, [:left] + [:right] * 8, raw)
