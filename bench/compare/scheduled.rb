# frozen_string_literal: true

# Scheduled jobs coming due: COUNT jobs all due at the same instant, then
# one server process starts. How fast does its scheduler move them onto
# their queue, and how long until they've all run?
#
#   BUNDLE_GEMFILE=bench/compare/Gemfile ruby bench/compare/scheduled.rb
#
# Each measurement is a fresh process (this script with --child SYSTEM
# SET). It schedules the no-op jobs with the system's bulk push, all at
# the same time DUE_IN seconds ahead, waits until that time has passed,
# then starts an embedded server and watches the set (ZCARD every 10 ms).
# With SETS including "retry", the same jobs are then moved from the
# schedule set to the retry set (same score) with the fields both systems
# add to a failed job (error_class, error_message, failed_at in epoch ms,
# retry_count 0), because neither has an API for creating retries without
# running failing jobs, which would make them come due at different times.
#
# Pollers. Robin's scheduler first waits rand * poll_interval, then polls
# every poll_interval * live processes * (0.5..1.5) seconds; one poll drains
# everything due, 500 jobs per Lua call. Sidekiq's waits 10 + rand * 5
# seconds (only rand * 5 when poll_interval_average is set), then polls
# every average_scheduled_poll_interval * live processes * (0.5..1.5)
# seconds (or poll_interval_average * (0.5..1.5) when set); one poll
# drains everything due, one job per round trip (a Lua ZPOPBYSCORE, then
# a client push). Both default to 5 seconds. Here POLL (default 1) sets
# Robin's poll_interval and Sidekiq's poll_interval_average, which is as
# close as they come: both then poll every 0.5–1.5 s. Because the first
# poll's timing is mostly the initial wait, "move rate" is measured from
# the first job leaving the set to the last.
#
# Environment:
#   SYSTEMS    robin,sidekiq
#   SETS       schedule,retry
#   COUNT      100000      jobs per measurement
#   THREADS    10          server threads
#   POLL       1           see above
#   PROCESS    1           0: the server works another queue, so the jobs
#                          are only moved, never run
#   DUE_IN     (5 + COUNT / 20000) seconds; must cover pushing
#   RUNS       3           measurements per cell (the median is reported)
#   REDIS_URL  redis://127.0.0.1:6379/12 (emptied before and after)

require_relative "support"

COUNT = Integer(ENV.fetch("COUNT", 100_000))
THREADS = Integer(ENV.fetch("THREADS", 10))
POLL = Float(ENV.fetch("POLL", 1))
PROCESS = ENV.fetch("PROCESS", "1") != "0"
DUE_IN = Float(ENV.fetch("DUE_IN", 5 + (COUNT / 20_000.0)))

# Turns the scheduled jobs into retries, keeping their scores.
def make_retries(system)
  keys = Bench::KEYS.fetch(system)
  redis = Bench.redis
  failed_at = (Time.now.to_f * 1000).to_i
  (0...COUNT).step(1_000) do |from|
    entries = redis.call("ZRANGE", keys.fetch(:schedule), from, from + 999, "WITHSCORES")
    retries = entries.flat_map do |raw, score|
      job = JSON.parse(raw).merge("error_class" => "RuntimeError", "error_message" => "bench",
        "failed_at" => failed_at, "retry_count" => 0)
      job.delete("at")
      [score, JSON.generate(job)]
    end
    redis.call("ZADD", keys.fetch(:retry), *retries)
  end
  redis.call("DEL", keys.fetch(:schedule))
end

def child(system, set)
  sys = Bench.system(system)
  label = sys.boot
  Bench::Jobs.define(sys)
  Bench::Jobs.expect(COUNT)
  key = Bench::KEYS.fetch(system).fetch(set.to_sym)

  due_at = Time.now.to_f + DUE_IN
  start = Bench.now
  (0...COUNT).each_slice(1_000) { |slice| sys.push_bulk(NoopJob, slice.map { |i| ["string", i, {"mike" => "bob"}] }, at: due_at) }
  push_secs = Bench.now - start
  make_retries(system) if set == "retry"
  abort "pushing took longer than DUE_IN (#{DUE_IN}s); raise DUE_IN" if Time.now.to_f > due_at
  raise "expected #{COUNT} jobs in #{key}" unless Bench.redis.call("ZCARD", key) == COUNT

  sleep(due_at - Time.now.to_f + 0.01)
  before = Bench.redis_usage
  start = Bench.now
  server = sys.server(threads: THREADS, poll: POLL, queues: PROCESS ? %w[default] : %w[elsewhere])
  server.run
  first = nil
  loop do
    left = Bench.redis.call("ZCARD", key)
    first ||= Bench.now if left < COUNT
    break if left.zero?

    sleep(0.01)
  end
  moved = Bench.now
  moved_usage = Bench.redis_usage
  Bench::Jobs.wait if PROCESS
  done = Bench.now
  server.stop

  {system: system, label: label, set: set, count: COUNT, threads: THREADS, poll: POLL, push_secs: push_secs.round(3),
   first_move_secs: (first - start).round(3), all_moved_secs: (moved - start).round(3),
   moved_per_sec: (COUNT / (moved - first)).round,
   all_done_secs: (PROCESS ? (done - start).round(3) : nil),
   # Redis CPU while moving, per job.
   redis_cpu_us_per_job: ((moved_usage[:cpu] - before[:cpu]) * 1e6 / COUNT).round(1),
   redis_commands_per_job: ((moved_usage[:commands] - before[:commands]).to_f / COUNT).round(2)}
end

if ARGV.first == "--child"
  puts JSON.generate(child(ARGV.fetch(1), ARGV.fetch(2)))
  exit
end

SETS = ENV.fetch("SETS", "schedule,retry").split(",")
RUNS = Integer(ENV.fetch("RUNS", 3))
Bench.claim_database!
raw = []
rows = []
SETS.each do |set|
  results = Hash.new { |h, k| h[k] = [] }
  RUNS.times do |run|
    Bench.order(run).each do |system|
      Bench.flush
      result = Bench.run_json("scheduled.rb", "--child", system, set)
      raw << result
      results[system] << result
      warn format("%-8s %-7s %8d jobs/s moved, all moved after %.2fs", set, system, result["moved_per_sec"], result["all_moved_secs"])
    end
  end
  results.each do |system, runs|
    med = ->(key) { Bench.median(runs.map { |r| r.fetch(key) }) }
    rows << [runs.first.fetch("label"), set, COUNT, "#{med.call("first_move_secs")} s", med.call("moved_per_sec"),
      "#{med.call("all_moved_secs")} s", (PROCESS ? "#{med.call("all_done_secs")} s" : "-"),
      "#{med.call("redis_cpu_us_per_job")} µs", med.call("redis_commands_per_job")]
  end
end

Bench.report("Scheduled jobs coming due: #{COUNT} jobs due at once, #{THREADS} threads, POLL=#{POLL}s, " \
  "#{PROCESS ? "jobs run" : "jobs only moved"}, median of #{RUNS}",
  ["system", "set", "jobs", "first job moved", "move rate (jobs/s)", "all moved", "all run", "Redis CPU/job (moving)",
    "Redis commands/job (moving)"],
  rows, [:left, :left] + [:right] * 7, raw)
