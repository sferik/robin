# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# End-to-end: a real Puma cluster (no preloading, a pruned bundle) with
# `plugin :robin`, restarted while it runs jobs. Left out of mutant's
# selection; test/puma_plugin_test.rb covers the plugin's logic.
class PumaIntegrationTest < RobinTest
  APP = <<~RUBY
    require "robin"
    Robin.configure do |c|
      c.redis = {url: ENV.fetch("PUMA_TEST_REDIS_URL")}
      c.key_prefix = ENV.fetch("PUMA_TEST_PREFIX")
      c.heartbeat_interval = 0.5
      c.fetch_timeout = 0.2
    end
    class PumaTestJob
      include Robin::Job
      def perform(n)
        sleep 0.1
        Robin.redis { |c| c.call("RPUSH", ENV.fetch("PUMA_TEST_PREFIX") + "done", n) }
      end
    end
    run ->(_env) { [200, {}, ["ok"]] }
  RUBY

  # The master writes down what it has loaded once its workers have booted.
  CONFIG = <<~RUBY
    workers 2
    prune_bundler
    extra_runtime_dependencies ["robin"]
    bind "unix://\#{__dir__}/puma.sock"
    pidfile "\#{__dir__}/puma.pid"
    directory __dir__
    plugin :robin
    robin_config { |c| c.concurrency = 2 }
    after_booted do
      loaded = $LOADED_FEATURES.grep(%r{/lib/robin[/.]}) + Gem.loaded_specs.keys.grep(/\\A(robin|json)\\z/)
      File.write("\#{__dir__}/master.txt", loaded.join("\\n"))
    end
  RUBY

  def teardown
    if @pid
      Process.kill("KILL", @pid) rescue nil # rubocop:disable Style/RescueModifier
      Process.wait(@pid) rescue nil # rubocop:disable Style/RescueModifier
    end
    super
  end

  def test_phased_and_hot_restarts
    skip "Puma's cluster mode needs fork" unless Process.respond_to?(:fork)
    skip "needs Bundler (run the tests with bundle exec)" unless defined?(Bundler)

    Dir.mktmpdir do |dir|
      @dir = dir
      boot_puma

      assert_equal "", File.read(File.join(dir, "master.txt")), "the master loaded Robin"
      restart_while_working("USR1", 0...40) # phased
      restart_while_working("USR2", 40...80) # hot

      assert_equal "", File.read(File.join(dir, "master.txt")), "the restarted master loaded Robin"
      Process.kill("TERM", @pid)
      eventually(timeout: 60) { Process.wait(@pid, Process::WNOHANG) }
      @pid = nil

      assert_empty identities
      assert_empty redis("SMEMBERS", config.key("inflights"))
    rescue Minitest::Assertion
      puts File.read(File.join(dir, "puma.log"))
      raise
    end
  end

  private

  def identities = redis("SMEMBERS", config.key("processes")).sort

  def boot_puma
    File.write(File.join(@dir, "config.ru"), APP)
    File.write(File.join(@dir, "puma.rb"), CONFIG)
    env = {"BUNDLE_GEMFILE" => Bundler.default_gemfile.to_s, "PUMA_TEST_REDIS_URL" => REDIS_URL,
           "PUMA_TEST_PREFIX" => key_prefix_for_test, "ROBIN_REDIS_URL" => REDIS_URL}
    @pid = Bundler.with_original_env do
      spawn(env, Gem.ruby, "-rbundler/setup", Gem.bin_path("puma", "puma"), "-C", "puma.rb",
        chdir: @dir, out: File.join(@dir, "puma.log"), err: %i[child out])
    end
    eventually(timeout: 60) { identities.size == 2 && File.exist?(File.join(@dir, "master.txt")) }
  end

  # Restarts Puma with +signal+ while the jobs numbered +range+ run, and
  # checks that each ran exactly once and that only the new workers'
  # servers are left registered.
  def restart_while_working(signal, range)
    before = identities
    range.each { |n| Robin::Client.push("class" => "PumaTestJob", "args" => [n]) }
    eventually(timeout: 30) { redis("LLEN", "#{key_prefix_for_test}done") > range.first }
    Process.kill(signal, @pid)
    eventually(timeout: 60) do
      (now = identities).size == 2 && (now & before).empty? && redis("LLEN", "#{key_prefix_for_test}done") >= range.last
    end
    done = redis("LRANGE", "#{key_prefix_for_test}done", 0, -1).map(&:to_i)

    assert_equal range.to_a, done.select { |n| range.cover?(n) }.sort
    before.each { |identity| assert_equal 0, redis("EXISTS", config.process_key(identity)) }
    assert_equal identities.map { |i| config.key("inflight", i) }.sort, redis("SMEMBERS", config.key("inflights")).sort
  end
end
