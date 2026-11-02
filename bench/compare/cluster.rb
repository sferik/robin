# frozen_string_literal: true

# Cluster capacity: how many no-op jobs per second N server processes
# together get through one Redis, and how much of Redis's CPU each job
# costs. Redis runs commands on one thread, so throughput stops rising
# once Redis is busy (about 1 core). Redis's CPU per job isn't fixed,
# though: the busier it is, the more commands each wakeup of its event
# loop handles, so it falls as clients are added, and the ceiling is
# higher than 1 / (Redis CPU per job) measured with one process.
#
#   BUNDLE_GEMFILE=bench/compare/Gemfile ruby bench/compare/cluster.rb
#
# For each N (1, 2, 4, ... up to MAX_PROCS), each system: top its queue up
# to the backlog, fork N server processes from one preloaded parent
# (worker.rb), wait WARMUP seconds, then measure for WINDOW seconds how
# fast the queue shrinks and how much CPU Redis uses (INFO's
# used_cpu_user + used_cpu_sys). A system stops growing N once doubling
# it raised its median throughput by less than 5%. The backlog is
# BACKLOG, or more when the last N's rate says twice as many processes
# would empty it before the window ends (Redis needs about 200 bytes
# per queued job).
#
# Environment:
#   SYSTEMS    robin,sidekiq
#   MAX_PROCS  8           largest N (doubling from 1)
#   THREADS    10          threads per process
#   BACKLOG    1000000     least jobs queued before each measurement
#   WARMUP     2           seconds between start and measuring
#   WINDOW     5           seconds measured (less if the queue runs low)
#   RUNS       3           measurements per cell (the median is reported)
#   REDIS_URL  redis://127.0.0.1:6379/12 (emptied before and after)
#
# Redis CPU and commands are the whole server's, so use a Redis nothing
# else is using. The harness itself only reads LLEN four times a second.
# Worker processes share the machine with Redis: on a laptop, past about
# (cores - 1) processes they compete with Redis for CPU, so the curve
# flattens for that reason too; the "Redis CPU" column tells which.

require_relative "support"

MAX_PROCS = Integer(ENV.fetch("MAX_PROCS", 8))
THREADS = Integer(ENV.fetch("THREADS", 10))
BACKLOG = Integer(ENV.fetch("BACKLOG", 1_000_000))
WARMUP = Float(ENV.fetch("WARMUP", 2))
WINDOW = Float(ENV.fetch("WINDOW", 5))
RUNS = Integer(ENV.fetch("RUNS", 3))

def measure(system, procs, backlog)
  queue = Bench::KEYS.fetch(system).fetch(:queue)
  missing = backlog - Bench.redis.call("LLEN", queue)
  Bench.run_json("push.rb", system, "noop", missing) if missing.positive?
  io, pids, label = Bench.start_workers(system, {"FORKS" => procs.to_s, "THREADS" => THREADS.to_s, "REDIS_URL" => Bench::REDIS_URL})
  begin
    sleep(WARMUP)
    start = Bench.now
    before = Bench.redis_usage
    len_before = Bench.redis.call("LLEN", queue)
    # Stop early rather than let the queue run dry inside the window.
    floor = len_before / 10
    sleep(0.25) until Bench.now - start >= WINDOW || Bench.redis.call("LLEN", queue) < floor
    after = Bench.redis_usage
    len_after = Bench.redis.call("LLEN", queue)
    secs = Bench.now - start
    rss = Bench.rss_kb(pids)
  ensure
    Bench.stop_workers(io)
  end
  jobs = len_before - len_after
  abort "#{system} with #{procs} processes emptied the queue within #{secs.round(2)}s; raise BACKLOG" if secs < WINDOW / 2
  warn "#{system}: the queue ran low after #{secs.round(2)}s; consider raising BACKLOG" if secs < WINDOW * 0.9
  {system: system, label: label, procs: procs, threads: THREADS, secs: secs.round(3), jobs: jobs,
   jobs_per_sec: (jobs / secs).round,
   redis_cores: ((after[:cpu] - before[:cpu]) / secs).round(3),
   redis_cpu_us_per_job: ((after[:cpu] - before[:cpu]) * 1e6 / jobs).round(1),
   redis_commands_per_job: ((after[:commands] - before[:commands]).to_f / jobs).round(2),
   rss_mb: rss / 1024}
end

Bench.claim_database!
labels = {}
raw = []
medians = Hash.new { |h, k| h[k] = [] } # system => [{procs, ...}] in order
active = Bench::SYSTEMS.dup
procs = 1
while procs <= MAX_PROCS && !active.empty?
  results = Hash.new { |h, k| h[k] = [] }
  RUNS.times do |run|
    Bench.order(run).each do |system|
      next unless active.include?(system)

      last = medians[system].last
      backlog = [BACKLOG, (last ? last[:jobs_per_sec] * 2 * (WARMUP + WINDOW + 2) : 0).to_i].max
      result = measure(system, procs, backlog)
      raw << result
      labels[system] = result[:label]
      results[system] << result
      warn format("%-7s %2d procs %8d jobs/s, Redis %.2f cores", system, procs, result[:jobs_per_sec], result[:redis_cores])
    end
  end
  results.each do |system, runs|
    row = {procs: procs}
    %i[jobs_per_sec redis_cores redis_cpu_us_per_job redis_commands_per_job rss_mb].each do |key|
      row[key] = Bench.median(runs.map { |r| r.fetch(key) })
    end
    previous = medians[system].last
    medians[system] << row
    active.delete(system) if previous && row[:jobs_per_sec] < previous[:jobs_per_sec] * 1.05
  end
  procs *= 2
end

rows = medians.flat_map do |system, list|
  peak = list.max_by { |r| r[:jobs_per_sec] }
  list.map do |r|
    rate = (r.equal?(peak) ? "**#{r[:jobs_per_sec]}**" : r[:jobs_per_sec].to_s)
    [labels.fetch(system), r[:procs], THREADS, rate, format("%.2f", r[:redis_cores]),
      "#{r[:redis_cpu_us_per_job]} µs", r[:redis_commands_per_job], "#{r[:rss_mb]} MB"]
  end
end
notes = medians.map do |system, list|
  peak = list.max_by { |r| r[:jobs_per_sec] }
  busy = list.find { |r| r[:redis_cores] >= 0.9 }
  "#{labels.fetch(system)}: peak #{peak[:jobs_per_sec]} jobs/s with #{peak[:procs]} processes; " +
    (busy ? "Redis first used 0.9+ cores with #{busy[:procs]}." : "Redis stayed under 0.9 cores.")
end
Bench.report("Cluster capacity: at least #{BACKLOG} no-op jobs queued, #{WINDOW}s windows after #{WARMUP}s warmup, " \
  "median of #{RUNS}; #{Etc.nprocessors} CPUs",
  ["system", "processes", "threads each", "processed jobs/s", "Redis CPU (cores)", "Redis CPU/job",
    "Redis commands/job", "workers' RSS"],
  rows, [:left] + [:right] * 7, raw, notes: notes)
