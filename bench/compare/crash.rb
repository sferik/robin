# frozen_string_literal: true

# Crash test: kill -9 a server mid-run, start a fresh one, and count what
# happened to every job. Each job sleeps SLEEP seconds and then counts its
# run in a Redis hash (HINCRBY bench:runs <idx> 1), so afterwards:
#
# - lost: jobs that never finished a run
# - run twice: jobs that finished more than once (a job killed mid-sleep
#   hadn't finished, so running it again isn't counted as a second run)
#
# Steps, per measurement: push JOBS jobs; start a server (worker.rb); once
# KILL_AFTER jobs have finished, SIGKILL it and at once start a fresh
# server; wait until every job has finished or WAIT seconds have passed
# since the kill.
#
# What to expect. Robin keeps fetched jobs in its process's in-flight keys;
# the cluster leader moves a dead process's jobs back to their queue once
# its heartbeat key has expired (process_ttl) and the leader's recovery
# runs (every 30 s, and when a process becomes the leader). The killed
# process was the leader, so the fresh one only takes over when the
# leader lease runs out (20 s, fixed). To keep the wait short this sets
# Robin's process_ttl to 10 s (default 60) and heartbeat_interval to 2 s
# (default 5), so its recovery should come about 20–25 s after the kill.
# Sidekiq OSS's fetch (BRPOP) removes a job from Redis when it's fetched;
# nothing puts back the jobs a killed process was running (Sidekiq Pro's
# super_fetch does). Its settings are left at their defaults.
#
#   BUNDLE_GEMFILE=bench/compare/Gemfile ruby bench/compare/crash.rb
#
# Environment:
#   SYSTEMS      robin,sidekiq
#   JOBS         1000        jobs per measurement
#   SLEEP        0.05        seconds each job sleeps
#   KILL_AFTER   JOBS / 4    finished jobs before the kill
#   THREADS      10          server threads
#   WAIT         60          seconds to wait after the kill
#   HEARTBEAT    2           Robin's heartbeat_interval
#   PROCESS_TTL  10          Robin's process_ttl
#   RUNS         2           measurements per system
#   REDIS_URL    redis://127.0.0.1:6379/12 (emptied before and after)

require_relative "support"

JOBS = Integer(ENV.fetch("JOBS", 1_000))
SLEEP = ENV.fetch("SLEEP", "0.05")
KILL_AFTER = Integer(ENV.fetch("KILL_AFTER", JOBS / 4))
THREADS = Integer(ENV.fetch("THREADS", 10))
WAIT = Float(ENV.fetch("WAIT", 60))
RUNS = Integer(ENV.fetch("RUNS", 2))
WORKER_ENV = {"THREADS" => THREADS.to_s, "REDIS_URL" => Bench::REDIS_URL,
              "HEARTBEAT" => ENV.fetch("HEARTBEAT", "2"), "PROCESS_TTL" => ENV.fetch("PROCESS_TTL", "10")}.freeze

def finished = Bench.redis.call("HLEN", Bench::RUNS_KEY)

def measure(system)
  Bench.flush
  queue = Bench::KEYS.fetch(system).fetch(:queue)
  Bench.run_json("push.rb", system, "sleep", JOBS, env: {"SLEEP" => SLEEP})
  first, pids, label = Bench.start_workers(system, WORKER_ENV)
  sleep(0.01) until finished >= KILL_AFTER
  Process.kill("KILL", pids.first)
  killed = Bench.now
  first.close # reaps it
  done_at_kill = finished
  # Fetched but not finished: running, or fetched ahead of a worker.
  in_flight = JOBS - Bench.redis.call("LLEN", queue) - done_at_kill

  second, = Bench.start_workers(system, WORKER_ENV)
  restarted = Bench.now - killed
  drained = nil
  begin
    until finished == JOBS || Bench.now - killed > WAIT
      drained ||= Bench.now - killed if Bench.redis.call("LLEN", queue).zero?
      sleep(0.05)
    end
    all_done = (Bench.now - killed if finished == JOBS)
    sleep(1) # let any job still running finish and count itself
    runs = Bench.redis.call("HVALS", Bench::RUNS_KEY).map { |v| Integer(v) }
  ensure
    Bench.stop_workers(second)
  end

  {system: system, label: label, jobs: JOBS, threads: THREADS, sleep: Float(SLEEP),
   finished_at_kill: done_at_kill, in_flight_at_kill: in_flight,
   lost: JOBS - runs.size, run_twice: runs.count { |n| n > 1 }, extra_runs: runs.sum - runs.size,
   restart_secs: restarted.round(2), queue_drained_secs: drained&.round(2), all_done_secs: all_done&.round(2)}
end

Bench.claim_database!
raw = []
RUNS.times do |run|
  Bench.order(run).each do |system|
    result = measure(system)
    raw << result
    warn format("%-7s in flight at kill %3d, lost %3d, ran twice %3d, all done %s", system, result[:in_flight_at_kill],
      result[:lost], result[:run_twice], result[:all_done_secs] ? "#{result[:all_done_secs]}s after the kill" : "never")
  end
end

rows = raw.map do |r|
  [r[:label], r[:jobs], r[:finished_at_kill], r[:in_flight_at_kill], r[:lost], r[:run_twice],
    r[:queue_drained_secs] ? "#{r[:queue_drained_secs]} s" : "-", r[:all_done_secs] ? "#{r[:all_done_secs]} s" : "never"]
end
Bench.report("Crash test: #{JOBS} jobs of #{SLEEP}s, #{THREADS} threads, kill -9 after #{KILL_AFTER} finished, " \
  "fresh server at once, waiting up to #{WAIT}s; Robin with heartbeat_interval #{WORKER_ENV["HEARTBEAT"]}s, " \
  "process_ttl #{WORKER_ENV["PROCESS_TTL"]}s",
  ["system", "jobs", "finished before kill", "in flight at kill", "lost", "run twice", "queue empty after kill",
    "all finished after kill"],
  rows, [:left] + [:right] * 7, raw)
