# frozen_string_literal: true

if ENV["COVERAGE"] != "false" && RUBY_ENGINE == "ruby" && !defined?(Mutant)
  require "simplecov"
  require_relative "simplecov_profile"
  SimpleCov.start("robin") do
    if (part = ENV["ROBIN_TEST_PART"])
      # One of `rake test`'s processes: it merges and checks the results.
      command_name part
      coverage_dir "#{RobinCoverage::PARTS}/#{part}"
      formatter RobinCoverage::Silent
    elsif RobinCoverage.strict?
      minimum_coverage RobinCoverage::THRESHOLDS
    end
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "robin"
require "minitest/autorun"
# Assertions that take only true and false for true and false (see
# minitest-strict).
require "minitest/strict"

begin
  # `cover "Robin::Thing*"` tells mutant which tests exercise which code.
  require "mutant/minitest/coverage"
rescue LoadError
  # mutant is MRI-only; on other engines coverage declarations are no-ops.
  module Minitest
    class Test
      def self.cover(_expression) = nil
    end
  end
end

require_relative "support/roundtrips"
Minitest::Test.include(RoundTrips::Assertions)

# assert_allocations (minitest-memory) pins how many objects a path may
# allocate. Only CRuby traces allocations: elsewhere the block runs, and
# the test is skipped.
require "minitest/memory"
Minitest::Test.include(Minitest::Memory)

REDIS_URL = ENV.fetch("ROBIN_TEST_REDIS_URL", "redis://127.0.0.1:6379/15")

module RobinTestHelpers
  # Every process gets its own key prefix, so parallel test runs (and
  # mutant's forked workers) never see or clear each other's data.
  def key_prefix_for_test = "robintest:#{Process.pid}:"

  def setup
    super
    Robin.config = Robin::Config.new
    Robin.config.redis = {url: REDIS_URL}
    Robin.config.key_prefix = key_prefix_for_test
    Robin.config.logger = Logger.new(nil)
    # Idle workers notice a stop within this, so servers stop quickly.
    Robin.config.fetch_timeout = 0.2
    # Buffered pushes left behind by a test mustn't be pushed (or reported)
    # when the test process exits.
    Robin::ReliablePush.exit_hook = ->(_) {}
    # Robin::Testing, once loaded in this process (as mutant's environment
    # and test:serial load it), leaves an interceptor in place, which
    # takes pushes off the direct path; these tests push to Redis.
    @interceptor = Robin::Client.interceptor
    Robin::Client.interceptor = nil
    flush_redis
  end

  def teardown
    Robin::Client.interceptor = @interceptor
    flush_redis
    Robin.config.redis_pool.shutdown
    super
  end

  def flush_redis(pool = Robin.config.redis_pool)
    pool.with do |c|
      cursor = "0"
      loop do
        cursor, keys = c.call("SCAN", cursor, "MATCH", "#{key_prefix_for_test}*", "COUNT", 1000)
        c.call("DEL", *keys) unless keys.empty?
        break if cursor == "0"
      end
    end
  end

  # Yields a pool for a second Redis "shard" (another database on the
  # test server), cleared of this process's keys before and after.
  def with_shard
    pool = Robin::Redis::Pool.new(size: 2) { Robin::Redis::Connection.new(url: REDIS_URL, db: 14) }
    flush_redis(pool)
    yield pool
  ensure
    flush_redis(pool)
    pool.shutdown
  end

  def config = Robin.config

  # Temporarily changes a constant.
  def with_constant(owner, name, value)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, original)
  end

  def redis(*) = Robin.redis { |c| c.call(*) }

  # Waits until the block returns truthy or fails after +timeout+.
  def eventually(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end
end

class RobinTest < Minitest::Test
  include RobinTestHelpers
end

# Two kinds of exceptions escaping a test would abort or crash the run
# instead of being reported as a failure (and mutant would then count the
# mutation as alive): Robin::Shutdown, which is an Interrupt that Minitest
# re-raises as a user abort, and test doubles whose #message raises, which
# crash Minitest's reporter. Both become ordinary failures.
module ReportEscapedExceptions
  class EscapedShutdown < StandardError; end

  class UnreadableError < StandardError; end

  def capture_exceptions
    super do
      yield
    rescue Robin::Shutdown => e
      raise EscapedShutdown, "Robin::Shutdown escaped the test: #{e.message}", e.backtrace
    rescue Exception => e # rubocop:disable Lint/RescueException
      begin
        e.message
      rescue Exception # rubocop:disable Lint/RescueException
        raise UnreadableError, "#{e.class} (with an unreadable message) escaped the test", e.backtrace
      end
      raise
    end
  end
end
Minitest::Test.prepend(ReportEscapedExceptions)
