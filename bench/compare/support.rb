# frozen_string_literal: true

# Shared by the scenario benchmarks in bench/compare (cluster.rb,
# scheduled.rb, idle.rb, payloads.rb, crash.rb, pickup.rb) and their
# helper processes (worker.rb, push.rb). load.rb and run.rb predate it and
# stand alone.
#
# Two halves:
# - Bench: the harness side. It talks to Redis through a plain redis-client
#   connection (neither system's), starts child processes, and prints
#   tables.
# - Bench::RobinSystem and Bench::SidekiqSystem: what a child process needs
#   from each system, through that system's own API (the real sidekiq gem
#   for Sidekiq, Robin's own API for Robin).

require "bundler/setup"
require "etc"
require "json"
require "logger"
require "redis_client"
require "rbconfig"

module Bench
  HERE = __dir__
  REDIS_URL = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/12")
  SYSTEMS = ENV.fetch("SYSTEMS", "robin,sidekiq").split(",")

  # Where each system keeps the keys the harness looks at directly.
  KEYS = {
    "robin" => {queue: "robin:queue:default", schedule: "robin:schedule", retry: "robin:retry"},
    "sidekiq" => {queue: "queue:default", schedule: "schedule", retry: "retry"}
  }.freeze

  # Keys the bench jobs write to (both systems use the same ones).
  RUNS_KEY = "bench:runs"
  PICKUP_KEY = "bench:pickup"

  module_function

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Process-wide CPU seconds (JRuby has no CLOCK_PROCESS_CPUTIME_ID).
  def cpu = Process.times.then { |t| t.utime + t.stime }

  def median(values) = values.sort[values.size / 2]

  # Nearest-rank percentile of +values+ (0 < fraction <= 1).
  def percentile(values, fraction)
    sorted = values.sort
    sorted[[(sorted.size * fraction).ceil - 1, 0].max]
  end

  # Alternate the order run by run, so drift on the machine hits both alike.
  def order(run) = run.even? ? SYSTEMS : SYSTEMS.reverse

  def env_list(name, default) = ENV.fetch(name, default).split(",").map { |v| Integer(v) }

  # The harness's own connection.
  def redis = @redis ||= RedisClient.config(url: REDIS_URL).new_client

  # Redis's own CPU seconds and commands run so far, from INFO.
  def redis_usage(info = redis.call("INFO"))
    fields = info.lines.map { |line| line.chomp.split(":", 2) }.select { |pair| pair.size == 2 }.to_h
    {cpu: Float(fields.fetch("used_cpu_user")) + Float(fields.fetch("used_cpu_sys")),
     commands: Integer(fields.fetch("total_commands_processed")),
     ops_per_sec: Integer(fields.fetch("instantaneous_ops_per_sec")),
     clients: Integer(fields.fetch("connected_clients"))}
  end

  # Never clear a database someone else is using.
  def claim_database!
    if redis.call("DBSIZE").positive? && ENV["BENCH_FLUSH"].to_s.empty?
      abort "#{REDIS_URL} isn't empty; point REDIS_URL at a spare database or set BENCH_FLUSH=1 to clear it"
    end
    flush
    at_exit { flush }
  end

  def flush = redis.call("FLUSHDB")

  # Runs a Ruby script in a fresh process and returns its last line, parsed.
  def run_json(script, *args, env: {})
    out = IO.popen(env, [RbConfig.ruby, File.join(HERE, script), *args.map(&:to_s)], &:read)
    raise "#{script} #{args.join(" ")} failed" unless $?.success?

    JSON.parse(out.lines.last)
  end

  # Starts worker.rb (FORKS server processes of +system+) and waits until
  # every one has started. Returns [io, pids, label]; stop it with
  # #stop_workers.
  def start_workers(system, env)
    io = IO.popen(env, [RbConfig.ruby, File.join(HERE, "worker.rb"), system])
    ready = Array.new(Integer(env.fetch("FORKS", 1))) do
      JSON.parse(io.gets || raise("#{system} worker exited before it was ready"))
    end
    [io, ready.map { |r| r.fetch("pid") }, ready.first.fetch("label")]
  end

  # Graceful stop, then SIGKILL if it takes longer than +wait+ seconds.
  def stop_workers(io, wait: 60)
    Process.kill("TERM", io.pid)
    deadline = now + wait
    sleep(0.05) until Process.waitpid(io.pid, Process::WNOHANG) || now > deadline
    if now > deadline
      warn "worker #{io.pid} didn't stop within #{wait}s; killing it"
      Process.kill("KILL", io.pid)
      Process.waitpid(io.pid)
    end
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    io.close
  end

  # Resident memory of +pids+, in KB.
  def rss_kb(pids) = `ps -o rss= -p #{pids.join(",")}`.split.sum { |v| Integer(v) }

  def table(headers, rows, align)
    puts "| #{headers.join(" | ")} |"
    puts "|#{align.map { |a| (a == :right) ? "--:" : "---" }.join("|")}|"
    rows.each { |row| puts "| #{row.join(" | ")} |" }
  end

  # Prints a header, the table, any notes and every raw result as JSON.
  def report(title, headers, rows, align, raw, notes: [])
    puts RUBY_DESCRIPTION
    puts title
    puts
    table(headers, rows, align)
    puts
    notes.each { |note| puts "- #{note}" }
    puts unless notes.empty?
    puts "Raw results:"
    puts
    raw.each { |r| puts JSON.generate(r) }
  end

  # Picks a system's adapter, for child processes.
  def system(name) = {"robin" => RobinSystem, "sidekiq" => SidekiqSystem}.fetch(name)

  # Settings a child applies to its server, from the environment. Unset ones
  # keep the system's default.
  #   THREADS     worker threads (both)
  #   POLL        seconds between scheduler polls (Robin: poll_interval;
  #               Sidekiq: poll_interval_average, which also skips its
  #               10-second initial wait)
  #   HEARTBEAT   Robin's heartbeat_interval (Sidekiq's is fixed at 10s)
  #   PROCESS_TTL Robin's process_ttl (Sidekiq's is fixed at 60s)
  def server_settings
    {threads: Integer(ENV.fetch("THREADS", 10)), poll: ENV["POLL"]&.then { Float(it) },
     heartbeat: ENV["HEARTBEAT"]&.then { Float(it) }, process_ttl: ENV["PROCESS_TTL"]&.then { Integer(it) }}
  end

  # The jobs the benchmarks run, defined for either system.
  module Jobs
    module_function

    def define(sys)
      sys.job(:NoopJob) { |*| Bench::Jobs.done }
      # Sleeps, then counts this run of job +idx+.
      sys.job(:SleepJob) do |idx, secs|
        sleep(secs)
        sys.redis { |c| c.call("HINCRBY", RUNS_KEY, idx, 1) }
      end
      # Records how long after its push (wall clock, epoch seconds) it started.
      sys.job(:PickupJob) do |pushed_at|
        latency = Time.now.to_f - pushed_at
        sys.redis { |c| c.call("RPUSH", PICKUP_KEY, latency) }
      end
    end

    # Optional in-process completion count: #expect, then #wait (and
    # #wait_warm, for the first +warmup+ of them).
    LOCK = Mutex.new
    WARM = Thread::Queue.new
    DONE = Thread::Queue.new
    @count = 0
    @expected = nil
    @warmup = nil

    def expect(count, warmup: nil)
      @expected = count
      @warmup = warmup
    end

    def wait = DONE.pop

    def wait_warm = WARM.pop

    def count = LOCK.synchronize { @count }

    def done
      LOCK.synchronize do
        @count += 1
        WARM << true if @count == @warmup
        DONE << true if @count == @expected
      end
    end
  end

  module RobinSystem
    module_function

    def boot
      require "robin"
      # A benchmark of the pure-Ruby parser is asked for, never fallen into.
      if Robin::Redis::PARSER == Robin::Redis::RESP && ENV.fetch("ROBIN_NO_EXT", "").empty?
        abort "Robin's native extension isn't loaded; run `rake compile`, or set ROBIN_NO_EXT=1 to measure pure Ruby"
      end

      Robin.configure do |config|
        config.redis = {url: REDIS_URL}
        config.logger = Logger.new($stderr, level: Logger::WARN)
      end
      "Robin #{Robin::VERSION} (#{Robin::Redis::PARSER.name.split("::").last} parser)"
    end

    def job(name, &perform)
      Object.const_set(name, Class.new do
        include Robin::Job

        define_method(:perform, &perform)
      end)
    end

    def redis(&) = Robin.redis(&)

    def push_bulk(klass, args, at: nil) = Robin::Client.push_bulk({"class" => klass, "args" => args, "at" => at}.compact)

    def push(klass, args) = Robin::Client.push("class" => klass, "args" => args)

    def server(threads:, queues: %w[default], poll: nil, heartbeat: nil, process_ttl: nil)
      Robin.configure_embed do |config|
        config.concurrency = threads
        config.queues = queues
        config.poll_interval = poll if poll
        config.heartbeat_interval = heartbeat if heartbeat
        config.process_ttl = process_ttl if process_ttl
      end
    end
  end

  module SidekiqSystem
    module_function

    # Sidekiq's C driver for redis-client, where it's installed (CRuby), as
    # Robin uses its C extension there.
    def driver
      @driver ||= begin
        require "hiredis-client"
        :hiredis
      rescue LoadError
        :ruby
      end
    end

    def redis_options = {url: REDIS_URL, driver: driver}

    def boot
      require "sidekiq"
      require "sidekiq/api"

      Sidekiq.configure_client do |config|
        config.redis = redis_options
        config.logger.level = Logger::WARN
      end
      "Sidekiq #{Sidekiq::VERSION} (#{driver} driver)"
    end

    def job(name, &perform)
      Object.const_set(name, Class.new do
        include Sidekiq::Job

        define_method(:perform, &perform)
      end)
    end

    def redis(&) = Sidekiq.redis(&)

    def push_bulk(klass, args, at: nil) = Sidekiq::Client.push_bulk({"class" => klass, "args" => args, "at" => at}.compact)

    def push(klass, args) = Sidekiq::Client.push("class" => klass, "args" => args)

    # HEARTBEAT and PROCESS_TTL have no Sidekiq setting and are ignored.
    def server(threads:, queues: %w[default], poll: nil, heartbeat: nil, process_ttl: nil)
      Sidekiq.configure_embed do |config|
        config.redis = redis_options
        config.concurrency = threads
        config.queues = queues
        config[:poll_interval_average] = poll if poll
        config.logger.level = Logger::WARN
      end
    end
  end
end
