# frozen_string_literal: true

require_relative "test_helper"
require "socket"

# The swarm supervisor with simulated processes and time.
class SwarmUnitTest < RobinTest
  cover "Robin::Swarm*"

  Status = Struct.new(:exitstatus, :termsig)

  class FakeOS
    attr_accessor :fork_available, :exit_on, :ready_on_sleep, :signals
    attr_reader :forks, :spawns, :kills, :sleeps, :thread_sleeps, :resets, :exits, :exited, :traps
    attr_writer :clock

    def initialize(test)
      @test = test
      @main = Thread.current
      @next_pid = 1000
      @forks = []
      @spawns = []
      @kills = []
      @sleeps = []
      @thread_sleeps = []
      @killed = [] # exits only a blocking wait sees
      @resets = []
      @exits = 0
      @exited = []
      @signals = []
      @clock = 0.0
      @fork_available = true
      @exit_on = %w[TERM KILL] # signals that make a fake child exit
      @ready_on_sleep = nil # pid to start heartbeating on the next sleep
    end

    def fork? = @fork_available

    def warmup = @warmups = warmups + 1

    def warmups = @warmups || 0

    def fork(&block)
      @forks << block
      @next_pid += 1
    end

    def spawn(env, *command)
      @spawns << [env, command]
      @next_pid += 1
    end

    def kill(pid, signal)
      @kills << [pid, signal]
      return unless @exit_on.include?(signal)

      status = Status.new(nil, Signal.list[signal])
      (signal == "KILL") ? @killed << [pid, status] : exit_child(pid, status)
    end

    def exit_child(pid, status = Status.new(0, nil)) = @exited << [pid, status]

    def wait(block: false)
      return @exited.shift unless block

      @exited.shift || @killed.shift || raise("would block forever")
    end

    def now = @clock

    def sleep(seconds)
      if Thread.current != @main # a watcher thread: note it, then park it
        @thread_sleeps << seconds
        Kernel.sleep
      end
      @sleeps << seconds
      @clock += seconds
      if (pid = @ready_on_sleep)
        @ready_on_sleep = nil
        @test.heartbeat(pid)
      end
    end

    def trap_signals(signals)
      @traps = signals
      :reader
    end

    def reset_signals(signals) = @resets << signals

    def read_signals(reader, timeout)
      raise "unexpected reader" unless reader == :reader

      @clock += timeout
      sig = @signals.shift
      sig ? [sig] : []
    end

    def finish_child = @exits += 1
  end

  class FakeCLI
    attr_reader :config, :options, :booted, :served

    def initialize(config, options = {})
      @config = config
      @options = options
      @booted = 0
      @served = 0
    end

    def boot = @booted += 1

    def serve = @served += 1
  end

  def setup
    super
    @os = FakeOS.new(self)
    @log = StringIO.new
    config.logger = Logger.new(@log)
    config.timeout = 1
    ENV.delete("ROBIN_SWARM_MODE")
    ENV.delete("ROBIN_SWARM_COUNT")
  end

  def teardown
    ENV.delete("ROBIN_SWARM_MODE")
    ENV.delete("ROBIN_SWARM_COUNT")
    ENV.delete("ROBIN_SWARM_INDEX")
    super
  end

  def swarm(options = {processes: 2}) = Robin::Swarm.new(FakeCLI.new(config, options), os: @os)

  def heartbeat(pid, hostname: Socket.gethostname)
    identity = "#{hostname}:#{pid}:x"
    redis("SADD", config.key("processes"), identity)
    redis("HSET", config.process_key(identity), "info", JSON.generate({"pid" => pid, "hostname" => hostname}))
  end

  # -- construction --------------------------------------------------------------

  def test_count
    assert_equal 3, swarm({processes: 3}).count
    ENV["ROBIN_SWARM_COUNT"] = "4"

    assert_equal 4, swarm({}).count
    ENV.delete("ROBIN_SWARM_COUNT")

    assert_equal Etc.nprocessors, swarm({}).count
    assert_raises(ArgumentError) { swarm({processes: "lots"}) }
    ENV["ROBIN_SWARM_COUNT"] = "4"

    assert_equal 2, swarm({processes: "2"}).count
  ensure
    ENV.delete("ROBIN_SWARM_COUNT")
  end

  def test_process_count
    {nil => 8, 3 => 3, "3" => 3, "0.5" => 4, "1.5" => 12, "2.0" => 16, "0.01" => 1, "0.07" => 1, "0.19" => 2, 0.5 => 4}.each do |value, count|
      assert_equal count, Robin::Swarm.process_count(value, 8), value.inspect
      assert_instance_of Integer, Robin::Swarm.process_count(value, 8)
    end
    assert_equal Etc.nprocessors, Robin::Swarm.process_count(nil)
    assert_equal Etc.nprocessors, Robin::Swarm.process_count("1.0")
    ["0", "-2", "0.0", "-0.5"].each do |bad|
      e = assert_raises(ArgumentError) { Robin::Swarm.process_count(bad, 8) }
      assert_equal "the swarm's process count must be positive: #{bad}", e.message
    end
    ["lots", "1.5x", "", "1e3"].each { |bad| assert_raises(ArgumentError) { Robin::Swarm.process_count(bad, 8) } }
  end

  def test_mode
    assert_equal "fork", swarm.mode
    @os.fork_available = false

    assert_equal "spawn", swarm.mode
    ENV["ROBIN_SWARM_MODE"] = "fork"

    assert_equal "fork", swarm.mode
  end

  def test_real_os_by_default
    s = Robin::Swarm.new(FakeCLI.new(config, processes: 1))

    assert_equal Process.respond_to?(:fork) ? "fork" : "spawn", s.mode
  end

  # -- spawn command -----------------------------------------------------------

  def test_child_arguments
    s = swarm({processes: 2, require: "app.rb", config_file: "robin.yml", environment: "production", concurrency: 7,
               timeout: 9, tag: "web", queues: ["critical,3", ["low", 1], :default], verbose: true, json_logs: true})

    assert_equal ["-r", "app.rb", "-C", "robin.yml", "-e", "production", "-c", "7", "-t", "9", "-g", "web",
      "-q", "critical,3", "-q", "low,1", "-q", "default", "-v", "--json-logs"], s.child_arguments
    assert_empty swarm({processes: 1}).child_arguments
    assert_empty swarm({processes: 1, tag: nil, verbose: false, json_logs: nil, queues: nil}).child_arguments
  end

  def test_child_command_and_env
    s = swarm({processes: 1, concurrency: 2})

    assert_equal [RbConfig.ruby, "-r", "robin/swarm", Robin::Swarm::EXE, "-c", "2"], s.child_command
    assert_path_exists Robin::Swarm::EXE
    assert_path_exists File.join(Robin::Swarm::LIB, "robin", "swarm.rb")
    previous = ENV["RUBYLIB"]
    ENV["RUBYLIB"] = "/elsewhere"

    assert_equal({"ROBIN_SWARM_INDEX" => "3", "ROBIN_SWARM_PARENT" => Process.pid.to_s,
                  "RUBYLIB" => "#{Robin::Swarm::LIB}#{File::PATH_SEPARATOR}/elsewhere"}, s.child_env(3))
    ENV.delete("RUBYLIB")

    assert_equal Robin::Swarm::LIB, s.child_env(0)["RUBYLIB"]
  ensure
    ENV["RUBYLIB"] = previous
  end

  # -- starting children -------------------------------------------------------

  def test_start_child_forks
    s = swarm
    @os.clock = 5.0
    child = s.start_child(1)

    assert_equal [1001, 1, 5.0, false], child.to_a
    assert_same child, s.children[1001]
    assert_equal 1, @os.forks.size
    assert_empty @os.spawns
    assert_includes @log.string, "swarm child 1 started (pid 1001)"
  end

  def test_start_child_spawns
    @os.fork_available = false
    s = swarm({processes: 1, concurrency: 3})
    s.start_child(0)
    env, command = @os.spawns.first

    assert_equal "0", env["ROBIN_SWARM_INDEX"]
    assert_equal s.child_command, command
    assert_empty @os.forks
  end

  def test_child_main
    cli = FakeCLI.new(config, processes: 1)
    forked = []
    config.on(:fork) { forked << [ENV["ROBIN_SWARM_INDEX"], cli.served] }
    s = Robin::Swarm.new(cli, os: @os)
    s.start_child(4)

    assert_empty forked
    @os.forks.first.call

    assert_equal [["4", 0]], forked, "fired in the child, before it serves"
    assert_equal [Robin::Swarm::SIGNALS], @os.resets
    assert_equal "4", ENV["ROBIN_SWARM_INDEX"]
    assert_equal 1, cli.served
    assert_equal 1, @os.exits
    watcher = Thread.list.find { |t| t.name == "robin.swarm.watch" }
    eventually { @os.thread_sleeps.any? }

    assert_equal [1], @os.thread_sleeps
    assert_empty @os.kills
  ensure
    watcher&.kill
  end

  # -- reaping and restarts ----------------------------------------------------

  def test_crashed_children_restart_with_growing_delay
    s = swarm
    child = s.start_child(0)
    @os.clock = 1.0
    @os.exit_child(child.pid, Status.new(1, nil))
    s.reap

    assert_empty s.children
    assert_includes @log.string, "swarm child 0 (pid 1001) exited 1; restarting in 2s"
    @os.clock = 2.9
    s.start_due_restarts

    assert_empty s.children
    @os.clock = 3.0
    s.start_due_restarts
    second = s.children.values.first

    assert_equal 0, second.index
    @os.clock = 4.5
    @os.exit_child(second.pid, Status.new(nil, 9))
    s.reap

    assert_includes @log.string, "exited 9; restarting in 4s"
    @os.clock = 9.0 # well past the restart time
    s.start_due_restarts

    assert_equal 1, s.children.size
  end

  def test_child_exits_are_events
    events = []
    config.event_handlers << ->(name, payload) { events << [name, payload] }
    s = swarm
    first = s.start_child(1)
    @os.exit_child(first.pid, Status.new(3, nil))
    s.reap
    second = s.start_child(1)
    @os.exit_child(second.pid, Status.new(nil, 9))
    s.reap
    @os.clock = 100.0
    third = s.start_child(1)
    @os.clock = 100.0 + Robin::Swarm::MIN_UPTIME
    @os.exit_child(third.pid)
    s.reap

    assert_equal [["swarm.child_exited", {index: 1, pid: first.pid, status: 3, delay: 2}],
      ["swarm.child_exited", {index: 1, pid: second.pid, status: 9, delay: 4}],
      ["swarm.child_exited", {index: 1, pid: third.pid, status: 0, delay: 0}]], events
    assert_equal [1001, 1002, 1003], [first, second, third].map(&:pid)
  end

  def test_crash_delay_is_capped_and_resets_after_a_healthy_run
    s = swarm
    7.times do
      child = s.start_child(0)
      @os.exit_child(child.pid)
      s.reap
    end

    assert_includes @log.string, "restarting in 60s"
    refute_includes @log.string, "restarting in 128s"
    child = s.start_child(0)
    @os.clock = Robin::Swarm::MIN_UPTIME
    @os.exit_child(child.pid)
    s.reap

    assert_match(/exited 0; restarting in 0s\n\z/, @log.string)
  end

  def test_short_runs_count_as_crashes_only_below_min_uptime
    s = swarm
    @os.clock = 100.0
    child = s.start_child(0)
    @os.clock = 100.0 + Robin::Swarm::MIN_UPTIME - 0.5
    @os.exit_child(child.pid)
    s.reap

    assert_match(/restarting in 2s\n\z/, @log.string)
  end

  def test_reap_ignores_unknown_and_retiring_children
    s = swarm
    child = s.start_child(0)
    child.retiring = true
    @os.exit_child(4242)
    @os.exit_child(child.pid)
    s.reap
    s.start_due_restarts

    assert_empty s.children
    refute_includes @log.string, "restarting"
  end

  def test_blocking_reap_waits_once
    s = swarm
    a = s.start_child(0)
    b = s.start_child(1)
    @os.exit_child(a.pid)
    @os.exit_child(b.pid)
    s.reap(block: true)

    assert_empty s.children
  end

  # -- signals -----------------------------------------------------------------

  def test_quiet_and_dump_are_forwarded
    s = swarm
    a = s.start_child(0)
    b = s.start_child(1)
    s.handle("TSTP")
    s.handle("TTIN")
    s.handle("CHLD")

    assert_equal [[a.pid, "TSTP"], [b.pid, "TSTP"], [a.pid, "TTIN"], [b.pid, "TTIN"]], @os.kills
  end

  def test_shutdown
    s = swarm
    a = s.start_child(0)
    b = s.start_child(1)
    s.handle("INT")

    assert_empty s.children
    assert_equal [[a.pid, "TERM"], [b.pid, "TERM"]], @os.kills
    assert_includes @log.string, "swarm stopping 2 children"
    refute_includes @log.string, "killing"
    assert_empty @os.sleeps
    s.handle("TERM") # already stopping: nothing more

    assert_equal 2, @os.kills.size
    assert_equal 1, @log.string.scan("swarm stopping").size
  end

  def test_shutdown_kills_stragglers
    @os.exit_on = %w[KILL]
    s = swarm
    @os.clock = 100.0
    a = s.start_child(0)
    s.shutdown

    assert_equal [[a.pid, "TERM"], [a.pid, "KILL"]], @os.kills
    assert_empty s.children
    assert_includes @log.string, "killing 1 children that didn't stop in time"
    assert_in_delta 11.0, @os.sleeps.sum, 0.2 # config.timeout + 10
  end

  def test_no_restarts_while_stopping
    s = swarm
    child = s.start_child(0)
    @os.exit_child(child.pid)
    s.reap
    s.start_child(1)
    s.handle("TERM") # the pending restart of child 0 is dropped
    @os.clock = @os.now + 100
    s.start_due_restarts

    assert_empty s.children
  end

  def test_rolling_restart
    s = swarm
    a = s.start_child(0)
    b = s.start_child(1)
    @os.ready_on_sleep = 1003
    s.handle("USR2")
    s.reap(block: true)
    # replacement for 0 (pid 1003) came up, then the old one was stopped;
    # replacement for 1 (pid 1004) never heartbeated, so 1 kept running
    assert_equal [[a.pid, "TERM"], [1004, "KILL"]], @os.kills
    assert_equal [1003, b.pid].sort, s.children.keys.sort
    refute b.retiring
    assert_includes @log.string, "swarm rolling restart"
    assert_includes @log.string, "replacement for child 1 didn't start; keeping the old one"
  end

  def test_rolling_restart_goes_in_index_order_and_keeps_indexes
    s = swarm
    b = s.start_child(1)
    a = s.start_child(0)
    heartbeat(1003)
    heartbeat(1004)
    s.rolling_restart
    s.reap
    s.start_due_restarts

    assert_equal [[a.pid, "TERM"], [b.pid, "TERM"]], @os.kills
    assert_equal({1003 => 0, 1004 => 1}, s.children.transform_values(&:index))
    refute_includes @log.string, "restarting" # retired children aren't replaced again
  end

  def test_failed_replacements_are_not_restarted
    s = swarm({processes: 1})
    s.start_child(0)
    s.rolling_restart
    s.reap(block: true)
    s.start_due_restarts

    assert_equal [1001], s.children.keys
    refute_includes @log.string, "restarting"
  end

  def test_rolling_restart_needs_a_heartbeat_from_this_host
    s = swarm({processes: 1})
    s.start_child(0)
    heartbeat(1002, hostname: "elsewhere")
    s.rolling_restart

    assert_includes @log.string, "replacement for child 0 didn't start"
  end

  def test_rolling_restart_gives_up_when_the_replacement_dies
    s = swarm({processes: 1})
    old = s.start_child(0)
    @os.exit_child(1002) # the replacement crashes right away
    s.rolling_restart

    assert_equal [old.pid], s.children.keys
    assert_includes @log.string, "replacement for child 0 didn't start"
    assert_equal 0, @os.sleeps.size
  end

  def test_readiness_waits_a_minute_polling_every_second
    s = swarm({processes: 1})
    s.start_child(0)
    s.rolling_restart

    assert_equal [1] * 61, @os.sleeps
  end

  def test_readiness_uses_the_swarm_config
    s = swarm({processes: 1})
    s.start_child(0)
    heartbeat(1002)
    Robin.config = Robin::Config.new # a different keyspace
    s.rolling_restart

    refute_includes @log.string, "didn't start"
  end

  def test_rolling_restart_kills_old_children_that_hang
    s = swarm({processes: 1})
    old = s.start_child(0)
    heartbeat(1002)
    @os.exit_on = %w[KILL]
    s.rolling_restart

    assert_equal [[old.pid, "TERM"], [old.pid, "KILL"]], @os.kills
    assert_equal [1002], s.children.keys
  end

  def test_rolling_restart_skips_children_that_exit_meanwhile
    s = swarm({processes: 3})
    a = s.start_child(0)
    b = s.start_child(1)
    c = s.start_child(2)
    heartbeat(1004)
    heartbeat(1005)
    @os.exit_child(b.pid, Status.new(nil, 9)) # reaped while waiting for a's replacement
    s.rolling_restart

    assert_equal [[a.pid, "TERM"], [c.pid, "TERM"]], @os.kills
    refute s.children.key?(b.pid)
  end

  def test_no_rolling_restart_while_stopping
    s = swarm
    s.shutdown
    s.rolling_restart

    refute_includes @log.string, "rolling restart"
  end

  # -- the run loop ------------------------------------------------------------

  def test_run
    cli = FakeCLI.new(config, processes: 2)
    s = Robin::Swarm.new(cli, os: @os)
    @os.signals = [nil, "TERM"]
    s.run

    assert_equal 1, cli.booted
    assert_in_delta 2.0, @os.now
    assert_includes @log.string, "swarm child 0 started"
    assert_includes @log.string, "swarm child 1 started"
    assert_equal Robin::Swarm::SIGNALS, @os.traps
    assert_equal 2, @os.forks.size
    assert_equal 1, @os.warmups
    assert_empty s.children
    assert_includes @log.string, "swarm #{Process.pid} starting 2 children (fork)"
    assert_includes @log.string, "swarm #{Process.pid} stopped"
  end

  # Runs the block with Robin.eager_load! recording how many warmups had
  # happened at each call.
  def recording_eager_loads
    calls = []
    os = @os
    original = Robin.method(:eager_load!)
    Robin.define_singleton_method(:eager_load!) { calls << os.warmups }
    begin
      yield
    ensure
      Robin.define_singleton_method(:eager_load!, original)
    end
    calls
  end

  def test_run_eager_loads_robin_before_the_warmup
    s = swarm({processes: 1})
    @os.signals = ["TERM"]
    calls = recording_eager_loads { s.run }

    assert_equal [0], calls
    assert_equal 1, @os.warmups
  end

  def test_run_without_fork_skips_the_warmup
    ENV["ROBIN_SWARM_MODE"] = "spawn"
    s = swarm({processes: 1})
    @os.signals = ["TERM"]
    calls = recording_eager_loads { s.run }

    assert_empty calls
    assert_equal 0, @os.warmups
    assert_equal 1, @os.spawns.size
  end

  def test_warmup_on_the_real_os
    called = []
    original = Process.method(:warmup)
    Process.define_singleton_method(:warmup) { called << true }
    begin
      Robin::Swarm::OS.new.warmup
    ensure
      Process.define_singleton_method(:warmup, original)
    end

    assert_equal [true], called
  end

  def test_run_restarts_crashed_children
    s = swarm({processes: 1})
    @os.signals = [nil, nil, nil, nil, "TERM"]
    @os.define_singleton_method(:read_signals) do |reader, timeout|
      exit_child(1001) if @signals.size == 5
      super(reader, timeout)
    end
    s.run

    assert_equal 2, @os.forks.size
  end

  # -- parent watching ---------------------------------------------------------

  def test_watch_parent_stops_orphans
    os = FakeOS.new(self)
    thread = Robin::Swarm.watch_parent(-1, os: os)

    assert_instance_of Thread, thread
    thread.join

    assert_equal "robin.swarm.watch", thread.name

    assert_equal [[Process.pid, "TERM"]], os.kills
  end

  def test_watch_parent_polls_while_the_parent_lives
    os = FakeOS.new(self)
    thread = Robin::Swarm.watch_parent(Process.ppid, os: os, interval: 7)
    sleep 0.05

    assert_equal "sleep", thread.status
    assert_empty os.kills
  ensure
    thread&.kill
  end

  def test_watch_parent_from_env
    os = FakeOS.new(self)

    assert_nil Robin::Swarm.watch_parent_from_env({}, os: os)
    assert_nil Robin::Swarm.watch_parent_from_env({"ROBIN_SWARM_PARENT" => "1"}, os: os)
    thread = Robin::Swarm.watch_parent_from_env({"ROBIN_SWARM_PARENT" => Process.ppid.to_s}, os: os)
    eventually { os.thread_sleeps.any? }

    assert_kind_of Thread, thread
    assert_empty os.kills
  ensure
    thread&.kill
  end

  def with_os_new(os)
    klass = Robin::Swarm::OS
    original = klass.method(:new)
    klass.define_singleton_method(:new) { os }
    yield
  ensure
    klass.define_singleton_method(:new, original)
  end

  def test_watch_parent_defaults_to_the_real_os
    os = FakeOS.new(self)
    with_os_new(os) { Robin::Swarm.watch_parent(-1).join }

    assert_equal [[Process.pid, "TERM"]], os.kills
  end

  def test_watch_parent_from_env_defaults
    os = FakeOS.new(self)
    previous = ENV["ROBIN_SWARM_PARENT"]
    ENV["ROBIN_SWARM_PARENT"] = Process.ppid.to_s
    thread = with_os_new(os) { Robin::Swarm.watch_parent_from_env }
    eventually { os.thread_sleeps.any? }

    assert_equal [1], os.thread_sleeps
    assert_empty os.kills
  ensure
    thread&.kill
    ENV["ROBIN_SWARM_PARENT"] = previous
  end

  def test_watch_parent_default_interval
    seen = []
    os = FakeOS.new(self)
    os.define_singleton_method(:sleep) do |s|
      seen << s
      Thread.current.kill
    end
    Robin::Swarm.watch_parent(Process.ppid, os: os).join

    assert_equal [1], seen
  end

  # -- the real OS adapter -----------------------------------------------------

  def test_os_processes
    os = Robin::Swarm::OS.new

    assert_equal Process.respond_to?(:fork), os.fork?
    pid = os.spawn({"ROBIN_X" => "1"}, RbConfig.ruby, "-e", "exit(ENV['ROBIN_X'] == '1' ? 3 : 4)")
    waited, status = os.wait(block: true)

    assert_equal [pid, 3], [waited, status.exitstatus]
    assert_nil os.wait
    assert_nil os.wait(block: true)
    assert_nil os.kill(pid, "TERM") # already gone
    # Bounded, and killed in the ensure below, so a broken kill/wait (e.g. a
    # mutant) can't leave it running forever.
    sleeper = os.spawn({}, RbConfig.ruby, "-e", "sleep 30")

    assert_nil os.wait
    os.kill(sleeper, "KILL")
    _, status = os.wait(block: true)

    assert_equal Signal.list["KILL"], status.termsig
    grouped = os.spawn({}, RbConfig.ruby, "-e", "exit 7", pgroup: true)
    waited, status = os.wait(block: true)

    assert_equal [grouped, 7], [waited, status.exitstatus]
  ensure
    reap(sleeper)
  end

  def reap(pid)
    return unless pid

    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil # already gone
  end

  def test_os_fork
    skip "fork is unavailable on #{RUBY_ENGINE}" unless Process.respond_to?(:fork)

    os = Robin::Swarm::OS.new
    pid = os.fork { Kernel.exit!(5) }
    _, status = os.wait(block: true)

    assert_equal 5, status.exitstatus
    assert_kind_of Integer, pid
  end

  def test_os_clock_and_sleep
    os = Robin::Swarm::OS.new
    t = os.now
    os.sleep(0.01)

    assert_operator os.now - t, :>=, 0.01
  end

  def test_os_signals
    os = Robin::Swarm::OS.new
    previous = trap("USR2", "IGNORE")
    reader = os.trap_signals(["USR2"])

    assert_empty os.read_signals(reader, 0)
    2.times do # one at a time: rapid repeats of a signal may coalesce
      Process.kill("USR2", Process.pid)

      assert_equal ["USR2"], os.read_signals(reader, 5)
    end
    os.reset_signals(["USR2"])

    assert_equal "DEFAULT", trap("USR2", previous || "DEFAULT").to_s
  end

  def test_os_exit
    calls = []
    original = Kernel.method(:exit!)
    Kernel.define_singleton_method(:exit!) { |code| calls << code }
    Robin::Swarm::OS.new.finish_child

    assert_equal [0], calls
  ensure
    Kernel.define_singleton_method(:exit!, original)
  end
end
