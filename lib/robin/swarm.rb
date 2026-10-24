# frozen_string_literal: true

require "etc"
require "rbconfig"
require "socket"

module Robin
  # Runs several Robin processes on one machine from a single command.
  #
  #   robin swarm -n 4 -r ./config/environment.rb -c 10
  #
  # Where fork is available, the parent boots the application once and
  # forks children, so they share memory copy-on-write. Elsewhere (JRuby)
  # each child is a fresh `robin` process started with the same options.
  # Dead children are replaced, with a growing delay if they keep crashing.
  # Signals sent to the parent:
  #
  # TERM, INT:: graceful shutdown of every child, then exit
  # TSTP::      quiet every child (finish running jobs, fetch no more)
  # TTIN::      every child logs its thread backtraces
  # USR2::      rolling restart: each child in turn is replaced by a fresh
  #             one, which must be up (heartbeating) *before* the old one
  #             stops, so capacity never drops
  #
  # The number of children comes from -n, else ROBIN_SWARM_COUNT, else the
  # number of CPU cores. A decimal means that many per core: 0.5 on 8 cores
  # is 4 children, 1.5 is 12 (always at least 1).
  #
  # Children see ROBIN_SWARM_INDEX (0...n) and stop by themselves if the
  # parent dies. A child exceeding config.memory_limit_mb stops gracefully
  # and is replaced.
  class Swarm
    READY_TIMEOUT = 60
    MIN_UPTIME = 10
    MAX_DELAY = 60
    SIGNALS = %w[INT TERM TSTP TTIN USR2 CHLD].freeze
    EXE = File.expand_path("../../exe/robin", __dir__)
    LIB = File.expand_path("..", __dir__)

    Child = Struct.new(:pid, :index, :started_at, :retiring)

    # Operating-system primitives, separated so the supervisor logic can
    # be tested without real processes.
    class OS
      SIGNAL_BUFFER = 1024

      # mutant:disable -- only differs where fork is missing (JRuby);
      # mutant runs on MRI.
      def fork? = Process.respond_to?(:fork)

      # mutant:disable -- `super` reaches Kernel#fork, the same call.
      def fork(&) = Process.fork(&)

      # mutant:disable -- `super` reaches Kernel#spawn, the same call.
      def spawn(env, *command) = Process.spawn(env, *command)

      # Tidies the heap (GC, compaction) so forked children share more
      # memory copy-on-write.
      def warmup = Process.warmup

      def kill(pid, signal)
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
      end

      # [pid, status] of an exited child, or nil.
      def wait(block: false)
        wait2(block)
      rescue Errno::ECHILD
        nil
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # mutant:disable -- `super` reaches Kernel#sleep, the same call.
      def sleep(seconds) = Kernel.sleep(seconds)

      # Routes +signals+ into a pipe; returns its reading end.
      def trap_signals(signals)
        reader, writer = IO.pipe
        signals.each { |sig| trap(sig) { notify(writer, sig) } }
        reader
      end

      def reset_signals(signals) = signals.each { |sig| trap(sig, "DEFAULT") }

      # Signals received within +timeout+ seconds.
      def read_signals(reader, timeout)
        return [] unless reader.wait_readable(timeout)

        reader.read_nonblock(SIGNAL_BUFFER).lines(chomp: true)
      end

      # mutant:disable -- `self.exit!` reaches Kernel#exit!, the same call.
      def finish_child = Kernel.exit!(0)

      private

      # mutant:disable -- equivalent spellings: wait2's pid -1 or omitted,
      # flags 0 or nil.
      def wait2(block) = Process.wait2(-1, block ? 0 : Process::WNOHANG)

      # mutant:disable -- raising instead only differs once 64KB of
      # unread signal names fill the pipe.
      def notify(writer, signal) = writer.write_nonblock("#{signal}\n", exception: false)
    end

    # Stops this process when +parent+ goes away. Children call this; with
    # spawn they get here by loading this file (see #child_command).
    def self.watch_parent(parent, os: OS.new, interval: 1)
      Thread.new do
        Thread.current.name = "robin.swarm.watch"
        os.sleep(interval) while Process.ppid == parent
        os.kill(Process.pid, "TERM")
      end
    end

    # Watches the swarm parent named in ROBIN_SWARM_PARENT, if it is ours.
    # Children for a count setting (see the class comment).
    def self.process_count(value, cores = Etc.nprocessors)
      return cores if value.nil?

      text = value.to_s
      number = text.include?(".") ? Float(text) : Integer(text)
      raise ArgumentError, "the swarm's process count must be positive: #{text}" unless number.positive?

      number.integer? ? number : [(number * cores).round, 1].max #: Integer
    end

    def self.watch_parent_from_env(env = ENV, os: OS.new)
      parent = env["ROBIN_SWARM_PARENT"]
      watch_parent(Process.ppid, os: os) if parent && Integer(parent) == Process.ppid
    end

    attr_reader :children, :count, :mode

    def initialize(cli, os: OS.new)
      @cli = cli
      @config = cli.config
      @os = os
      @count = Swarm.process_count(cli.options[:processes] || ENV["ROBIN_SWARM_COUNT"])
      @mode = ENV["ROBIN_SWARM_MODE"] || (os.fork? ? "fork" : "spawn")
      @children = {}
      @crashes = Hash.new(0)
      @restarts = {} # index => when (monotonic) to start a replacement
    end

    def run
      @cli.boot
      if @mode == "fork"
        # Loaded before forking, the code is shared copy-on-write instead
        # of autoloaded by each child.
        Robin.eager_load!
        @os.warmup
      end
      @signals = @os.trap_signals(SIGNALS)
      logger.info("swarm #{Process.pid} starting #{@count} children (#{@mode})")
      @count.times { |i| start_child(i) }
      until @stopping # shutdown returns once every child is gone
        reap
        start_due_restarts
        @os.read_signals(@signals, 1).each { |sig| handle(sig) }
      end
      logger.info("swarm #{Process.pid} stopped")
    end

    def handle(signal)
      case signal
      when "INT", "TERM" then shutdown
      when "TSTP", "TTIN" then signal_children(signal)
      when "USR2" then rolling_restart
      end
    end

    def shutdown
      return if @stopping

      @stopping = true
      @restarts.clear
      logger.info("swarm stopping #{@children.size} children")
      signal_children("TERM")
      return if wait_for { @children.empty? }

      logger.warn("killing #{@children.size} children that didn't stop in time")
      signal_children("KILL")
      reap(block: true) until @children.empty?
    end

    def rolling_restart
      return if @stopping

      logger.info("swarm rolling restart")
      @children.values.sort_by(&:index).each do |old|
        next unless @children.key?(old.pid)

        old.retiring = true
        replacement = start_child(old.index)
        if ready?(replacement)
          stop_child(old)
        else
          logger.error("replacement for child #{old.index} didn't start; keeping the old one")
          replacement.retiring = true
          @os.kill(replacement.pid, "KILL")
          old.retiring = false
        end
      end
    end

    # The options a spawned child needs to run like this process.
    def child_arguments
      o = @cli.options
      args = [] #: Array[String]
      {require: "-r", config_file: "-C", environment: "-e", concurrency: "-c", timeout: "-t", tag: "-g"}.each do |key, flag|
        args.push(flag, o.fetch(key).to_s) if o[key]
      end
      Array(o[:queues]).each { |q| args.push("-q", [q].join(",")) }
      args << "-v" if o[:verbose]
      args << "--json-logs" if o[:json_logs]
      args
    end

    def child_command = [RbConfig.ruby, "-r", "robin/swarm", EXE, *child_arguments]

    def child_env(index)
      {"ROBIN_SWARM_INDEX" => index.to_s, "ROBIN_SWARM_PARENT" => Process.pid.to_s,
       "RUBYLIB" => [LIB, ENV["RUBYLIB"]].compact.join(File::PATH_SEPARATOR)}
    end

    def start_child(index)
      pid = (@mode == "fork") ? @os.fork { child_main(index) } : @os.spawn(child_env(index), *child_command)
      child = Child.new(pid, index, @os.now, false)
      @children[pid] = child
      logger.info("swarm child #{index} started (pid #{pid})")
      child
    end

    # Runs inside a forked child.
    def child_main(index)
      @os.reset_signals(SIGNALS)
      ENV["ROBIN_SWARM_INDEX"] = index.to_s
      Swarm.watch_parent(Process.ppid, os: @os)
      @cli.config.fire_event(:fork)
      @cli.serve
      @os.finish_child
    end

    # Collects exited children and schedules replacements.
    def reap(block: false)
      loop do
        waited = @os.wait(block: block) or break
        pid, status = waited

        child = @children.delete(pid)
        next unless child

        block = false
        next if @stopping || child.retiring

        index = child.index
        @crashes[index] = (@os.now - child.started_at < MIN_UPTIME) ? @crashes[index] + 1 : 0
        crashes = @crashes.fetch(index)
        delay = crashes.zero? ? 0 : [2**crashes, MAX_DELAY].min
        logger.warn("swarm child #{index} (pid #{pid}) exited #{status.exitstatus || status.termsig}; " \
          "restarting in #{delay}s")
        Events.emit(@config, "swarm.child_exited", index: index, pid: pid, status: status.exitstatus || status.termsig, delay: delay)
        @restarts[index] = @os.now + delay
      end
    end

    def start_due_restarts
      now = @os.now
      @restarts.select { |_, at| at <= now }.each_key do |index|
        @restarts.delete(index)
        start_child(index)
      end
    end

    private

    def logger = @config.logger

    # Is the child heartbeating in Redis yet?
    def ready?(child)
      wait_for(READY_TIMEOUT, poll: 1) do
        return false unless @children.key?(child.pid) # it died

        ProcessSet.new(config: @config).any? { |p| p["pid"] == child.pid && p["hostname"] == Robin.hostname }
      end
    end

    def stop_child(child)
      @os.kill(child.pid, "TERM")
      return if wait_for { !@children.key?(child.pid) }

      @os.kill(child.pid, "KILL")
      reap(block: true) while @children.key?(child.pid)
    end

    # Polls, reaping exited children, until the block is true or +seconds+
    # pass. Returns whether the block became true.
    def wait_for(seconds = @config.timeout + 10, poll: 0.1)
      deadline = @os.now + seconds
      loop do
        reap
        return true if yield
        return false if @os.now > deadline

        @os.sleep(poll)
      end
    end

    def signal_children(signal) = @children.each_key { |pid| @os.kill(pid, signal) }
  end
end

# Spawned swarm children load this file with `ruby -r robin/swarm` so they
# stop when the swarm does.
Robin::Swarm.watch_parent_from_env
