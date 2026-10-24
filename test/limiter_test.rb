# frozen_string_literal: true

require_relative "test_helper"

class LimitedJob
  include Robin::Job

  LIMIT = Robin::Limiter.concurrent("limited-job", 1, wait_timeout: 0)
  robin_options limiter_backoff: 0.1

  def perform(id)
    LIMIT.within_limit { Recorder2.record(id) }
  end
end

module Recorder2
  @calls = Queue.new
  def self.record(x) = @calls << x

  def self.calls = @calls
end

# Real-time and concurrency checks; left out of mutant's selection (they sleep).
class LimiterTest < RobinTest
  def concurrently(threads, &block)
    Array.new(threads) { Thread.new(&block) }.each(&:join)
  end

  def test_concurrent_limits_simultaneous_holders
    limiter = Robin::Limiter.concurrent("conc", 3, wait_timeout: 5)
    current = 0
    peak = 0
    mutex = Mutex.new
    concurrently(10) do
      limiter.within_limit do
        mutex.synchronize {
          current += 1
          peak = [peak, current].max
        }
        sleep 0.05
        mutex.synchronize { current -= 1 }
      end
    end

    assert_equal 3, peak
    assert_equal 0, limiter.used
  end

  def test_concurrent_raises_when_full_and_expires_leases
    limiter = Robin::Limiter.concurrent("conc2", 1, wait_timeout: 0.1, lock_timeout: 0.3)
    holder = Thread.new { limiter.within_limit { sleep 0.5 } }
    sleep 0.05
    err = assert_raises(Robin::Limiter::OverLimit) { limiter.within_limit { flunk } }
    assert_same limiter, err.limiter
    holder.join
    # a crashed holder's lease lapses
    redis("ZADD", "#{key_prefix_for_test}lmtr:conc2:s", Robin.now_ms + 200, "ghost")
    assert_raises(Robin::Limiter::OverLimit) { limiter.within_limit {} }
    sleep 0.25

    assert limiter.within_limit { :ok }
  end

  def test_bucket
    limiter = Robin::Limiter.bucket("bkt", 5, :hour, wait_timeout: 0)
    count = 0
    errors = 0
    m = Mutex.new
    concurrently(10) do
      limiter.within_limit { m.synchronize { count += 1 } }
    rescue Robin::Limiter::OverLimit
      m.synchronize { errors += 1 }
    end

    assert_equal 5, count
    assert_equal 5, errors
    assert_equal 5, limiter.used
  end

  def test_bucket_waits_for_next_interval
    limiter = Robin::Limiter.bucket("bkt2", 2, 1, wait_timeout: 2)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    3.times { limiter.within_limit {} }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :<, 2
  end

  def test_window
    limiter = Robin::Limiter.window("win", 3, 0.5, wait_timeout: 0)
    3.times { limiter.within_limit {} }
    assert_raises(Robin::Limiter::OverLimit) { limiter.within_limit {} }
    assert_equal 3, limiter.used
    waiting = Robin::Limiter.window("win", 3, 0.5, wait_timeout: 1)
    waiting.within_limit {}
  end

  def test_leaky
    limiter = Robin::Limiter.leaky("leak", 2, 1, wait_timeout: 0)
    2.times { limiter.within_limit {} }
    assert_raises(Robin::Limiter::OverLimit) { limiter.within_limit {} }
    sleep 0.55 # drains one
    limiter.within_limit {}
  end

  def test_points
    limiter = Robin::Limiter.points("pts", 10, 1, wait_timeout: 0)
    limiter.within_limit(points: 7) {}
    assert_raises(Robin::Limiter::OverLimit) { limiter.within_limit(points: 5) {} }
    limiter.refund(4)
    limiter.within_limit(points: 5) {}
    assert_raises(ArgumentError) { limiter.within_limit(points: 11) {} }
    assert_operator limiter.used, :>=, 7
  end

  def test_list_reset_delete
    a = Robin::Limiter.bucket("listed", 1, :minute, wait_timeout: 0)
    a.within_limit {}
    assert_raises(Robin::Limiter::OverLimit) { a.within_limit {} }
    Robin::Limiter.concurrent("other", 2).within_limit {}
    list = Robin::Limiter.list
    row = list.find { |l| l["name"] == "listed" }

    assert_equal({"name" => "listed", "type" => "bucket", "limit" => 1, "interval" => 60.0, "used" => 1, "over_limit_count" => 1},
      row.except("last_used_at"))
    assert row["last_used_at"]
    assert_equal %w[listed other], list.map { |l| l["name"] }
    Robin::Limiter.reset!("listed")
    row = Robin::Limiter.list.find { |l| l["name"] == "listed" }

    assert_equal 0, row["used"]
    assert_equal 0, row["over_limit_count"]
    Robin::Limiter.delete!("listed")

    assert_equal %w[other], Robin::Limiter.list.map { |l| l["name"] }
  end

  def test_middleware_reschedules_without_failing
    Robin::Limiter.concurrent("limited-job", 1).tap do |l|
      redis("ZADD", "#{key_prefix_for_test}lmtr:limited-job:s", Robin.now_ms + 60_000, "blocker")
    end
    config.poll_interval = 0.1
    config.heartbeat_interval = 0.2
    Robin.server!
    launcher = Robin::Launcher.new(config).run
    LimitedJob.perform_async(1)
    entry = eventually { Robin::ScheduledSet.new.first }

    assert_equal 1, entry["limited"]
    assert_equal 0, Robin::RetrySet.new.size
    redis("DEL", "#{key_prefix_for_test}lmtr:limited-job:s")

    assert_equal 1, Timeout.timeout(5) { Recorder2.calls.pop }
    assert_equal 0, redis("GET", "#{key_prefix_for_test}stat:failed").to_i
  ensure
    launcher&.stop
  end

  def test_middleware_gives_up_after_max
    config.max_rate_limit_retries = 1
    mw = Robin::Limiter::ServerMiddleware.new
    mw.config = config
    limiter = Robin::Limiter.concurrent("x", 1)
    payload = {"class" => "LimitedJob", "args" => [], "jid" => "j", "queue" => "default", "limited" => 1}
    assert_raises(Robin::Limiter::OverLimit) { mw.call(nil, payload, "default") { raise Robin::Limiter::OverLimit.new(limiter) } }
  end
end
