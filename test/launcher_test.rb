# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"
require_relative "support/statsd_recorder"

class LauncherTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Launcher*"
  # Mutant only picks the most specific matching cover expressions, so the
  # fast tests must also claim the methods the lifecycle class claims.
  cover "Robin::Launcher#run"
  cover "Robin::Launcher#stop"

  FakeUnit = Struct.new(:queue, :raw, :key)

  class FakeProcessor
    attr_reader :thread, :unacked
    attr_accessor :work, :finished_at, :finished

    def initialize(name = nil)
      @thread = name && Thread.new { Thread.current.name = name }.tap(&:join)
      @finished = 0
    end

    # Finishes a job at +at+ (monotonic seconds).
    def finish(at)
      @finished += 1
      @finished_at = at
    end

    def terminate = nil

    def alive? = false
  end

  # A FakeProcessor among the launcher's workers.
  def fake_processor(name = nil)
    FakeProcessor.new(name).tap { |p| @launcher.managers.first.instance_variable_get(:@processors) << p }
  end

  def setup
    super
    config.concurrency = 1
    config.timeout = 1
    config.tag = "web"
    config.labels = %w[blue]
    @errors = capture_errors
    @launcher = started(Robin::Launcher.new(config))
    @launcher.define_singleton_method(:rss_kb) { 2048 }
  end

  STARTED_AT = 1_760_000_000_123

  # The launcher as #run leaves it: heartbeats only follow a run.
  def started(launcher)
    launcher.tap { |l| l.instance_variable_set(:@started_at, STARTED_AT) }
  end

  def teardown
    Robin::Leader.unregister(config)
    super
  end

  def proc_hash = redis("HGETALL", @launcher.proc_key).each_slice(2).to_h

  def beat = @launcher.beat

  def events_for(*names)
    log = []
    names.each { |n| config.on(n) { log << n } }
    log
  end

  # -- construction & simple accessors --------------------------------------

  def test_identity_and_wiring
    host, pid, suffix = @launcher.identity.split(":")

    assert_equal Socket.gethostname, host
    assert_equal Process.pid.to_s, pid
    assert_match(/\A\h{8}\z/, suffix)
    refute_equal @launcher.identity, Robin::Launcher.new(config).identity
    assert_same config, @launcher.config
    assert_equal @launcher.identity, @launcher.leader.identity
    assert_instance_of Robin::Metrics::Collector, @launcher.collector
    assert_equal config.key("inflight", @launcher.identity), @launcher.inflight_key
    assert_equal config.process_key(@launcher.identity), @launcher.proc_key
    assert_false @launcher.quiet?
    assert_false @launcher.stopping?
    assert_nil Robin::Launcher.new(config).started_at
    assert_nil @launcher.on_stop_request
  end

  def test_one_manager_per_capsule
    config.capsule("solo") { |c| c.queues = ["serial"] }
    launcher = Robin::Launcher.new(config)

    assert_equal [config.default_capsule, config.capsule("solo")], launcher.managers.map(&:capsule)
    assert(launcher.managers.all? { |m| m.launcher.equal?(launcher) })
  end

  def test_process_info
    config.capsule("solo") do |c|
      c.queues = ["serial,2", "default"]
      c.concurrency = 2
    end
    info = started(Robin::Launcher.new(config, embedded: true)).process_info

    assert_equal Robin.hostname, info["hostname"]
    assert_equal Process.pid, info["pid"]
    assert_equal "web", info["tag"]
    assert_equal %w[blue], info["labels"]
    assert_equal Robin::VERSION, info["version"]
    assert_equal RUBY_DESCRIPTION, info["ruby"]
    assert_equal config.environment, info["env"]
    assert_true info["embedded"]
    assert_equal 3, info["concurrency"]
    assert_equal %w[default serial], info["queues"]
    assert_equal [{"default" => 0}, {"serial" => 2, "default" => 0}], info["weights"]
    assert_equal({"default" => {"concurrency" => 1, "mode" => "strict", "weights" => {"default" => 0}},
                  "solo" => {"concurrency" => 2, "mode" => "weighted", "weights" => {"serial" => 2, "default" => 0}}},
      info["capsules"])
    assert_equal Robin.epoch_seconds(STARTED_AT), info["started_at"]
    assert_false @launcher.process_info["embedded"]
    assert_equal @launcher.identity, @launcher.process_info["identity"]
  end

  def test_process_info_before_run
    assert_nil Robin::Launcher.new(config).process_info["started_at"]
  end

  def test_identity_and_hostname_use_the_dyno_name
    ENV["DYNO"] = "worker.3"
    launcher = started(Robin::Launcher.new(config))

    assert launcher.identity.start_with?("worker.3:#{Process.pid}:")
    assert_equal "worker.3", launcher.process_info["hostname"]
  ensure
    ENV.delete("DYNO")
  end

  def test_title
    @launcher.managers.first.resize(4)

    assert_equal "robin #{Robin::VERSION} web [0 of 4 busy]", @launcher.title
    @launcher.work_started(fake_processor, FakeUnit.new("q", "{}"))
    @launcher.instance_variable_set(:@quiet, true)

    assert_equal "robin #{Robin::VERSION} web [1 of 4 busy] quiet", @launcher.title
    @launcher.instance_variable_set(:@done, true)

    assert_equal "robin #{Robin::VERSION} web [1 of 4 busy] stopping", @launcher.title
  end

  # Records process titles and systemd messages while the block runs.
  def watching_the_os(watchdog: false)
    seen = []
    stub_method(Process, :setproctitle, ->(t) { seen << [:title, t] }) do
      stub_method(Robin::Systemd, :watchdog?, -> { watchdog }) do
        stub_method(Robin::Systemd, :notify, ->(state) { seen << [:notify, state] }) { yield }
      end
    end
    seen
  end

  def test_beat_sets_the_title_and_pets_the_watchdog
    assert_equal [[:title, @launcher.title]], watching_the_os { beat }
    assert_equal [[:title, @launcher.title], [:notify, "WATCHDOG=1"]], watching_the_os(watchdog: true) { beat }
  end

  def test_embedded_servers_leave_the_title_and_systemd_alone
    launcher = started(Robin::Launcher.new(config, embedded: true))
    launcher.define_singleton_method(:rss_kb) { 1 }

    assert_empty watching_the_os(watchdog: true) { launcher.beat }
  end

  # Stands in for Robin::GVL: each sample is the next of +samples+.
  class FakeGVL
    attr_reader :log

    def initialize(*samples)
      @samples = samples
      @log = []
    end

    def start = @log << :start

    def stop = @log << :stop

    def sample = @samples.shift
  end

  def fake_gvl(*samples)
    FakeGVL.new(*samples).tap { |gvl| @launcher.instance_variable_set(:@gvl, gvl) }
  end

  def test_the_heartbeat_records_gvl_contention
    fake_gvl(12.5, nil)
    beat

    assert_equal "12.5", proc_hash["gvl"]
    redis("HDEL", @launcher.proc_key, "gvl")
    beat

    refute proc_hash.key?("gvl")
    assert proc_hash.key?("rtt_us")
  end

  def test_gvl_contention_goes_to_statsd_every_heartbeat
    config.statsd = StatsdRecorder.new
    fake_gvl(3.5, nil, 60.0)
    3.times { beat }

    assert_equal [[:gauge, "gvl.contention", 3.5, {}], [:gauge, "gvl.contention", 60.0, {}]],
      config.statsd.calls.select { |c| c[1] == "gvl.contention" }
  end

  def test_contention_kept_high_warns_every_ten_minutes
    logs = capture_logs
    events = capture_events
    fake_gvl(50.0, 90.0, 49.9, 50.0, 70.0, 80.5, 99.0, 99.0)
    clock = 1000.0
    stub_method(Process, :clock_gettime, ->(*args) { (args.size == 1) ? clock : 1 }) do
      5.times { beat } # 50, 90, 49.9 (the streak ends), 50, 70
      beat # 80.5: three in a row
      beat # 99: within ten minutes of the warning
      clock += 600
      beat # 99
    end
    warning = "GVL contention is %s%%: threads spend most of their time waiting for each other; fewer threads per " \
      "process (and more processes) would run CPU-heavy jobs faster"

    assert_equal [format(warning, "80.5"), format(warning, "99.0")], logs.string.lines(chomp: true).grep(/GVL/).map { |l| l.delete_prefix("WARN: ") }
    assert_equal [["gvl.contended", {percent: 80.5}], ["gvl.contended", {percent: 99.0}]], events
  end

  def test_contention_high_from_the_start_warns_on_the_third_heartbeat
    events = capture_events
    fake_gvl(60.0, 60.0, 60.0)
    2.times { beat }

    assert_empty events
    beat

    assert_equal [["gvl.contended", {percent: 60.0}]], events
  end

  def test_gvl_warnings_are_ten_minutes_apart
    events = capture_events
    fake_gvl(*[75.0] * 6)
    clock = 1000.0
    stub_method(Process, :clock_gettime, ->(*args) { (args.size == 1) ? clock : 1 }) do
      3.times { beat } # warns
      clock += 1
      beat
      clock += 598
      beat
      clock += 1
      beat # 600s after the first warning
    end

    assert_equal [["gvl.contended", {percent: 75.0}]] * 2, events
    assert_same 1600.0, @launcher.instance_variable_get(:@last).fetch(:gvl)
  end

  def test_run_measures_the_gvl_unless_turned_off
    config.heartbeat_interval = 0.05
    gvl = fake_gvl

    assert_true config.gvl_monitoring
    @launcher.run

    assert_equal [:start], gvl.log
    @launcher.stop

    assert_equal %i[start stop], gvl.log
    other = started(Robin::Launcher.new(config))
    config.gvl_monitoring = false
    gvl = FakeGVL.new
    other.instance_variable_set(:@gvl, gvl)
    other.run
    other.stop

    assert_equal [:stop], gvl.log
  end

  def test_a_new_launcher_measures_with_the_extension
    assert_instance_of Robin::GVL, @launcher.instance_variable_get(:@gvl)
    assert_equal Robin.const_defined?(:NativeGVL), @launcher.instance_variable_get(:@gvl).available?
  end

  def test_slow_redis_is_reported_every_ten_minutes
    logs = capture_logs
    clock = 1000.0
    us = 0
    stub_method(Process, :clock_gettime, ->(*args) { (args.last == :microsecond) ? (us += 60_000) : clock }) do
      beat
      beat
      clock += 600
      beat
    end

    assert_equal ["WARN: Redis round trips take 60.0ms; jobs will be slow (is Redis far away, or overloaded?)"] * 2,
      logs.string.lines(chomp: true).grep(/round trips/)
  end

  def test_slow_redis_is_an_event
    events = capture_events
    clock = 1000.0
    us = 0
    stub_method(Process, :clock_gettime, ->(*args) { (args.last == :microsecond) ? (us += 70_000) : clock }) do
      beat
      clock += 1
      beat
      clock += 598
      beat
      clock += 1
      beat
    end

    assert_equal [["redis.slow", {rtt_us: 70_000}]] * 2, events
    assert_same 1600.0, @launcher.instance_variable_get(:@last).fetch(:slow_redis)
  end

  def test_fast_redis_is_not_reported
    logs = capture_logs
    us = 0
    stub_method(Process, :clock_gettime, ->(*args) { (args.last == :microsecond) ? (us += 50_000) : 1.0 }) { beat }

    assert_equal 50_000, Robin::Launcher::SLOW_REDIS_US
    assert_empty logs.string.lines.grep(/round trips/)
  end

  def test_work_tracking_and_metrics
    a = fake_processor
    b = fake_processor
    before = Robin.now_ms
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @launcher.work_started(a, FakeUnit.new("q", '{"class":"A"}', "k"))
    @launcher.work_started(b, FakeUnit.new("q", '{"class":"B"}'))

    assert_equal 2, @launcher.busy
    queue, raw, run_at, key = a.work

    assert_equal ["q", '{"class":"A"}', "k"], [queue, raw, key]
    assert_operator run_at, :>=, before
    @launcher.work_finished(a, {"class" => "Wrapper", "display_class" => "Real"}, 12.5, true)
    @launcher.work_finished_cleanup(b)

    assert_equal 0, @launcher.busy
    assert_operator a.finished_at, :>=, started
    assert_operator a.finished_at, :<=, Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal 1, a.finished
    assert_nil b.finished_at, "never finished a job"
    assert_equal 0, b.finished
    jobs, processed, failed = @launcher.collector.drain

    assert_equal [1, 0], [processed, failed]
    assert_equal ["Real"], jobs.keys
    @launcher.work_finished(a, {"class" => "Plain"}, 1, false)

    assert_equal ["Plain"], @launcher.collector.drain[0].keys
    @launcher.work_finished(a, {}, 1, false)

    assert_equal [nil], @launcher.collector.drain[0].keys
  end

  def test_successful_jobs_send_a_distribution_when_asked
    a = fake_processor
    config.statsd = StatsdRecorder.new(dogstatsd: true)
    @launcher.work_finished(a, {"class" => "A"}, 1, true)

    assert_empty config.statsd.calls
    config.statsd = StatsdRecorder.new(dogstatsd: true, distributions: true)
    @launcher.work_finished(a, {"class" => "W", "display_class" => "Real"}, 12.5, true)
    @launcher.work_finished(a, {"class" => "A"}, 3, false)

    assert_equal [[:distribution, "jobs.perform_dist", 12.5, {class: "Real"}]], config.statsd.calls
    config.statsd = nil
    @launcher.work_finished(a, {"class" => "A"}, 1, true)
  ensure
    config.statsd = nil
  end

  def test_running_work_is_kept_by_each_worker
    a = fake_processor
    b = fake_processor
    @launcher.work_started(a, FakeUnit.new("q", "{}"))

    assert_equal [[a, a.work]], @launcher.running
    assert_nil b.work
    @launcher.work_finished(a, {"class" => "A"}, 1, true)

    assert_nil a.work
    assert_empty @launcher.running
  end

  def test_hook_registration
    @launcher.every_beat { :a }
    @launcher.every_leader_beat { :b }
    hooks = @launcher.instance_variable_get(:@hooks)

    assert_equal [:a], hooks[:beat].map(&:call)
    assert_equal [:b], hooks[:leader].map(&:call)
  end

  # -- heartbeat ---------------------------------------------------------------

  def test_beat_publishes_process_state
    config.process_ttl = 33
    worker = fake_processor("robin.default.0")
    anonymous = fake_processor
    @launcher.work_started(worker, FakeUnit.new("q", '{"jid":"j1"}'))
    @launcher.work_started(anonymous, FakeUnit.new("r", '{"jid":"j2"}'))
    log = events_for(:heartbeat)
    before = Robin.now_ms
    beat
    after = Robin.now_ms
    data = proc_hash

    assert_equal [@launcher.identity], redis("SMEMBERS", config.key("processes"))
    assert_equal @launcher.process_info, JSON.parse(data["info"])
    assert_operator Float(data["beat"]), :>=, Robin.epoch_seconds(before)
    assert_operator Float(data["beat"]), :<=, Robin.epoch_seconds(after)
    assert_equal "2", data["busy"]
    assert_equal "1", data["concurrency"]
    assert_equal "false", data["quiet"]
    assert_equal "2048", data["rss"]
    assert_equal "0", data["leader"] # leadership is reported as of before this beat's election
    assert_equal [@launcher.inflight_key], redis("SMEMBERS", config.key("inflights"))
    assert_nil data["rtt_us"], "the first heartbeat has no earlier round trip to report"
    assert_operator redis("TTL", @launcher.proc_key), :>, 30
    assert_operator redis("TTL", @launcher.proc_key), :<=, 33
    assert_equal [:heartbeat], log
  end

  def test_beat_publishes_running_work
    config.process_ttl = 33
    worker = fake_processor("robin.default.0")
    anonymous = fake_processor
    raw = %({"jid":"j1","args":["s3cr3t-ciphertext"],"encrypted":1,"n":1.0e+20})
    @launcher.work_started(worker, FakeUnit.new("q", raw))
    @launcher.work_started(anonymous, FakeUnit.new("r", '{"jid":"j2"}'))
    run_at = worker.work[2]
    beat
    work = redis("HGETALL", "#{@launcher.proc_key}:work").each_slice(2).to_h

    assert_equal ["robin.default.0", anonymous.object_id.to_s].sort, work.keys.sort
    # The job's raw payload is kept as fetched (args stay encrypted), as a
    # string: {"queue", "payload", "run_at" (epoch seconds)}.
    assert_equal Robin.dump_json({"queue" => "q", "payload" => raw, "run_at" => Robin.epoch_seconds(run_at)}),
      work["robin.default.0"]
    assert_equal({"queue" => "r", "payload" => '{"jid":"j2"}', "run_at" => work_run_at(work, anonymous)},
      JSON.parse(work[anonymous.object_id.to_s]))
    assert_operator redis("TTL", "#{@launcher.proc_key}:work"), :<=, 33
    assert_operator redis("TTL", "#{@launcher.proc_key}:work"), :>, 30
  end

  def work_run_at(work, processor) = JSON.parse(work.fetch(processor.object_id.to_s)).fetch("run_at")

  def test_beat_escapes_queue_names
    @launcher.work_started(fake_processor("t"), FakeUnit.new(%(we"ird), "{}"))
    beat

    assert_equal %(we"ird), JSON.parse(redis("HGET", "#{@launcher.proc_key}:work", "t"))["queue"]
  end

  def test_beat_reports_leadership_from_before_the_tick
    beat

    assert_equal "0", proc_hash["leader"]
    beat

    assert_equal "1", proc_hash["leader"]
  end

  def test_a_process_that_is_no_leader_candidate_never_leads
    config.leader_candidate = false
    beat
    beat

    assert_equal "0", proc_hash["leader"]
    assert_nil Robin::Leader.current(config)
  end

  def test_beat_clears_old_work_and_marks_quiet
    redis("HSET", "#{@launcher.proc_key}:work", "stale", "{}")
    @launcher.instance_variable_set(:@quiet, true)
    beat

    assert_equal 0, redis("EXISTS", "#{@launcher.proc_key}:work")
    assert_equal "true", proc_hash["quiet"]
    assert_equal "0", proc_hash["busy"]
  end

  def test_beat_flushes_metrics_and_refreshes_state
    @launcher.collector.record("Job", 5, true)
    redis("SADD", config.key("paused"), "default")
    redis("ZADD", config.key("cancelled"), Robin.now_ms + 60_000, "gone")
    fetcher = @launcher.managers.first.fetcher
    beat

    assert_equal "1", redis("GET", config.key("stat", "processed"))
    assert_equal ["default"], fetcher.paused
    assert Robin::Cancellation.skip?(config, "gone")
    assert_equal @launcher.identity, Robin::Leader.current(config)
  end

  # Each capsule's jobs fetched for workers that never took them.
  def test_a_heartbeat_hands_back_every_capsules_stale_jobs_in_one_more_round_trip
    config.capsule("solo") { |c| c.queues = ["serial"] }
    launcher = started(Robin::Launcher.new(config))
    units = launcher.managers.map do |manager|
      fetcher = manager.fetcher
      unit_in_flight(fetcher, "{}", manager.capsule.queues.first).tap { |unit| fetcher.instance_variable_get(:@buffer) << [unit, 0] }
    end

    assert_roundtrips(2) { launcher.beat }
    assert_equal [["{}"], ["{}"]], [redis("LRANGE", config.key("queue", "default"), 0, -1), redis("LRANGE", config.key("queue", "serial"), 0, -1)]
    assert_equal units.map(&:key), launcher.managers.flat_map { |m| m.fetcher.held } & units.map(&:key), "freed"
    assert_roundtrips(1) { launcher.beat }
  end

  def test_a_heartbeat_takes_one_round_trip
    config.capsule("solo") { |c| c.queues = ["serial"] }
    launcher = started(Robin::Launcher.new(config))
    launcher.define_singleton_method(:rss_kb) { 2048 }
    launcher.collector.record("Job", 5, true)
    redis("SADD", config.key("paused"), "serial")
    redis("ZADD", config.key("cancelled"), Robin.now_ms + 60_000, "gone")
    real = config.housekeeping_pool
    pool = RecordingPool.new(real, nil)
    config.instance_variable_set(:@housekeeping_pool, pool)
    assert_roundtrips(1) { launcher.beat }
    calls = pool.calls

    assert_equal [[:multi]], calls.reject { |kind, *| %i[tx pipelined].include?(kind) }, "the sweep found nothing to pipeline"
    tx = calls.drop(1)
    zrange = tx.find { |c| c[1] == "ZRANGE" }

    assert_equal [:tx, "ZRANGE", config.key("cancelled"), "+inf", "BYSCORE"], zrange.values_at(0, 1, 2, 4, 5)
    assert_in_delta Robin.now_ms, zrange.fetch(3), 5_000
    assert_equal [[:tx, "SMEMBERS", config.key("paused")],
      [:tx, :evalsha, Robin::Scripts::LEASE, [config.key("leader")], [launcher.identity, Robin::Leader::TTL_MS]],
      [:tx, "SMEMBERS", launcher.inflight_key],
      [:tx, "INCRBY", config.key("stat", "processed"), 1]], tx[tx.index(zrange) + 1, 4]
    assert_equal [%w[serial], %w[serial]], launcher.managers.map { |m| m.fetcher.paused }
    assert Robin::Cancellation.skip?(config, "gone")
    assert_equal launcher.identity, Robin::Leader.current(config)
    assert_equal "1", redis("GET", config.key("stat", "processed"))
    assert_roundtrips(1) { launcher.beat } # and no sweep this time
    assert_operator Integer(redis("HGET", launcher.proc_key, "rtt_us")), :>, 0
  ensure
    config.instance_variable_set(:@housekeeping_pool, real) if real
  end

  def test_a_heartbeat_reports_the_round_trip_time_of_the_one_before
    beat
    beat
    rtt = Integer(proc_hash.fetch("rtt_us"))

    assert_operator rtt, :>, 0
    assert_operator rtt, :<, 5_000_000
  end

  def test_a_heartbeat_reports_gvl_contention_with_its_state
    @launcher.instance_variable_get(:@gvl).define_singleton_method(:sample) { 12.5 }
    beat

    assert_equal "12.5", proc_hash.fetch("gvl")
  end

  def test_a_heartbeat_of_no_leader_candidate_sends_no_lease
    config.leader_candidate = false
    real = config.housekeeping_pool
    pool = RecordingPool.new(real, nil)
    config.instance_variable_set(:@housekeeping_pool, pool)
    assert_roundtrips(1) { beat }

    assert_equal [[:multi]], pool.calls.reject { |kind, *| %i[tx pipelined].include?(kind) }
    refute pool.calls.any? { |c| c[1] == :evalsha }
    refute_predicate @launcher.leader, :leader?
  ensure
    config.instance_variable_set(:@housekeeping_pool, real) if real
  end

  def test_a_heartbeat_reads_the_in_flight_keys_only_when_it_sweeps
    real = config.housekeeping_pool
    pool = RecordingPool.new(real, nil)
    config.instance_variable_set(:@housekeeping_pool, pool)
    sweeps = Array.new(2) do
      beat
      pool.calls.count { |call| call == [:tx, "SMEMBERS", @launcher.inflight_key] }.tap { pool.recorders.clear }
    end

    assert_equal [1, 0], sweeps
    assert_empty @errors
  ensure
    config.instance_variable_set(:@housekeeping_pool, real) if real
  end

  def test_a_failing_sweep_is_reported_and_the_heartbeat_goes_on
    @launcher.define_singleton_method(:sweep_inflight) { |*| raise "sweep broke" }
    seen = []
    @launcher.define_singleton_method(:handle_signal) { |sig| seen << sig }
    redis("LPUSH", "#{@launcher.proc_key}-signals", "TSTP")
    beat

    assert_equal [["sweep broke", {context: "sweep"}]], @errors.map { |e, ctx| [e.message, ctx] }
    assert_equal ["TSTP"], seen
  end

  def test_a_heartbeat_reports_the_metrics_it_wrote_to_statsd
    config.statsd = StatsdRecorder.new
    @launcher.collector.record("Job", 5, true)
    beat

    assert_includes config.statsd.calls, [:job_metrics, {"Job" => {s: 1, f: 0, ms: 5.0, hist: {0 => 1}}}]
  ensure
    config.statsd = nil
  end

  def test_a_heartbeat_that_fails_before_it_takes_the_metrics_raises_its_own_error
    @launcher.collector.record("Job", 5, true)
    failing = Object.new
    failing.define_singleton_method(:multi) { |&_| raise Robin::Redis::ConnectionError, "down" }
    real = config.housekeeping_pool
    config.instance_variable_set(:@housekeeping_pool, Struct.new(:conn) { def with = yield(conn) }.new(failing))

    assert_raises(Robin::Redis::ConnectionError) { beat }
    assert_equal [{"Job" => {s: 1, f: 0, ms: 5.0, hist: {0 => 1}}}, 1, 0], @launcher.collector.drain
  ensure
    config.instance_variable_set(:@housekeeping_pool, real) if real
  end

  def test_metrics_a_failed_heartbeat_couldnt_write_go_with_the_next
    @launcher.collector.record("Job", 5, true)
    # The heartbeat's transaction is put together, then fails to go out.
    failing = Object.new
    failing.define_singleton_method(:multi) do |&block|
      block.call(Robin::Redis::Pipeline.new)
      raise Robin::Redis::ConnectionError, "down"
    end
    real = config.housekeeping_pool
    config.instance_variable_set(:@housekeeping_pool, Struct.new(:conn) { def with = yield(conn) }.new(failing))

    assert_raises(Robin::Redis::ConnectionError) { beat }
    config.instance_variable_set(:@housekeeping_pool, real)
    beat

    assert_equal "1", redis("GET", config.key("stat", "processed"))
  ensure
    config.instance_variable_set(:@housekeeping_pool, real) if real
  end

  def test_beat_handles_remote_signals_in_order
    seen = []
    @launcher.define_singleton_method(:handle_signal) { |sig| seen << sig }
    # Senders LPUSH, so the oldest signal is at the tail.
    redis("LPUSH", "#{@launcher.proc_key}-signals", "TSTP", *Array.new(200, "x"), "TTIN")
    beat

    assert_equal ["TSTP", *Array.new(200, "x"), "TTIN"], seen
    assert_equal 0, redis("EXISTS", "#{@launcher.proc_key}-signals")
    seen.clear
    beat

    assert_empty seen
  end

  # -- idle GC ---------------------------------------------------------------

  # The full GCs the launcher's beats run.
  def collections(launcher = @launcher)
    gcs = []
    launcher.define_singleton_method(:collect_garbage) { gcs << :gc }
    gcs
  end

  def ago(seconds) = Process.clock_gettime(Process::CLOCK_MONOTONIC) - seconds

  def test_idle_gc_waits_a_second
    assert_equal 1, Robin::Launcher::IDLE_GC_AFTER
  end

  # The launcher's clock reads +now+ (monotonic seconds).
  def at(now) = @launcher.define_singleton_method(:monotonic) { now }

  def test_beat_collects_garbage_once_a_second_after_the_last_job
    config.idle_gc = true
    gcs = collections
    a = fake_processor
    b = fake_processor
    at(100.0)
    beat

    assert_empty gcs, "no job ever finished"
    a.finish(99.5)
    b.finish(97.0)
    beat

    assert_empty gcs, "the last one finished half a second ago"
    at(100.5)
    beat

    assert_equal [:gc], gcs, "a second after"
    at(110.0)
    beat

    assert_equal [:gc], gcs, "none finished since"
    a.finish(100.75)
    beat

    assert_equal [:gc, :gc], gcs
  end

  def test_beat_collects_garbage_after_enough_jobs
    config.idle_gc = 3
    gcs = collections
    a = fake_processor
    b = fake_processor
    at(100.0)
    a.finish(90.0)
    b.finish(90.0)
    beat

    assert_empty gcs, "two jobs"
    b.finish(91.0)
    beat

    assert_equal [:gc], gcs, "three"
    2.times { a.finish(92.0) }
    beat

    assert_equal [:gc], gcs, "two since"
    b.finish(99.5)
    beat

    assert_equal [:gc], gcs, "three since, but the last half a second ago"
    at(100.5)
    beat

    assert_equal [:gc, :gc], gcs
  end

  def test_beat_collects_no_garbage_while_a_job_runs
    config.idle_gc = true
    gcs = collections
    fake_processor.finish(ago(2))
    fake_processor.work = ["q", "{}", Robin.now_ms, "k"]
    beat

    assert_empty gcs
  end

  def test_beat_collects_no_garbage_unless_asked
    config.idle_gc = false
    gcs = collections
    fake_processor.finish(ago(2))
    beat

    assert_empty gcs
  end

  def test_embedded_servers_collect_no_garbage
    config.idle_gc = true
    launcher = started(Robin::Launcher.new(config, embedded: true))
    launcher.define_singleton_method(:rss_kb) { 1 }
    gcs = collections(launcher)
    FakeProcessor.new.tap { |p| launcher.managers.first.instance_variable_get(:@processors) << p }.finish(ago(2))
    launcher.beat

    assert_empty gcs
  end

  def test_collect_garbage_runs_a_full_gc
    calls = []
    stub_method(GC, :start, ->(*args) { calls << args }) { @launcher.send(:collect_garbage) }

    assert_equal [[]], calls
  end

  def test_beat_runs_hooks_and_checks_memory
    order = []
    @launcher.every_beat { |conn| order << [:beat, conn.class] }
    @launcher.define_singleton_method(:check_memory) { order << :memory }
    config.on(:heartbeat) { order << :heartbeat }
    beat

    assert_equal [[:beat, Robin::Redis::Connection], :memory, :heartbeat], order
  end

  # -- signals -------------------------------------------------------------------

  def test_handle_signal
    calls = []
    %i[quiet request_stop dump_threads].each { |m| @launcher.define_singleton_method(m) { calls << m } }
    logs = capture_logs
    %w[TSTP TERM TTIN quiet].each { |s| @launcher.handle_signal(s) }

    assert_equal %i[quiet request_stop dump_threads], calls
    assert_equal "WARN: ignoring unknown remote signal \"quiet\"\n", logs.string
  end

  # -- resize ------------------------------------------------------------------

  def concurrencies(launcher = @launcher) = launcher.managers.map(&:concurrency)

  def with_solo_capsule(concurrency: 2, name: "solo")
    config.capsule(name) { |c| c.concurrency = concurrency }
    started(Robin::Launcher.new(config))
  end

  def test_concurrency_counts_every_capsule
    launcher = with_solo_capsule

    assert_equal 3, launcher.concurrency
    launcher.managers.last.resize(5)

    assert_equal 6, launcher.concurrency
  end

  def test_resize_rejects_bad_counts_and_unknown_capsules
    [0, -1, 2.5, "3", nil].each do |count|
      error = assert_raises(ArgumentError) { @launcher.resize(count) }

      assert_equal "a capsule needs a concurrency above 0, not #{count.inspect}", error.message
    end
    error = assert_raises(ArgumentError) { @launcher.resize(2, capsule: "nope") }

    assert_equal %(no capsule named "nope"), error.message
    assert_equal [1], concurrencies
  end

  def test_resize_grows_a_pool_robin_sized_and_reports_it
    Robin.server!
    launcher = with_solo_capsule
    logs = capture_logs
    events = capture_events

    assert_true launcher.resize(20, capsule: "solo")
    assert_equal [1, 20], concurrencies(launcher)
    assert_equal 26, config.redis_pool.size # 21 workers, plus 5
    assert_true launcher.resize(3)
    assert_equal [3, 20], concurrencies(launcher)
    assert_equal 28, config.redis_pool.size
    assert_equal %(INFO: capsule "solo" now runs 20 workers (was 2)\nINFO: capsule "default" now runs 3 workers (was 1)\n), logs.string
    assert_equal [["workers.resized", {capsule: "solo", from: 2, to: 20}],
      ["workers.resized", {capsule: "default", from: 1, to: 3}]], events
  ensure
    Robin.instance_variable_set(:@server, nil)
  end

  def test_resize_refuses_more_workers_than_a_set_pool_size_serves
    config.redis = {url: REDIS_URL, pool_size: 6}
    launcher = with_solo_capsule
    logs = capture_logs
    events = capture_events

    assert_false launcher.resize(4, capsule: "solo")
    assert_equal [1, 2], concurrencies(launcher)
    assert_equal %(WARN: not resizing capsule "solo" to 4: 5 workers need a Redis pool of 7 connections, but :pool_size is 6\n),
      logs.string
    assert_empty events
    assert_true launcher.resize(3, capsule: "solo")
    assert_equal [1, 3], concurrencies(launcher)
    assert_equal 6, config.redis_pool.size
  end

  def test_a_quiet_process_is_not_resized
    logs = capture_logs
    @launcher.quiet
    events = capture_events
    pool_size = config.redis_pool.size

    assert_false @launcher.resize(30)
    assert_equal [1], concurrencies
    assert_equal pool_size, config.redis_pool.size
    assert_empty events
    assert_equal %(WARN: not resizing capsule "default" to 30: the process is quiet\n), logs.string.lines.last
  end

  def test_resizing_shows_in_health_title_process_info_and_heartbeat
    capture_logs
    @launcher.resize(3)

    assert_equal 3, @launcher.health["concurrency"]
    assert_equal "robin #{Robin::VERSION} web [0 of 3 busy]", @launcher.title
    info = @launcher.process_info

    assert_equal 3, info["concurrency"]
    assert_equal 3, info.dig("capsules", "default", "concurrency")
    beat

    assert_equal "3", proc_hash["concurrency"]
    assert_equal 3, JSON.parse(proc_hash["info"]).dig("capsules", "default", "concurrency")
  end

  def test_remote_resize
    Robin.server!
    launcher = with_solo_capsule(name: "my\nown capsule")
    logs = capture_logs
    launcher.handle_signal("RESIZE 3 default")
    launcher.handle_signal("RESIZE 012 my\nown capsule")

    assert_equal [3, 12], concurrencies(launcher), "counts are decimal; capsule names are the rest"
    assert_empty @errors
    launcher.handle_signal("RESIZE 2 nope")
    launcher.handle_signal("RESIZE 0 default")

    assert_equal [[ArgumentError, %(no capsule named "nope"), {context: "resize"}],
      [ArgumentError, "a capsule needs a concurrency above 0, not 0", {context: "resize"}]],
      @errors.map { |e, ctx| [e.class, e.message, ctx] }
    ["RESIZE x default", "RESIZE 2", "RESIZE  default", " RESIZE 2 default", "RESIZE 2 default\nTERM"].each do |sig|
      launcher.handle_signal(sig)
    end

    assert_equal [3, 12], concurrencies(launcher)
    assert_equal ["WARN: ignoring unknown remote signal \"RESIZE x default\"", "WARN: ignoring unknown remote signal \"RESIZE 2\"",
      "WARN: ignoring unknown remote signal \"RESIZE  default\"", "WARN: ignoring unknown remote signal \" RESIZE 2 default\""],
      logs.string.lines(chomp: true).grep(/WARN: ignoring/)
    assert_equal [[ArgumentError, %(no capsule named "default\\nTERM")]], @errors.drop(2).map { |e, _ctx| [e.class, e.message] }
  ensure
    Robin.instance_variable_set(:@server, nil)
  end

  def test_beat_handles_remote_resizes
    capture_logs
    redis("LPUSH", "#{@launcher.proc_key}-signals", "RESIZE 4 default")
    beat

    assert_equal [4], concurrencies
  end

  def test_request_stop_uses_callback
    called = 0
    @launcher.on_stop_request = -> { called += 1 }
    @launcher.request_stop

    assert_equal 1, called
  end

  def test_request_stop_defaults_to_background_stop
    stopped = Queue.new
    @launcher.define_singleton_method(:stop) { stopped << Thread.current }
    thread = @launcher.request_stop

    assert_kind_of Thread, thread
    refute_same Thread.current, stopped.pop
  end

  def test_dump_threads
    t = Thread.new { sleep }
    t.name = "dumpme"
    sleep 0.01 until t.status == "sleep"
    logs = capture_logs
    @launcher.dump_threads
    t.kill
    t.join

    assert_includes logs.string, "WARN: Thread dumpme (sleep)\n"
    assert_includes logs.string, "WARN: Thread #{Thread.main.object_id} (run)\n" if Thread.main.name.nil?

    assert_match(/launcher_test\.rb:\d+/, logs.string)
  end

  def test_dump_threads_joins_frames_with_newlines
    fake = Struct.new(:name, :status, :backtrace).new("t1", "run", %w[a:1 b:2])
    stub_method(Thread, :list, -> { [fake] }) do
      logs = capture_logs
      @launcher.dump_threads

      assert_equal "WARN: Thread t1 (run)\nWARN: a:1\nb:2\n", logs.string
    end
  end

  def test_dump_threads_without_backtrace
    dead = Thread.new { nil }.tap(&:join)
    stub_method(Thread, :list, -> { [dead] }) do
      logs = capture_logs
      @launcher.dump_threads

      assert_equal "WARN: Thread #{dead.object_id} (false)\nWARN: <no backtrace>\n", logs.string
    end
  end

  # -- leader duties -------------------------------------------------------------

  def test_leader_hooks_run_only_on_the_leader_and_are_throttled
    calls = []
    stub_method(Robin::Metrics, :sample_queues, ->(*args) { calls << [:sample, args.first, args.last.class, args.size] }) do
      stub_method(Robin::Recovery, :run, ->(cfg, pool:) { calls << [:recovery, cfg, pool] }) do
        @launcher.every_leader_beat { |conn| calls << [:leader_hook, conn.class] }
        redis("SET", config.key("leader"), "someone-else")
        beat
        @launcher.send(:leader_chores)

        assert_empty calls
        redis("DEL", config.key("leader"))
        beat
        @launcher.send(:leader_chores)
        @launcher.send(:leader_chores)

        assert_equal [[:sample, config, Robin::Redis::Connection, 2], [:recovery, config, config.housekeeping_pool],
          [:leader_hook, Robin::Redis::Connection], [:leader_hook, Robin::Redis::Connection]], calls
      end
    end
  end

  def test_failing_hooks_are_reported_and_isolated
    ran = []
    @launcher.every_beat { raise "beat hook broke" }
    @launcher.every_beat { ran << :beat2 }
    @launcher.every_leader_beat { raise "leader hook broke" }
    @launcher.every_leader_beat { ran << :leader2 }
    @launcher.leader.define_singleton_method(:leader?) { true }
    @launcher.instance_variable_set(:@last, Hash.new(Float::INFINITY))
    @launcher.beat
    @launcher.send(:leader_chores)

    assert_equal %i[beat2 leader2], ran
    assert_equal [["beat hook broke", {context: "beat hook"}], ["leader hook broke", {context: "leader hook"}]],
      @errors.map { |e, c| [e.message, c] }
  end

  def test_every_throttles_by_name
    runs = []
    @launcher.send(:every, 30, :x) { runs << :x1 }
    @launcher.send(:every, 30, :x) { runs << :x2 }
    @launcher.send(:every, 30, :y) { runs << :y1 }
    last = @launcher.instance_variable_get(:@last)
    last[:x] -= 29.5

    @launcher.send(:every, 30, :x) { runs << :x3 }
    last[:x] -= 1

    @launcher.send(:every, 30, :x) { runs << :x4 }
    last[:x] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 31
    @launcher.send(:every, 30, :x) { runs << :x5 }

    assert_equal %i[x1 y1 x4 x5], runs
  end

  def test_every_reports_errors_with_its_name
    @launcher.send(:every, 1, :sample_queues) { raise "nope" }

    assert_equal [["nope", {context: "sample_queues"}]], @errors.map { |e, c| [e.message, c] }
  end

  def test_leader_duties_have_their_intervals
    seen = []
    @launcher.define_singleton_method(:every) { |s, n, &_b| seen << [s, n] }
    @launcher.leader.define_singleton_method(:leader?) { true }
    @launcher.send(:leader_chores)

    assert_equal [[60, :sample_queues], [30, :recovery], [60, :prune]], seen
  end

  def test_prune_processes
    redis("SADD", config.key("processes"), "alive", "dead1", "dead2")
    redis("SET", config.process_key("alive"), "1")

    assert_equal 2, config.redis { |c| assert_roundtrips(1) { @launcher.send(:prune_processes, c) } }
    assert_equal ["alive"], redis("SMEMBERS", config.key("processes"))
    redis("DEL", config.key("processes"))

    assert_equal 0, config.redis { |c| @launcher.send(:prune_processes, c) }
  end

  def test_prune_runs_from_leader_hooks
    redis("SADD", config.key("processes"), "ghost")
    beat
    @launcher.send(:leader_chores)

    refute_includes redis("SMEMBERS", config.key("processes")), "ghost"
    assert_includes redis("SMEMBERS", config.key("processes")), @launcher.identity
  end

  # -- memory -------------------------------------------------------------------

  def test_check_memory
    stops = 0
    @launcher.define_singleton_method(:request_stop) { stops += 1 }
    @launcher.send(:check_memory)
    config.memory_limit_mb = 3
    @launcher.send(:check_memory)

    assert_equal 0, stops
    config.memory_limit_mb = 2
    logs = capture_logs
    @launcher.send(:check_memory)

    assert_equal 1, stops
    assert_equal "WARN: RSS 2MB exceeds memory_limit_mb 2MB; restarting gracefully\n", logs.string
    @launcher.instance_variable_set(:@done, true)
    @launcher.send(:check_memory)

    assert_equal 1, stops
  end

  def test_exceeding_the_memory_limit_is_an_event
    events = capture_events
    @launcher.define_singleton_method(:request_stop) { nil }
    @launcher.define_singleton_method(:rss_kb) { 5 * 1024 }
    config.memory_limit_mb = 6
    @launcher.send(:check_memory)

    assert_empty events
    config.memory_limit_mb = 4
    @launcher.send(:check_memory)

    assert_equal [["memory.exceeded", {rss_mb: 5, limit_mb: 4}]], events
  end

  def test_check_memory_uses_whole_megabytes
    stops = 0
    @launcher.define_singleton_method(:request_stop) { stops += 1 }
    @launcher.define_singleton_method(:rss_kb) { 2047 }
    config.memory_limit_mb = 2
    @launcher.send(:check_memory)

    assert_equal 0, stops
  end

  def test_rss_from_proc_status
    launcher = Robin::Launcher.new(config)
    stub_method(File, :readable?, ->(path) { path == "/proc/self/status" }) do
      stub_method(File, :read, ->(path) { (path == "/proc/self/status") ? "Name: ruby\nVmHWM:\t 9999 kB\nVmRSS:\t  4321 kB\n" : "" }) do
        assert_equal 4321, launcher.send(:rss_kb)
      end
    end
  end

  def test_rss_from_ps_and_cached
    launcher = Robin::Launcher.new(config)
    commands = []
    launcher.define_singleton_method(:`) do |cmd|
      commands << cmd
      " 777\n"
    end
    stub_method(File, :readable?, ->(_path) { false }) do
      assert_equal 777, launcher.send(:rss_kb)
      assert_equal 777, launcher.send(:rss_kb)
    end

    assert_equal ["ps -o rss= -p #{Process.pid}"], commands
    launcher.instance_variable_set(:@rss_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 14)
    stub_method(File, :readable?, ->(_path) { false }) { launcher.send(:rss_kb) }

    assert_equal 1, commands.size
    launcher.instance_variable_set(:@rss_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 15.5)
    stub_method(File, :readable?, ->(_path) { false }) { launcher.send(:rss_kb) }

    assert_equal 2, commands.size
  end

  def test_rss_tolerates_missing_whitespace
    launcher = Robin::Launcher.new(config)
    stub_method(File, :readable?, ->(_path) { true }) do
      stub_method(File, :read, ->(_path) { "VmRSS:55 kB\n" }) do
        assert_equal 55, launcher.send(:rss_kb)
      end
    end
  end

  def test_rss_without_a_vmrss_line_reads_as_zero
    launcher = Robin::Launcher.new(config)
    stub_method(File, :readable?, ->(_path) { true }) do
      stub_method(File, :read, ->(_path) { "Name: ruby\n" }) do
        assert_equal 0, launcher.send(:rss_kb)
      end
    end
  end

  def test_rss_failure_reads_as_zero
    launcher = Robin::Launcher.new(config)

    stub_method(File, :readable?, ->(_path) { raise Errno::EACCES }) do
      assert_equal 0, launcher.send(:rss_kb)
    end
  end

  def test_real_rss_is_positive
    assert_operator Robin::Launcher.new(config).send(:rss_kb), :>, 0
  end

  def test_safely
    assert_equal :ok, @launcher.send(:safely, "x") { :ok }
    @launcher.send(:safely, "thing") { raise "bad" }

    assert_equal [["bad", {context: "thing"}]], @errors.map { |e, c| [e.message, c] }
  end

  # -- run / quiet / stop -------------------------------------------------------

  def test_quiet
    quieted = []
    @launcher.managers.each { |m| m.define_singleton_method(:quiet) { quieted << self } }
    order = []
    config.on(:quiet) { order << 1 }
    config.on(:quiet) { order << 2 }
    logs = capture_logs
    @launcher.quiet
    @launcher.quiet

    assert_true @launcher.quiet?
    assert_equal @launcher.managers, quieted
    assert_equal [2, 1], order
    assert_equal "INFO: quieting: no new jobs will be started\n", logs.string
  end

  def test_stop_without_requeue_and_nothing_in_flight
    config.shutdown_requeue = false
    unit = unit_in_flight(@launcher.managers.first.fetcher, "{}")
    logs = capture_logs
    @launcher.stop

    assert_equal ["{}"], in_flight(@launcher.inflight_key)
    refute_includes logs.string, "pushed"
    config.shutdown_requeue = true
    redis("DEL", @launcher.inflight_key, unit.key)
    logs = capture_logs
    Robin::Launcher.new(config).stop

    refute_includes logs.string, "pushed"
  end

  def test_stop_deletes_process_keys_and_flushes_metrics
    @launcher.work_started(fake_processor, FakeUnit.new("q", "{}"))
    beat
    @launcher.work_finished_cleanup(@launcher.running.first.first)
    redis("LPUSH", "#{@launcher.proc_key}-signals", "x")
    @launcher.collector.record("Job", 1, false)
    @launcher.stop

    assert_equal 0, redis("EXISTS", @launcher.proc_key, "#{@launcher.proc_key}:work", "#{@launcher.proc_key}-signals")
    assert_equal "1", redis("GET", config.key("stat", "failed"))
  end

  def test_stop_quiets_stops_the_scheduler_and_unregisters
    quiets = []
    config.on(:quiet) { quiets << :quiet }
    Robin::Leader.register(config, @launcher.leader)
    @launcher.stop

    assert_predicate @launcher, :quiet?
    assert_equal [:quiet], quiets
    assert @launcher.instance_variable_get(:@scheduler).instance_variable_get(:@done)
    refute Robin::Leader.instance_variable_get(:@leaders).key?(config.object_id)
  end

  def test_stop_passes_the_shutdown_deadline_to_managers
    config.timeout = 7
    deadlines = []
    @launcher.managers.each { |m| m.define_singleton_method(:stop) { |d, hard| deadlines << [d, hard] } }
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @launcher.stop
    deadline, hard = deadlines.first

    assert_in_delta now + 7, deadline, 0.5
    assert_in_delta deadline + 3, hard, 0.001
    assert_equal 3, Robin::Launcher::HARD_SHUTDOWN_GRACE
  end

  def test_stop_marks_the_process_stopping_and_requeues_without_counting
    config.timeout = 7
    stopping = config.key("stopping", @launcher.identity)
    seen = []
    @launcher.managers.each { |m| m.define_singleton_method(:stop) { |_d, _h| seen << [:managers, Robin.redis { |c| c.call("GET", stopping) }] } }
    drain = lambda do |cfg, _conn, list, **opts|
      seen << [:drain, cfg, list, opts, Robin.redis { |c| c.call("TTL", stopping) }]
      0
    end
    stub_method(Robin::Recovery, :drain, drain) { @launcher.stop }

    assert_equal [:managers, "1"], seen.first
    _, cfg, list, opts, ttl = seen.last

    assert_same config, cfg
    assert_equal [@launcher.inflight_key, {count: false}], [list, opts]
    assert_includes 3_606..3_607, ttl
    assert_equal 0, redis("EXISTS", stopping)
  end

  # -- boot checks ------------------------------------------------------------

  # Answers INFO with +info+ while the block runs.
  def with_info(info, id: "127.0.0.1:6379/0", ssl: false)
    fake = Object.new
    fake.define_singleton_method(:call) { |*args| (args == ["INFO"]) ? info : raise("unexpected #{args}") }
    fake.define_singleton_method(:id) { id }
    fake.define_singleton_method(:options) { {ssl: ssl} }
    config.define_singleton_method(:redis) { |&blk| blk.call(fake) }
    yield
  ensure
    config.singleton_class.remove_method(:redis)
  end

  def test_check_accepts_a_healthy_setup_and_says_where_jobs_are
    logs = capture_logs
    with_info("redis_version:7.2.4\r\nmaxmemory_policy:noeviction\r\n") { @launcher.send(:check!) }

    assert_equal "INFO: Redis 7.2.4 at 127.0.0.1:6379/0; keys under #{config.key_prefix.inspect}\n", logs.string
  end

  def test_the_redis_log_line_shows_tls_and_robins_own_prefix
    logs = capture_logs
    config.internal_key_prefix = "own:"
    with_info("redis_version:8.0.0\r\n", id: "sentinel:mymaster/2", ssl: true) { @launcher.send(:check!) }

    assert_equal "INFO: Redis 8.0.0 at sentinel:mymaster/2 over TLS; keys under #{config.key_prefix.inspect}, " \
      "Robin's own under \"own:\"\n", logs.string
  end

  def test_the_redis_log_line_never_shows_the_password
    conn = Robin::Redis::Connection.new(**Robin::Redis::Connection.parse_url("redis://user:s3cret@127.0.0.1:1/0"))

    assert_equal "Redis 7.4.0 at 127.0.0.1:1/0; keys under #{config.key_prefix.inspect}", @launcher.send(:connected, conn, "7.4.0")
  end

  def test_check_rejects_old_redis
    error = assert_raises(ArgumentError) { with_info("redis_version:6.0.9\r\n") { @launcher.send(:check!) } }

    assert_equal "Robin needs Redis 6.2 or later; this server runs 6.0.9", error.message
    with_info("redis_version:6.2.0\r\n") { @launcher.send(:check!) }
  end

  def test_check_warns_about_eviction
    logs = capture_logs
    with_info("redis_version:8.0.0\r\nmaxmemory_policy:volatile-lru\r\n") { @launcher.send(:check!) }

    assert_includes logs.string, "WARN: Redis maxmemory-policy is volatile-lru; set it to noeviction"
    logs.truncate(0)
    logs.rewind
    with_info("redis_version:8.0.0\r\n") { @launcher.send(:check!) } # policy not reported (e.g. a proxy)

    refute_includes logs.string, "WARN"
  end

  def test_check_rejects_bad_concurrency_and_timeout
    config.capsule("solo").concurrency = 0
    error = assert_raises(ArgumentError) { @launcher.send(:check!) }

    assert_equal 'capsule "solo" needs a concurrency above 0', error.message
    config.capsule("solo").concurrency = 1
    config.timeout = 0
    error = assert_raises(ArgumentError) { @launcher.send(:check!) }

    assert_equal "the shutdown timeout must be above 0 seconds", error.message
    config.timeout = 1
    config.fetch_timeout = 0
    error = assert_raises(ArgumentError) { @launcher.send(:check!) }

    assert_equal "the fetch timeout must be above 0 seconds", error.message
  end

  def test_check_rejects_a_pool_too_small_for_the_workers
    config.concurrency = 5
    config.redis = {url: REDIS_URL, pool_size: 6}
    error = assert_raises(ArgumentError) { @launcher.send(:check!) }

    assert_equal "the Redis pool has 6 connections but 5 worker threads need at least 7; raise :pool_size or leave it unset", error.message
    config.redis = {url: REDIS_URL, pool_size: 7}
    @launcher.send(:check!)
  end

  def test_run_checks_before_anything_else
    @launcher.define_singleton_method(:check!) { raise ArgumentError, "unfit" }

    @launcher.define_singleton_method(:start_health_server) { flunk "must not listen" }

    config.on(:startup) { flunk "must not start" }
    error = assert_raises(ArgumentError) { @launcher.run }

    assert_equal "unfit", error.message
  end

  def test_check_compares_versions_numerically
    with_info("redis_version:10.0.0\r\n") { @launcher.send(:check!) }
    with_info("redis_version:7.0\r\n") { @launcher.send(:check!) }
    error = assert_raises(ArgumentError) { with_info("redis_version:6.1.99\r\n") { @launcher.send(:check!) } }

    assert_equal "Robin needs Redis 6.2 or later; this server runs 6.1.99", error.message
  end

  # -- health ------------------------------------------------------------------

  def health_at(clock)
    result = nil
    stub_method(Process, :clock_gettime, ->(*) { clock }) { result = @launcher.health }
    result
  end

  def test_health
    report = @launcher.health

    assert_equal({"healthy" => false, "status" => "stale", "identity" => @launcher.identity, "heartbeat_age" => nil,
                  "busy" => 0, "concurrency" => 1}, report)
    beat
    report = @launcher.health

    assert_equal "ok", report.fetch("status")
    assert report.fetch("healthy")
    assert_operator report.fetch("heartbeat_age"), :>=, 0
    assert_operator report.fetch("heartbeat_age"), :<, 1
    beat_at = @launcher.instance_variable_get(:@beat_at)

    assert_equal 60, config.process_ttl
    assert_equal ["ok", true, 60.0], health_at(beat_at + 60).values_at("status", "healthy", "heartbeat_age")
    assert_equal ["stale", false, 60.001], health_at(beat_at + 60.001).values_at("status", "healthy", "heartbeat_age")
    assert_in_delta 1.235, health_at(beat_at + 1.23456)["heartbeat_age"], 1e-9
    capture_logs
    @launcher.quiet

    assert_equal ["quiet", true], @launcher.health.values_at("status", "healthy")
    @launcher.instance_variable_set(:@done, true)

    assert_equal ["stopping", false], @launcher.health.values_at("status", "healthy")
  end

  def test_health_counts_busy_workers
    @launcher.managers.first.resize(3)
    @launcher.work_started(fake_processor, FakeUnit.new("q", "{}"))

    assert_equal [1, 3], @launcher.health.values_at("busy", "concurrency")
  end

  def test_no_health_server_without_a_port
    @launcher.send(:start_health_server)

    assert_nil @launcher.instance_variable_get(:@health)
  end

  def test_health_server_listens_on_the_configured_port
    config.health_port = 0
    config.health_bind = "127.0.0.1"
    logs = capture_logs
    @launcher.send(:start_health_server)
    health = @launcher.instance_variable_get(:@health)

    assert_equal "INFO: health check listening on 127.0.0.1:#{health.port}\n", logs.string
    assert_equal "127.0.0.1", health.instance_variable_get(:@server).addr[3]
    assert_includes http_get(health.port), '"status":"stale"'
  ensure
    health&.stop
  end

  def test_swarm_children_add_their_index_to_the_health_port
    free = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    config.health_port = free - 2
    config.health_bind = "127.0.0.1"
    capture_logs
    ENV["ROBIN_SWARM_INDEX"] = "2"
    @launcher.send(:start_health_server)
    health = @launcher.instance_variable_get(:@health)

    assert_equal free, health.port
  ensure
    ENV.delete("ROBIN_SWARM_INDEX")
    health&.stop
  end

  def test_a_failing_startup_hook_stops_the_boot
    config.on(:startup) { raise "missing setting" }
    started = []
    @launcher.managers.each { |m| m.define_singleton_method(:start) { started << m } }
    error = assert_raises(RuntimeError) { @launcher.run }

    assert_equal "missing setting", error.message
    assert_empty started
    refute Robin::Leader.instance_variable_get(:@leaders).key?(config.object_id)
  end

  def test_a_failing_startup_hook_closes_the_health_port
    config.on(:startup) { raise "missing setting" }
    config.health_port = 0
    config.health_bind = "127.0.0.1"
    capture_logs
    assert_raises(RuntimeError) { @launcher.run }
    health = @launcher.instance_variable_get(:@health)

    assert_raises(Errno::ECONNREFUSED) { http_get(health.port) }
    refute_predicate @launcher, :stopping? # only the port closes
  end

  def test_stopping_marker_rounds_a_fractional_timeout_up
    config.timeout = 0.4
    @launcher.send(:mark_stopping)

    # EX 3601 (3600.4 rounded up), never 3600.
    assert_operator redis("PTTL", config.key("stopping", @launcher.identity)), :>, 3_600_000
  end

  def test_stop_survives_redis_errors
    calls = []
    stub_method(Robin::Recovery, :drain, ->(*, **) { raise "drain failed" }) do
      @launcher.define_singleton_method(:mark_stopping) { raise "mark failed" }
      @launcher.instance_variable_get(:@leader).define_singleton_method(:resign) { |_c| raise "resign failed" }
      @launcher.collector.define_singleton_method(:flush) { |*| raise "flush failed" }
      @launcher.stop
      calls = @errors.map { |e, c| [e.message, c[:context]] }
    end

    assert_equal [["mark failed", "mark stopping"], ["flush failed", "final metrics flush"], ["drain failed", "requeue in-flight jobs"],
      ["resign failed", "unregister"]], calls
  end

  # -- sweeping a live process's in-flight keys -----------------------------------

  def fetcher = @launcher.managers.first.fetcher

  def inflight_unit(jid, queue: "q") = unit_in_flight(fetcher, JSON.generate({"class" => "X", "args" => [], "jid" => jid, "queue" => queue}), queue)

  def inflight = in_flight(@launcher.inflight_key)

  def registered = redis("SMEMBERS", @launcher.inflight_key).sort

  # Sweeps with the keys registered now, making +trips+ round trips.
  def sweep(conn = nil, trips: 0..)
    registered = redis("SMEMBERS", @launcher.inflight_key)
    assert_roundtrips(trips) do
      next @launcher.send(:sweep_inflight, conn, registered) if conn

      config.housekeeping_pool.with { |c| @launcher.send(:sweep_inflight, c, registered) }
    end
  end

  def test_sweep_requeues_jobs_unheld_on_two_sweeps_in_a_row
    logs = capture_logs
    held = inflight_unit("held")
    orphan = inflight_unit("orphan")
    fake_processor.work = ["q", held.raw, 1, held.key]
    sweep(trips: 1)

    assert_equal [held.raw, orphan.raw].sort, inflight, "first sighting only makes it a suspect"
    sweep(trips: 2) # a look, then the move

    assert_equal [held.raw], inflight
    assert_equal [held.key], registered, "the emptied key is unregistered"
    assert_equal [orphan.raw], redis("LRANGE", config.key("queue", "q"), 0, -1)
    assert_includes redis("SMEMBERS", config.key("queues")), "q"
    assert_includes logs.string, "WARN: put back 1 orphaned in-flight job(s)"
    logs.truncate(0)
    sweep(trips: 0) # nothing unheld to look at

    assert_empty logs.string
  end

  def test_sweep_reports_orphans_as_an_event
    events = capture_events
    inflight_unit("a")
    inflight_unit("b")
    sweep

    assert_empty events
    sweep
    sweep

    assert_equal [["jobs.orphaned", {count: 2}]], events
  end

  def test_sweep_counts_orphans_in_statsd
    config.statsd = StatsdRecorder.new
    inflight_unit("a")
    inflight_unit("b")
    sweep

    assert_empty config.statsd.calls
    sweep
    sweep

    assert_equal [[:increment, "jobs.orphaned", 2, {}]], config.statsd.calls
  ensure
    config.statsd = nil
  end

  def test_sweep_counts_jobs_awaiting_acknowledgement_as_held
    awaiting = inflight_unit("awaiting")
    orphan = inflight_unit("orphan")
    worker = @launcher.managers.first.processors.first
    worker.instance_variable_set(:@unacked, awaiting.key)
    sweep
    sweep

    assert_equal [awaiting.raw], inflight
    assert_equal [orphan.raw], redis("LRANGE", config.key("queue", "q"), 0, -1)
  end

  def test_sweep_counts_keys_the_fetcher_holds_as_held
    buffered = inflight_unit("buffered")
    finished = inflight_unit("finished")
    orphan = inflight_unit("orphan")
    fetcher.instance_variable_get(:@buffer) << [buffered, 0]
    fetcher.instance_variable_get(:@acks) << finished.key
    fetcher.instance_variable_get(:@free) << "#{@launcher.inflight_key}:free"
    redis("SADD", @launcher.inflight_key, "#{@launcher.inflight_key}:free")
    sweep
    sweep

    assert_equal [buffered.raw, finished.raw].sort, inflight
    assert_equal [orphan.raw], redis("LRANGE", config.key("queue", "q"), 0, -1)
    assert_includes registered, "#{@launcher.inflight_key}:free"
  end

  def test_sweep_leaves_jobs_that_were_picked_up_or_finished_meanwhile
    later_held = inflight_unit("later-held")
    finished = inflight_unit("finished")
    sweep
    fake_processor.work = ["q", later_held.raw, 1, later_held.key]
    config.redis { |c| fetcher.acknowledge(c, [finished.key]) }
    sweep
    sweep

    assert_equal [later_held.raw], inflight
    assert_equal 0, redis("LLEN", config.key("queue", "q"))
    assert_equal [later_held.key, finished.key].sort, registered
  end

  # A key acknowledged, freed and filled with another job between two
  # sweeps isn't the same orphan.
  def test_sweep_tells_a_key_filled_again_from_an_orphan
    unit = inflight_unit("first")
    sweep
    redis("DEL", unit.key)
    redis("RPUSH", unit.key, "second")
    sweep

    assert_equal %w[second], inflight
    assert_equal 0, redis("LLEN", config.key("queue", "q"))
  end

  # Left empty by a failed round trip (or an acknowledgement whose reply
  # was lost): unregistered, with nothing to put back.
  def test_sweep_unregisters_empty_keys_no_one_holds
    logs = capture_logs
    key = "#{@launcher.inflight_key}:dropped"
    redis("SADD", @launcher.inflight_key, key)
    sweep
    rec = config.housekeeping_pool.with { |c| RecordingConnection.new(c).tap { |r| sweep(r) } }

    assert_equal [:pipe, :evalsha, Robin::Scripts::REQUEUE_ONE, [key, config.key("queue", ""), config.key("queues"), @launcher.inflight_key], ["", ""]],
      rec.calls.last
    assert_empty registered
    assert_empty logs.string
  end

  def test_sweep_never_takes_a_key_its_fetcher_holds_by_then
    logs = capture_logs
    taken = inflight_unit("taken")
    orphan = inflight_unit("orphan")
    sweep
    fetcher.define_singleton_method(:forget) { |key| key != taken.key }
    sweep

    assert_equal [taken.raw], inflight
    assert_equal [taken.key], registered
    assert_equal [orphan.raw], redis("LRANGE", config.key("queue", "q"), 0, -1)
    assert_includes logs.string, "WARN: put back 1 orphaned in-flight job(s)"
    assert_empty @launcher.instance_variable_get(:@suspects)
  end

  # A key never holds more than one job, but if one did, they'd go back one
  # at a time, from the front.
  def test_sweep_puts_back_one_job_of_a_key_at_a_time
    key = "#{@launcher.inflight_key}:two"
    first, second = %w[a b].map { |jid| JSON.generate({"class" => "X", "args" => [], "jid" => jid, "queue" => "q"}) }
    redis("SADD", @launcher.inflight_key, key)
    redis("RPUSH", key, first, second)
    sweep
    sweep

    assert_equal [first], redis("LRANGE", config.key("queue", "q"), 0, -1)
    assert_equal [second], redis("LRANGE", key, 0, -1)
    assert_equal [key], registered
  end

  # Each capsule has a fetcher; any of them may hold the key.
  def test_sweep_asks_every_capsules_fetcher_to_forget_an_orphan
    kept = inflight_unit("kept")
    answer = false
    asked = []
    other = Object.new
    other.define_singleton_method(:held) { [] }
    other.define_singleton_method(:forget) { |key| (asked << key) && answer }
    @launcher.managers << Struct.new(:fetcher, :processors).new(other, [])
    sweep
    sweep

    assert_equal [kept.key], asked
    assert_equal [kept.raw], inflight, "the other capsule's fetcher holds it"
    answer = true
    sweep # a first sighting again

    assert_equal [kept.key], asked
    sweep

    assert_equal [kept.key, kept.key], asked
    assert_empty inflight
    assert_includes fetcher.instance_variable_get(:@lost), kept.key
  end

  def test_sweep_only_counts_jobs_it_actually_moved
    logs = capture_logs
    orphan = inflight_unit("orphan")
    sweep
    # A worker acknowledges it (its key goes for good) between the read
    # and the move.
    conn = config.housekeeping_pool.with { |c| c }
    real = conn.method(:pipelined)
    conn.define_singleton_method(:pipelined) do |**opts, &blk|
      real.call(**opts, &blk).tap { Robin.redis { |c| c.call("DEL", orphan.key) } }
    end
    sweep(conn)

    assert_empty logs.string
    assert_equal 0, redis("LLEN", config.key("queue", "q"))
    assert_empty registered
  ensure
    conn&.singleton_class&.remove_method(:pipelined)
  end

  def test_nap_returns_at_once_when_already_stopping
    @launcher.instance_variable_set(:@done, true)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @launcher.send(:nap, 30)

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  end

  def test_nap_sleeps_until_woken
    napper = Thread.new { @launcher.send(:nap, 30) }
    sleep 0.05

    assert_predicate napper, :alive?
    @launcher.send(:wake_up)

    assert napper.join(2)
  end

  def test_beats_sweep
    orphan = inflight_unit("orphan")
    @launcher.beat
    @launcher.instance_variable_get(:@last).delete(:sweep)
    @launcher.beat

    assert_equal [orphan.raw], redis("LRANGE", config.key("queue", "q"), 0, -1)
  end

  def test_sweep_reads_running_jobs_before_unacknowledged_ones
    unit = inflight_unit("finishing")
    worker = fake_processor
    worker.work = ["q", unit.raw, 1, unit.key]
    # The job finishes (and awaits acknowledgement) right after the sweep
    # first asks whether anything awaits acknowledgement.
    worker.define_singleton_method(:unacked) do
      value = @unacked
      @work = nil
      @unacked = unit.key
      value
    end
    sweep

    assert_empty @launcher.instance_variable_get(:@suspects)
  end

  def test_sweep_handles_many_keys
    orphans = Array.new(200) { |i| inflight_unit("o#{i}").raw }
    sweep
    sweep

    assert_empty registered
    assert_equal orphans.sort, redis("LRANGE", config.key("queue", "q"), 0, -1).sort
  end

  def test_a_requeued_job_seen_again_starts_over_as_a_suspect
    orphan = inflight_unit("orphan")
    sweep
    sweep # requeued
    redis("LREM", config.key("queue", "q"), 1, orphan.raw)
    again = unit_in_flight(fetcher, orphan.raw, "q") # fetched again, not yet held by a worker
    sweep

    assert_equal [orphan.raw], inflight
    assert_equal [again.key], registered
  end

  # Recovery unregisters the keys of a process whose heartbeat lapsed; the
  # next heartbeat registers the ones its workers hold again.
  def test_beat_registers_held_keys_again
    @launcher.beat

    assert_equal 0, redis("EXISTS", @launcher.inflight_key), "nothing held: nothing registered"
    fetcher.instance_variable_get(:@free) << "#{@launcher.inflight_key}:f"
    fake_processor.work = ["q", "{}", 1, "#{@launcher.inflight_key}:w"]
    @launcher.beat

    assert_equal ["#{@launcher.inflight_key}:f", "#{@launcher.inflight_key}:w"], registered
  end

  def test_beats_sweep_once_a_minute
    seen = []
    swept = []
    # (Only the sweep's: a slow round trip, under load, asks for its warning too.)
    @launcher.define_singleton_method(:due?) { |s, n| n == :sweep && (seen << [s, n]) && seen.size == 1 }
    @launcher.define_singleton_method(:sweep_inflight) { |_c, registered| swept << registered }
    redis("SADD", @launcher.inflight_key, "k")
    2.times { @launcher.beat }

    assert_equal [[60, :sweep]] * 2, seen
    assert_equal [%w[k]], swept
  end

  # -- heartbeat lapses and housekeeping -------------------------------------------

  def test_a_lapsed_heartbeat_is_reported
    logs = capture_logs
    @launcher.beat
    @launcher.beat

    refute_includes logs.string, "heartbeat lapsed"
    redis("DEL", @launcher.proc_key) # the key expired while we were stalled
    @launcher.beat

    assert_includes logs.string, "WARN: heartbeat lapsed (more than 60s without one); jobs running here may have been recovered"
  end

  def test_a_lapsed_heartbeat_is_an_event
    events = capture_events
    @launcher.beat
    @launcher.beat

    assert_empty events
    redis("DEL", @launcher.proc_key)
    @launcher.beat

    assert_equal [["heartbeat.lapsed", {}]], events
  end

  def test_the_first_beat_is_not_a_lapse
    logs = capture_logs
    @launcher.beat

    refute_includes logs.string, "heartbeat lapsed"
  end

  def test_heartbeats_use_the_housekeeping_pool
    used = []
    pool = config.housekeeping_pool
    real = pool.method(:with)
    pool.define_singleton_method(:with) { |&b| used << :housekeeping && real.call(&b) }
    @launcher.beat

    assert_equal [:housekeeping], used
  ensure
    pool.singleton_class.remove_method(:with)
  end

  def test_leader_chores_only_run_on_the_leader
    seen = []
    @launcher.define_singleton_method(:every) { |s, n, &_b| seen << n }
    @launcher.leader.define_singleton_method(:leader?) { false }
    @launcher.send(:leader_chores)

    assert_empty seen
  end
end

# Tests that start real threads (and so take a second or more); they only
# guard #run and #stop so mutation testing doesn't run them for every
# other Launcher method.
class LauncherLifecycleTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Launcher#run"
  cover "Robin::Launcher#stop"

  def setup
    super
    config.concurrency = 1
    config.timeout = 1
    config.tag = "web"
    config.labels = %w[blue]
    @errors = capture_errors
    @launcher = Robin::Launcher.new(config)
    @launcher.define_singleton_method(:rss_kb) { 2048 }
  end

  def teardown
    Robin::Leader.unregister(config)
    super
  end

  def test_run_and_stop_lifecycle
    config.heartbeat_interval = 0.05
    config.poll_interval = 0.05
    orphan = config.key("inflight", "ghost:1:aa")
    redis("RPUSH", orphan, JSON.generate({"class" => "X", "args" => [], "jid" => "o", "queue" => "parked"}))
    redis("SADD", config.key("inflights"), orphan)
    order = []
    config.on(:startup) { order << [:startup, redis("SMEMBERS", config.key("processes")), redis("LLEN", config.key("queue", "parked"))] }
    config.on(:shutdown) { order << :shutdown1 }
    config.on(:shutdown) { order << :shutdown2 }
    beats = 0
    @launcher.every_beat { beats += 1 }
    before = Robin.now_ms

    assert_same @launcher, @launcher.run
    assert_operator @launcher.started_at, :>=, before
    assert_same @launcher.leader, Robin::Leader.instance_variable_get(:@leaders)[config.object_id]
    assert_equal [[:startup, [], 1]], order
    assert_equal Robin.epoch_seconds(@launcher.started_at), @launcher.process_info["started_at"]
    assert_predicate @launcher.instance_variable_get(:@scheduler).instance_variable_get(:@thread), :alive?
    assert_equal 1, beats
    assert_equal 1, redis("LLEN", config.key("queue", "parked"))
    assert_includes redis("SMEMBERS", config.key("inflights")), @launcher.inflight_key
    eventually { beats >= 3 }

    assert_equal "robin.heartbeat", @launcher.instance_variable_get(:@heartbeat).name
    assert(@launcher.managers.first.processors.all?(&:alive?))
  ensure
    @launcher.stop
  end

  def test_systemd_hears_when_the_server_is_ready_and_stopping
    config.heartbeat_interval = 0.05
    states = []
    stub_method(Robin::Systemd, :notify, ->(state) { states << state }) do
      @launcher.run

      assert_equal ["READY=1"], states
      @launcher.stop
    end

    assert_equal ["READY=1", "STOPPING=1"], states.uniq.reject { |s| s == "WATCHDOG=1" }
  end

  def test_embedded_servers_never_notify_systemd
    launcher = Robin::Launcher.new(config, embedded: true)
    stub_method(Robin::Systemd, :notify, ->(state) { flunk "notified #{state}" }) do
      launcher.run
      launcher.stop
    end
  end

  def test_run_freezes_the_capsules
    @launcher.run

    assert_predicate config.capsules, :frozen?
    assert_raises(FrozenError) { config.concurrency = 9 }
  ensure
    @launcher.stop
  end

  def test_run_warms_up_the_jit_before_starting_work_when_asked
    warmed = []
    config.jit_warmup = true
    stub_method(Robin::Warmup, :run, ->(c) { warmed << [c, Robin::Leader.leader?(c), c.capsules.frozen?] }) { @launcher.run }

    assert_equal [[config, false, true]], warmed, "after the capsules freeze, before the lease"
  ensure
    @launcher.stop
  end

  def test_run_skips_the_jit_warmup_unless_asked
    config.jit_warmup = false
    stub_method(Robin::Warmup, :run, ->(_c) { flunk "warmed up" }) { @launcher.run }
  ensure
    @launcher.stop
  end

  def test_run_and_stop_the_health_server
    config.health_port = 0
    config.health_bind = "127.0.0.1"
    @launcher.run
    port = @launcher.instance_variable_get(:@health).port

    assert_match(/\AHTTP\/1.1 200 OK\r\n.*"status":"ok"/m, http_get(port))
    @launcher.stop

    assert_raises(Errno::ECONNREFUSED) { http_get(port) }
  end

  def test_stop_lifecycle
    config.heartbeat_interval = 0.05
    order = []
    config.on(:shutdown) { order << :shutdown1 }
    config.on(:shutdown) { order << :shutdown2 }
    @launcher.run
    unit_in_flight(@launcher.managers.first.fetcher, JSON.generate({"class" => "X", "args" => [], "jid" => "mine", "queue" => "parked"}), "parked")
    redis("RPUSH", config.key("queue", "parked"), "older")
    logs = capture_logs
    @launcher.stop

    assert_true @launcher.stopping?
    assert_equal %i[shutdown2 shutdown1], order
    assert_includes logs.string, "INFO: pushed 1 unfinished job(s) back to their queues\n"
    assert logs.string.end_with?("INFO: bye!\n")
    assert_equal 2, redis("LLEN", config.key("queue", "parked"))
    assert_empty redis("SMEMBERS", config.key("processes"))
    assert_empty redis("SMEMBERS", config.key("inflights"))
    assert_equal 0, redis("EXISTS", @launcher.proc_key)
    assert_nil Robin::Leader.current(config)
    refute Robin::Leader.leader?(config)
    refute_predicate @launcher.instance_variable_get(:@heartbeat), :alive?
    refute(@launcher.managers.first.processors.any?(&:alive?))
  end

  def test_stop_waits_up_to_a_second_for_the_heartbeat
    config.heartbeat_interval = 0.01
    calls = 0
    release = Queue.new
    @launcher.define_singleton_method(:beat) do
      calls += 1
      release.pop(timeout: 3) if calls == 2
    end
    @launcher.managers.each do |m|
      m.define_singleton_method(:start) { nil }
      m.define_singleton_method(:stop) { |_deadline, _hard_deadline| nil }
    end
    @launcher.run
    sleep 0.01 until calls >= 2
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @launcher.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    release << true

    assert_in_delta 1.0, elapsed, 0.35
  end

  def test_run_attaches_periodic_jobs_when_configured
    attached = []
    config.heartbeat_interval = 60
    stub_method(Robin::Periodic, :attach, ->(l) { attached << l }) do
      launcher = Robin::Launcher.new(config)
      launcher.run.stop
      config.periodic { |_| nil }
      launcher = Robin::Launcher.new(config)
      launcher.run.stop

      assert_equal [launcher], attached
    end
  end

  def test_run_survives_failing_recovery_and_heartbeat
    config.heartbeat_interval = 60
    stub_method(Robin::Recovery, :run, ->(*) { raise "recovery failed" }) do
      @launcher.define_singleton_method(:beat) { raise "beat failed" }
      @launcher.run.stop
    end

    assert_equal [["recovery failed", "startup recovery"], ["beat failed", "heartbeat"]],
      @errors.map { |e, c| [e.message, c[:context]] }.first(2)
  end

  def test_heartbeat_thread_stops_beating_once_stopping
    config.heartbeat_interval = 0.02
    beats = []
    launcher = @launcher
    @launcher.define_singleton_method(:beat) { beats << launcher.stopping? }
    @launcher.run
    sleep 0.01 until beats.size >= 2
    @launcher.instance_variable_set(:@done, true)
    @launcher.instance_variable_get(:@heartbeat).join(1)

    refute_includes beats, true
  ensure
    @launcher.instance_variable_set(:@done, false)
    @launcher.stop
  end

  def test_heartbeat_thread_sleeps_between_beats
    config.heartbeat_interval = 0.05
    beats = 0
    @launcher.define_singleton_method(:beat) { beats += 1 }
    @launcher.run
    sleep 0.3

    assert_operator beats, :<, 15
    assert_operator beats, :>=, 3
  ensure
    @launcher.stop
  end

  def slow_chores(seconds)
    config.heartbeat_interval = 0.01
    started = Queue.new
    finished = []
    @launcher.define_singleton_method(:leader_chores) do
      started << true
      sleep seconds
      finished << true
    end
    @launcher.managers.each { |m| m.define_singleton_method(:stop) { |*| nil } }
    @launcher.run
    started.pop
    finished
  end

  def test_stop_waits_for_running_leader_chores
    finished = slow_chores(0.5)
    @launcher.stop

    assert_equal [true], finished
  end

  def test_stop_waits_at_most_a_second_for_stuck_chores
    finished = slow_chores(1.8)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @launcher.stop

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.5
    assert_empty finished
  end

  def test_stop_wakes_sleeping_housekeeping_threads
    config.heartbeat_interval = 30
    @launcher.run
    threads = %i[@heartbeat @chores].map { |ivar| @launcher.instance_variable_get(ivar) }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @launcher.stop

    refute(threads.any?(&:alive?))
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_startup_recovery_uses_the_housekeeping_pool
    pools = []
    stub_method(Robin::Recovery, :run, ->(_cfg, pool:) { pools << pool && 0 }) { @launcher.run }

    assert_equal [config.housekeeping_pool], pools
  ensure
    @launcher.stop
  end

  def test_housekeeping_runs_on_two_high_priority_threads
    config.heartbeat_interval = 0.01
    @launcher.leader.define_singleton_method(:leader?) { true }
    chores = 0
    @launcher.define_singleton_method(:leader_chores) { chores += 1 }
    @launcher.run
    eventually { chores >= 2 }
    threads = %i[@heartbeat @chores].map { |ivar| @launcher.instance_variable_get(ivar) }

    assert_equal %w[robin.heartbeat robin.leader], threads.map(&:name)
    assert_equal [1, 1], threads.map(&:priority)
    @launcher.stop

    refute(threads.any?(&:alive?))
  ensure
    @launcher.stop
  end

  def test_every_fetcher_shares_the_launchers_acker_queue
    config.capsule("solo") { |c| c.queues = ["serial"] }
    launcher = Robin::Launcher.new(config)
    queues = launcher.managers.map { |m| m.fetcher.acker }

    assert_equal 2, queues.size
    assert_same launcher.instance_variable_get(:@acks), queues.first
    assert_same queues.first, queues.last
  end

  def test_acknowledgements_go_out_on_a_high_priority_thread_until_stop
    @launcher.run
    thread = @launcher.instance_variable_get(:@acker)

    assert_equal "robin.acks", thread.name
    assert_equal 1, thread.priority
    @launcher.stop

    refute_predicate thread, :alive?
  ensure
    @launcher.stop
  end

  def test_a_running_launcher_sends_the_acknowledgements_left_waiting
    log = []
    @launcher.run
    @launcher.instance_variable_get(:@acks) << FakeAcking.new(:a, log)

    eventually { log == [:a] }
  ensure
    @launcher.stop
  end

  def test_stop_waits_for_acknowledgements_being_sent
    log = []
    sending = Thread::Queue.new
    fetcher = FakeAcking.new(:a, log)
    fetcher.define_singleton_method(:send_acks) do
      sending << true
      sleep 0.5
      log << :a
    end
    @launcher.run
    @launcher.instance_variable_get(:@acks) << fetcher
    sending.pop
    @launcher.stop

    assert_equal [:a], log
  ensure
    @launcher.stop
  end

  def test_stop_gives_up_on_a_stuck_acknowledgement_after_a_second
    stuck = Thread::Queue.new
    fetcher = FakeAcking.new(:a, [])
    fetcher.define_singleton_method(:send_acks) { stuck.pop }
    @launcher.run
    @launcher.instance_variable_get(:@acks) << fetcher
    eventually { stuck.num_waiting == 1 }
    stopper = Thread.new { @launcher.stop }

    # About 1.3 s: the second it gives the acknowledgements, and the rest.
    assert stopper.join(1.9), "stop waited too long for the stuck acknowledgement"
  ensure
    stuck << true
    @launcher.stop
  end

  # A fetcher stand-in recording its #send_acks calls in +log+.
  FakeAcking = Struct.new(:name, :log, :error) do
    def send_acks
      log << name
      raise error if error
    end
  end

  # Runs the launcher's acknowledgement loop over +queued+ (fetchers, and
  # nil to stop) on another thread, recording its sleeps in +log+; returns
  # the log once the loop has stopped.
  def ack_loop(queued, log = [])
    acks = @launcher.instance_variable_get(:@acks)
    queued.each { |f| acks << f }
    stub_method(@launcher, :sleep, ->(seconds) { log << [:sleep, seconds] }) do
      thread = Thread.new { @launcher.send(:send_acks) }

      assert thread.join(1), "the loop didn't stop"
    end
    log
  end

  def test_the_acker_waits_then_sends_for_every_fetcher_queued_meanwhile
    log = []
    a = FakeAcking.new(:a, log)
    b = FakeAcking.new(:b, log)

    assert_equal [[:sleep, Robin::Fetcher::ACK_WAIT], :a, :b], ack_loop([a, b, nil], log)
    assert_empty @errors
  end

  def test_the_acker_stops_at_a_nil_it_waits_for
    log = []
    acks = @launcher.instance_variable_get(:@acks)
    a = FakeAcking.new(:a, log)
    a.define_singleton_method(:send_acks) { (log << :a) && acks << nil }

    assert_equal [[:sleep, Robin::Fetcher::ACK_WAIT], :a], ack_loop([a], log)
  end

  def test_the_acker_stops_at_once_on_a_nil
    assert_empty ack_loop([nil])
  end

  def test_the_acker_reports_only_the_first_of_a_run_of_failures
    log = []
    bad = FakeAcking.new(:bad, log, RuntimeError.new("down"))
    good = FakeAcking.new(:good, log)
    ack_loop([bad, bad, good, bad, nil], log)

    assert_equal [[:sleep, Robin::Fetcher::ACK_WAIT], :bad, :bad, :good, :bad], log
    assert_equal [["down", {context: "acknowledging jobs"}]] * 2, @errors.map { |e, ctx| [e.message, ctx] }
  end

  def test_heartbeat_thread_survives_and_reports_failures
    config.heartbeat_interval = 0.01
    calls = 0
    @launcher.define_singleton_method(:beat) do
      calls += 1
      raise "beat #{calls}" if calls == 2
    end
    @launcher.run
    sleep 0.01 until calls >= 4

    assert_equal [["beat 2", {context: "heartbeat"}]], @errors.map { |e, c| [e.message, c] }
  ensure
    @launcher.stop
  end
end
