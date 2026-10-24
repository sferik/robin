# frozen_string_literal: true

require "tmpdir"

# End-to-end: real `robin swarm` processes, one test file per mode so they
# run side by side under `rake test`. Left out of mutant's selection;
# test/swarm_unit_test.rb covers the supervisor logic.
module SwarmTestHelpers
  APP = <<~RUBY
    require "robin"
    Robin.configure do |c|
      c.redis = {url: ENV.fetch("SWARM_REDIS_URL")}
      c.key_prefix = ENV.fetch("SWARM_PREFIX")
      c.logger = Logger.new(ENV.fetch("SWARM_LOG"))
      c.heartbeat_interval = 0.3
      c.timeout = 2
      c.fetch_timeout = 0.2
    end
    class PidJob
      include Robin::Job
      def perform(key) = Robin.redis { |c| c.call("SADD", key, "\#{Process.pid}:\#{ENV["ROBIN_SWARM_INDEX"]}") }
    end
  RUBY

  def teardown
    if @pid
      Process.kill("KILL", @pid) rescue nil # rubocop:disable Style/RescueModifier
      Process.wait(@pid) rescue nil # rubocop:disable Style/RescueModifier
    end
    super
  end

  def pids = Robin::ProcessSet.new.map { |p| p["pid"] }.sort

  def run_swarm(mode)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "app.rb"), APP)
      log = File.join(dir, "log")
      env = {"SWARM_REDIS_URL" => REDIS_URL, "SWARM_LOG" => log, "SWARM_PREFIX" => key_prefix_for_test,
             "ROBIN_SWARM_MODE" => mode, "RUBYLIB" => File.expand_path("../lib", __dir__)}
      @pid = spawn(env, RbConfig.ruby, Robin::Swarm::EXE, "swarm", "-n", "2", "-c", "2", "-q", "default",
        "-r", File.join(dir, "app.rb"), chdir: dir, out: File::NULL, err: File::NULL)
      before = eventually(timeout: 60) { (p = pids).size == 2 && p }

      refute_includes before, @pid
      4.times { Robin::Client.push("class" => "PidJob", "args" => ["#{key_prefix_for_test}seen"]) }
      eventually(timeout: 20) { redis("SCARD", "#{key_prefix_for_test}seen") >= 1 && Robin::Queue.new.size.zero? }

      assert redis("SMEMBERS", "#{key_prefix_for_test}seen").all? { |m| m =~ /\A\d+:[01]\z/ }
      Process.kill("USR2", @pid)
      after = eventually(timeout: 120) { (p = pids).size == 2 && (p & before).empty? && p }

      assert_equal 2, after.size
      Process.kill("KILL", after.first) # a crashed child is replaced
      eventually(timeout: 60) { (pids - after).any? }
      Process.kill("TERM", @pid)
      _, status = Process.wait2(@pid)
      @pid = nil

      assert_predicate status, :success?
      text = File.read(log)

      assert_includes text, "rolling restart"
      assert_includes text, "(#{mode})"
    end
  end
end
