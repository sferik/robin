# frozen_string_literal: true

# One measurement: push COUNT no-op jobs to an empty Redis database, then
# start an in-process server and time how long it takes to run them all.
# Prints a single JSON line. Run through bench/compare/run.rb, which
# starts a fresh process per measurement.
#
#   BUNDLE_GEMFILE=bench/compare/Gemfile ruby bench/compare/load.rb robin
#
# WARMUP more jobs go first, pushed and run untimed, so the measurement
# starts once the JIT (JRuby's, or YJIT) has compiled the hot paths: the
# server runs WARMUP + COUNT jobs, and the processing figures cover the
# jobs after the first WARMUP.
#
# Environment: COUNT (default 500000), WARMUP (default 200000), THREADS
# (default 10), REDIS_URL (default redis://127.0.0.1:6379/12; it must
# start empty, unless BENCH_FLUSH=1, and is emptied afterwards).

require "bundler/setup"
require "json"
require "logger"

SYSTEM = ARGV.fetch(0)
COUNT = Integer(ENV.fetch("COUNT", 500_000))
WARMUP = Integer(ENV.fetch("WARMUP", 200_000))
THREADS = Integer(ENV.fetch("THREADS", 10))
REDIS_URL = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/12")
BATCH = 1_000

# The same arguments for both: a string, an integer and a small hash, so
# every job pays for real JSON encoding and decoding.
def args_for(idx) = ["string", idx, {"mike" => "bob"}]

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def rss_kb = Integer(`ps -o rss= -p #{Process.pid}`.strip)

# Process-wide CPU seconds (JRuby has no CLOCK_PROCESS_CPUTIME_ID).
def cpu = Process.times.then { |t| t.utime + t.stime }

# Redis's own CPU seconds and commands run so far, from INFO.
def redis_usage(info)
  fields = info.lines.map { |line| line.chomp.split(":", 2) }.select { |pair| pair.size == 2 }.to_h
  cpu = Float(fields.fetch("used_cpu_user")) + Float(fields.fetch("used_cpu_sys"))
  [cpu, Integer(fields.fetch("total_commands_processed"))]
end

# Counts finished jobs and wakes the main thread once the warmup jobs are
# done (WARM) and after the last one (DONE).
module Finish
  LOCK = Mutex.new
  WARM = Thread::Queue.new
  DONE = Thread::Queue.new
  @count = 0

  def self.one
    LOCK.synchronize do
      @count += 1
      WARM << true if @count == WARMUP
      DONE << true if @count == WARMUP + COUNT
    end
  end

  def self.count = LOCK.synchronize { @count }
end

# What each system needs: its job class, how to empty the database, push a
# batch, and start and stop an in-process server.
module RobinSystem
  def self.boot
    require "robin"
    # A benchmark of the pure-Ruby parser is asked for, never fallen into.
    if Robin::Redis::PARSER == Robin::Redis::RESP && ENV.fetch("ROBIN_NO_EXT", "").empty?
      abort "Robin's native extension isn't loaded; run `rake compile`, or set ROBIN_NO_EXT=1 to measure pure Ruby"
    end

    Object.const_set(:LoadJob, Class.new do
      include Robin::Job

      def perform(_string, _idx, _hash) = Finish.one
    end)
    Robin.configure do |config|
      config.redis = {url: REDIS_URL}
      config.logger = Logger.new($stderr, level: Logger::WARN)
    end
    "Robin #{Robin::VERSION} (#{Robin::Redis::PARSER.name.split("::").last} parser)"
  end

  def self.flush = Robin.redis { |c| c.call("FLUSHDB") }

  def self.size = Robin.redis { |c| c.call("DBSIZE") }

  def self.info = Robin.redis { |c| c.call("INFO") }

  def self.push(args) = Robin::Client.push_bulk("class" => LoadJob, "args" => args)

  def self.start
    @server = Robin.configure_embed do |config|
      config.concurrency = THREADS
      config.queues = %w[default]
    end
    @server.run
  end

  def self.stop = @server.stop
end

# Sidekiq's C driver for redis-client, where it's installed (CRuby), as
# Robin uses its C extension there.
SIDEKIQ_DRIVER = begin
  require "hiredis-client"
  :hiredis
rescue LoadError
  :ruby
end
SIDEKIQ_REDIS = {url: REDIS_URL, driver: SIDEKIQ_DRIVER}.freeze

module SidekiqSystem
  def self.boot
    require "sidekiq"

    Object.const_set(:LoadJob, Class.new do
      include Sidekiq::Job

      def perform(_string, _idx, _hash) = Finish.one
    end)
    Sidekiq.configure_client do |config|
      config.redis = SIDEKIQ_REDIS
      config.logger.level = Logger::WARN
    end
    "Sidekiq #{Sidekiq::VERSION} (#{SIDEKIQ_DRIVER} driver)"
  end

  def self.flush = Sidekiq.redis(&:flushdb)

  def self.size = Sidekiq.redis(&:dbsize)

  def self.info = Sidekiq.redis { |c| c.call("INFO") }

  def self.push(args) = Sidekiq::Client.push_bulk("class" => LoadJob, "args" => args)

  def self.start
    @server = Sidekiq.configure_embed do |config|
      config.redis = SIDEKIQ_REDIS
      config.concurrency = THREADS
      config.queues = %w[default]
      config.logger.level = Logger::WARN
    end
    @server.run
  end

  def self.stop = @server.stop
end

system = {"robin" => RobinSystem, "sidekiq" => SidekiqSystem}.fetch(SYSTEM)
label = system.boot

# Never clear a database someone else is using.
if system.size.positive? && ENV["BENCH_FLUSH"].to_s.empty?
  abort "#{REDIS_URL} isn't empty; point REDIS_URL at a spare database or set BENCH_FLUSH=1 to clear it"
end
system.flush

# Pushes +count+ jobs, numbered from +from+.
def push(system, from, count)
  (count / BATCH).times { |b| system.push(Array.new(BATCH) { |i| args_for(from + (b * BATCH) + i) }) }
  rest = count % BATCH
  system.push(Array.new(rest) { |i| args_for(from + count - rest + i) }) unless rest.zero?
end

push(system, 0, WARMUP)
start = now
push(system, WARMUP, COUNT)
push_secs = now - start

GC.start
rss_before = rss_kb
system.start
Finish::WARM.pop unless WARMUP.zero?
# From here on, with the JIT warm: the jobs run since, and what they cost.
warm_count = Finish.count
redis_before = redis_usage(system.info)
cpu_before = cpu
start = now
Finish::DONE.pop
run_secs = now - start
measured = WARMUP + COUNT - warm_count
cpu_secs = cpu - cpu_before
redis_after = redis_usage(system.info)
rss_after = rss_kb
system.stop
system.flush

puts JSON.generate(
  system: SYSTEM, label: label, ruby: RUBY_DESCRIPTION, count: COUNT, threads: THREADS,
  push_secs: push_secs.round(3), run_secs: run_secs.round(3),
  warmup: WARMUP, measured: measured,
  jobs_per_sec: (measured / run_secs).round, rss_before_kb: rss_before, rss_after_kb: rss_after,
  # Per job, while running: Ruby CPU, Redis CPU and Redis commands.
  cpu_us_per_job: (cpu_secs * 1e6 / measured).round(1),
  redis_cpu_us_per_job: ((redis_after[0] - redis_before[0]) * 1e6 / measured).round(1),
  redis_commands_per_job: ((redis_after[1] - redis_before[1]).to_f / measured).round(2)
)
