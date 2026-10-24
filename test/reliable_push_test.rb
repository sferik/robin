# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/statsd_recorder"
require_relative "support/lock_assertions"

class ReliablePushTest < RobinTest
  include LockAssertions

  cover "Robin::ReliablePush*"

  DOWN = {url: "redis://127.0.0.1:1/0", connect_timeout: 0.2}.freeze

  class Job
    include Robin::Job

    def perform(_) = nil
  end

  # ReliablePush gets its own config (and key prefix): anything that falls
  # back to the global Robin.config pushes where these tests don't look.
  def setup
    super
    @log = StringIO.new
    @cfg = Robin::Config.new
    @cfg.key_prefix = "#{key_prefix_for_test}rp#{SecureRandom.hex(4)}:"
    @instances = []
    @cfg.logger = Logger.new(@log, formatter: ->(sev, _, _, msg) { "#{sev}: #{msg}\n" })
    up!
  end

  def teardown
    @instances.each do |rp|
      thread = retrier(rp)
      thread&.kill
      begin
        thread&.join
      rescue
        nil # a deliberately crashed retrier
      end
    end
    @cfg.redis_pool.shutdown
    super
  end

  def track(rp)
    @instances << rp
    rp
  end

  def config = @cfg

  def down! = @cfg.redis = DOWN

  def up! = @cfg.redis = {url: REDIS_URL}

  def payloads(range)
    client = Robin::Client.new(config: @cfg)
    range.map { |i| client.normalize({"class" => "ReliablePushTest::Job", "args" => [i], "jid" => "j#{i}"}) }
  end

  def queued_args = Robin::Queue.new("default", config: @cfg).map { |j| j.args.first }

  def log_lines = @log.string.lines.map(&:chomp)

  # A ReliablePush whose retrier waits for good, so only the test's own
  # drain pushes (and logs).
  def waiting(**)
    rp = track(Robin::ReliablePush.new(config, **))
    rp.define_singleton_method(:pause) { |_| sleep }
    rp
  end

  # A ReliablePush whose retrier doesn't sleep; it records each delay and
  # brings Redis back after +recover_after+ waits.
  def instant(recover_after: 1, **)
    rp = track(Robin::ReliablePush.new(config, **))
    delays = []
    test = self
    rp.define_singleton_method(:pause) do |seconds|
      delays << seconds
      test.send(:up!) if delays.size == recover_after
    end
    [rp, delays]
  end

  def retrier(rp) = rp.instance_variable_get(:@retrier)

  def test_for_returns_one_instance_per_config
    other = Robin::Config.new

    assert_same Robin::ReliablePush.for(config), Robin::ReliablePush.for(config)
    refute_same Robin::ReliablePush.for(config), Robin::ReliablePush.for(other)
    pool = Robin::Redis::Pool.new { nil }

    assert_same Robin::ReliablePush.for(config, pool), Robin::ReliablePush.for(config, pool)
    refute_same Robin::ReliablePush.for(config), Robin::ReliablePush.for(config, pool)
    assert_same pool, Robin::ReliablePush.for(config, pool).instance_variable_get(:@pool)
    assert_nil Robin::ReliablePush.for(config).instance_variable_get(:@pool)
  end

  def test_drains_to_its_own_pool
    with_shard { |shard| check_drain_to(shard) }
  end

  def check_drain_to(shard)
    rp = track(Robin::ReliablePush.new(config, pool: shard))
    rp.push(payloads(1..2)) { raise Robin::Redis::ConnectionError, "down" }
    entries = shard.call("LRANGE", config.key("queue", "default"), 0, -1)

    assert_equal [2, 1], entries.map { |raw| JSON.parse(raw)["args"].first }
    assert_empty queued_args
  end

  def test_limits
    config.reliable_push = true

    assert_equal 1_000, Robin::ReliablePush.new(config).limit
    config.reliable_push = 7

    assert_equal 7, Robin::ReliablePush.new(config).limit
    assert_equal 3, Robin::ReliablePush.new(config, limit: 3).limit
  end

  def test_passes_through_when_healthy
    rp = Robin::ReliablePush.new(config)

    assert_equal :pushed, rp.push(payloads(1..1)) { :pushed }
    assert_equal 0, rp.size
    assert_empty log_lines
  end

  def test_integration_with_client
    Robin.config.reliable_push = true
    jid = Job.perform_async(1)

    assert_equal jid, Robin::Queue.new("default").first.jid
    assert_equal 0, Robin::ReliablePush.for(Robin.config).size
  end

  def test_buffers_and_drains_when_redis_recovers
    rp, delays = instant
    down!
    result = rp.push(payloads(1..2)) { raise Robin::Redis::ConnectionError, "refused" }

    assert_nil result
    eventually(timeout: 5) { retrier(rp).nil? }

    assert_equal [0.5], delays
    assert_equal 0, rp.size
    assert_nil retrier(rp)
    assert_equal [1, 2], queued_args
    assert_equal ["WARN: Redis unavailable (refused); buffering 2 job(s) for later",
      "INFO: Redis is reachable again; pushed 2 buffered job(s)"], log_lines
  end

  def test_drained_jobs_are_counted_in_statsd
    config.statsd = StatsdRecorder.new
    rp = Robin::ReliablePush.new(config)
    rp.push(payloads(1..3)) { raise Robin::Redis::ConnectionError, "refused" }
    rp.drain

    assert_equal [[:increment, "jobs.recovered.push", 3, {}]], config.statsd.calls
    rp.drain

    assert_equal 1, config.statsd.calls.size, "nothing more to count"
  ensure
    config.statsd = nil
  end

  def test_pool_timeouts_are_buffered_too
    rp = Robin::ReliablePush.new(config)
    rp.push(payloads(1..1)) { raise Robin::Redis::Pool::TimeoutError, "busy" }

    assert_equal 0, rp.size
    assert_equal [1], queued_args
  end

  def test_other_errors_propagate
    rp = Robin::ReliablePush.new(config)

    assert_raises(Robin::Redis::CommandError) { rp.push(payloads(1..1)) { raise Robin::Redis::CommandError, "ERR" } }
    assert_equal 0, rp.size
  end

  def test_later_pushes_queue_behind_the_buffer_in_order
    rp, = instant(recover_after: 100)
    down!
    rp.push(payloads(1..1)) { raise Robin::Redis::ConnectionError, "down" }
    called = false
    rp.push(payloads(2..3)) { called = true }

    refute called
    assert_equal 3, rp.size
    up!

    assert_true rp.drain
    assert_equal [1, 2, 3], queued_args
    eventually(timeout: 5) { retrier(rp).nil? }
  end

  def test_drain_pushes_everything_in_order
    rp = waiting
    down!
    rp.push(payloads(1..250)) { raise Robin::Redis::ConnectionError, "down" }

    assert_equal 250, rp.size
    up!

    assert assert_roundtrips(3) { rp.drain } # 100 at a time
    assert_equal (1..250).to_a, queued_args
    assert_equal "INFO: Redis is reachable again; pushed 250 buffered job(s)", log_lines.last
  end

  def test_drain_with_empty_buffer
    rp = Robin::ReliablePush.new(config)

    assert_true rp.drain
    assert_empty log_lines
  end

  def test_drain_failure_returns_false
    rp, = instant(recover_after: 100)
    down!
    rp.push(payloads(1..1)) { raise Robin::Redis::ConnectionError, "down" }

    assert_false rp.drain
    assert_equal 1, rp.size
  end

  def test_buffer_is_bounded_and_drops_oldest
    rp, = instant(recover_after: 100, limit: 3)
    down!
    rp.push(payloads(1..2)) { raise Robin::Redis::ConnectionError, "down" }
    rp.push(payloads(3..5)) { nil }

    assert_equal 3, rp.size
    assert_includes log_lines, "WARN: Robin::ReliablePush::Dropped: reliable push buffer full (3); dropped 2 job(s): " \
      "ReliablePushTest::Job jid=j1, ReliablePushTest::Job jid=j2"
    up!
    rp.drain

    assert_equal [3, 4, 5], queued_args
  end

  def test_buffer_one_over_drops_one
    rp, = instant(recover_after: 100, limit: 2)
    down!
    rp.push(payloads(1..3)) { raise Robin::Redis::ConnectionError, "down" }

    assert_equal 2, rp.size
    assert_includes log_lines, "WARN: Robin::ReliablePush::Dropped: reliable push buffer full (2); dropped 1 job(s): ReliablePushTest::Job jid=j1"
  end

  def events
    @events ||= [].tap { |list| @cfg.event_handlers << ->(name, payload) { list << [name, payload] } }
  end

  def errors
    @errors ||= [].tap { |list| @cfg.error_handlers << ->(ex, ctx, _) { list << [ex, ctx] } }
  end

  def test_buffering_draining_and_dropping_are_events
    events
    rp, = instant(recover_after: 100, limit: 2)
    down!
    error = Robin::Redis::ConnectionError.new("down")
    batch = payloads(1..3)
    rp.push(batch) { raise error }
    retrying = retrier(rp)
    up!
    rp.drain
    # The retrier may drain first (in parallel, on JRuby), and reports
    # what it pushed once it lets go of the buffer: it's done when it ends.
    assert retrying.join(5), "the retrier should end once the buffer is empty"

    # The error by its class and message: JRuby can hand on another
    # instance of it, which prints the same but isn't ==.
    (buffered, given), *rest = events

    assert_equal ["push.buffered", batch, [Robin::Redis::ConnectionError, "down"]],
      [buffered, given[:jobs], [given[:error].class, given[:error].message]]
    assert_equal %i[jobs error], given.keys
    assert_equal [["push.dropped", {jobs: batch.first(1)}], ["push.recovered", {count: 2}]], rest
  end

  def test_dropped_jobs_are_reported_as_errors
    errors
    rp, = instant(recover_after: 100, limit: 1)
    down!
    rp.push(payloads(1..2)) { raise Robin::Redis::ConnectionError, "down" }
    (ex, ctx), = errors

    assert_instance_of Robin::ReliablePush::Dropped, ex
    assert_kind_of Robin::Error, ex
    assert_equal "reliable push buffer full (1); dropped 1 job(s): ReliablePushTest::Job jid=j1", ex.message
    assert_equal({context: "reliable push"}, ctx)
    assert_equal 1, errors.size
  end

  # An error handler that pushes a job of its own while the buffer is
  # full mustn't deadlock on the buffer's lock.
  def test_drops_are_reported_outside_the_lock
    rp, = instant(recover_after: 100, limit: 1)
    down!
    reported = 0
    @cfg.error_handlers << lambda do |_ex, _ctx, _cfg|
      reported += 1
      rp.push(payloads(9..9)) { raise Robin::Redis::ConnectionError, "down" } if reported == 1
    end
    rp.push(payloads(1..2)) { raise Robin::Redis::ConnectionError, "down" }

    assert_equal 2, reported
    assert_equal 1, rp.size
  end

  def test_drain_reports_what_it_pushed_before_failing
    events
    rp = waiting
    down!
    rp.push(payloads(1..150)) { raise Robin::Redis::ConnectionError, "down" }
    up!
    calls = 0
    rp.define_singleton_method(:push_chunk) do |chunk|
      calls += 1
      raise Robin::Redis::ConnectionError, "down" if calls == 2

      super(chunk)
    end

    assert_false rp.drain

    assert_equal 50, rp.size
    assert_equal ["push.recovered", {count: 100}], events.last
    assert_equal "INFO: Redis is reachable again; pushed 100 buffered job(s)", log_lines.last
  end

  def test_finish_pushes_what_is_buffered
    errors
    rp, = instant(recover_after: 100)
    down!
    rp.push(payloads(1..2)) { raise Robin::Redis::ConnectionError, "down" }
    up!

    assert_nil rp.finish
    assert_equal [1, 2], queued_args
    assert_empty errors
  end

  def test_finish_reports_jobs_it_could_not_push
    errors
    events
    rp, = instant(recover_after: 100)
    down!
    batch = payloads(1..2)
    rp.push(batch) { raise Robin::Redis::ConnectionError, "down" }
    rp.finish
    (ex, ctx), = errors

    assert_instance_of Robin::ReliablePush::Lost, ex
    assert_kind_of Robin::Error, ex
    assert_equal "process exiting with 2 buffered job(s) not pushed: ReliablePushTest::Job jid=j1, ReliablePushTest::Job jid=j2",
      ex.message
    assert_equal({context: "reliable push"}, ctx)
    assert_equal ["push.lost", {jobs: batch}], events.last
    assert_equal 0, rp.size
  end

  def test_the_exit_hook_is_installed_once_when_buffering_starts
    hooked = []
    Robin::ReliablePush.exit_hook = ->(rp) { hooked << rp && nil }
    rp, = instant(recover_after: 100)
    rp.push(payloads(1..1)) { nil }

    assert_empty hooked
    down!
    rp.push(payloads(2..2)) { raise Robin::Redis::ConnectionError, "down" }
    rp.push(payloads(3..3)) { nil }

    assert_equal [rp], hooked
  end

  def test_the_default_exit_hook_finishes_at_exit
    rp = Robin::ReliablePush.new(@cfg)
    finished = []
    rp.define_singleton_method(:finish) { finished << :finished }
    block = nil
    original = Kernel.method(:at_exit)
    begin
      Kernel.define_singleton_method(:at_exit) { |&b| block = b }
      Robin::ReliablePush::AT_EXIT.call(rp)
    ensure
      Kernel.define_singleton_method(:at_exit, original)
    end

    assert_empty finished
    block.call

    assert_equal [:finished], finished
  end

  def test_drain_logs_a_single_job
    rp = waiting
    down!
    rp.push(payloads(1..1)) { raise Robin::Redis::ConnectionError, "down" }
    up!
    rp.drain

    assert_equal "INFO: Redis is reachable again; pushed 1 buffered job(s)", log_lines.last
  end

  def test_a_crashed_retrier_is_replaced
    rp = track(Robin::ReliablePush.new(@cfg))
    rp.define_singleton_method(:pause) do |_|
      Thread.current.report_on_exception = false
      raise "retrier crashed"
    end
    down!
    rp.push(payloads(1..1)) { raise Robin::Redis::ConnectionError, "down" }
    crashed = retrier(rp)
    assert_raises(RuntimeError) { crashed.join(5) }

    assert_same crashed, retrier(rp)
    rp.define_singleton_method(:pause) { |_| sleep }
    rp.push(payloads(2..2)) { nil }

    refute_same crashed, retrier(rp)
  end

  def test_locks
    rp = track(Robin::ReliablePush.new(@cfg))
    rp.define_singleton_method(:pause) { |_| sleep }
    lock = rp.instance_variable_get(:@mutex)

    assert_equal 0, assert_waits_for(lock) { rp.size }
    down!
    assert_waits_for(lock) { rp.push(payloads(1..1)) { raise Robin::Redis::ConnectionError, "down" } }

    assert_equal 1, rp.size
    assert_waits_for(lock) { rp.drain }
    rp.define_singleton_method(:drain) { false }
    assert_waits_for(lock) { rp.finish }

    assert_equal 0, rp.size
    assert_waits_for(Robin::ReliablePush.instance_variable_get(:@lock)) { Robin::ReliablePush.for(Robin::Config.new) }
  end

  def test_buffering_waits_for_the_lock
    rp = track(Robin::ReliablePush.new(@cfg))
    rp.define_singleton_method(:pause) { |_| sleep }
    down!
    lock = rp.instance_variable_get(:@mutex)
    buffer = rp.instance_variable_get(:@buffer)
    held = Queue.new
    release = Queue.new
    holder = Thread.new { lock.synchronize { held << true; release.pop } } # rubocop:disable Style/Semicolon
    held.pop
    worker = Thread.new { rp.push(payloads(1..1)) { raise Robin::Redis::ConnectionError, "down" } }
    worker.join(0.2)

    assert_empty buffer # not appended while another thread holds the lock
    release << true
    holder.join
    worker.join(5)

    assert_equal 1, buffer.size
  end

  def test_buffer_exactly_full_drops_nothing
    rp, = instant(recover_after: 100, limit: 2)
    down!
    rp.push(payloads(1..2)) { raise Robin::Redis::ConnectionError, "down" }

    assert_equal 2, rp.size
    refute(log_lines.any? { |l| l.include?("buffer full") })
  end

  def test_retrier_backs_off_exponentially_up_to_thirty_seconds
    rp, delays = instant(recover_after: 9)
    down!
    rp.push(payloads(1..1)) { raise Robin::Redis::ConnectionError, "down" }
    eventually(timeout: 10) { retrier(rp).nil? }

    assert_equal [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 30, 30, 30], delays
    assert_equal [1], queued_args
  end

  def test_only_one_retrier_runs
    rp = track(Robin::ReliablePush.new(@cfg))
    gate = Queue.new
    rp.define_singleton_method(:pause) { |_| gate.pop }
    down!
    rp.push(payloads(1..1)) { raise Robin::Redis::ConnectionError, "down" }
    first = retrier(rp)
    eventually { first.status == "sleep" } # parked in pause

    assert_equal "robin.reliable_push", first.name
    rp.push(payloads(2..2)) { nil }

    assert_same first, retrier(rp)
    up!
    gate << :go
    first.join(5)

    assert_equal [1, 2], queued_args
  end

  def test_pause_sleeps
    rp = Robin::ReliablePush.new(config)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rp.send(:pause, 0.05)

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.05
  end
end
