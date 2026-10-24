# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class ConfigTest < Minitest::Test
  cover "Robin::Config*"
  cover "Robin::Capsule*"

  ENV_KEYS = %w[APP_ENV RACK_ENV RAILS_ENV].freeze

  def setup
    Robin.instance_variable_set(:@server, nil) # whatever a test before left
    @saved_env = ENV.to_h.slice(*ENV_KEYS)
    ENV_KEYS.each { |k| ENV.delete(k) }
    @config = Robin::Config.new
    @log = StringIO.new
    @config.logger = Logger.new(@log)
  end

  def teardown
    ENV_KEYS.each { |k| ENV.delete(k) }
    @saved_env.each { |k, v| ENV[k] = v }
    Robin.instance_variable_set(:@server, nil)
  end

  def test_batch_status_class_defaults_to_robins
    assert_same Robin::Batch::Status, @config.batch_status_class
    kind = Class.new(Robin::Batch::Status)
    @config.batch_status_class = kind

    assert_same kind, @config.batch_status_class
  end

  # -- capsules -------------------------------------------------------------

  def test_capsule_defaults
    cap = Robin::Capsule.new("x", @config)

    assert_equal "x", cap.name
    assert_same @config, cap.config
    assert_equal 5, cap.concurrency
    assert_equal ["default"], cap.queues
    assert_equal({"default" => 0}, cap.weights)
    assert_predicate cap, :strict?
  end

  def test_strict_queues
    cap = Robin::Capsule.new("x", @config)
    cap.queues = [" critical ", :default, "low,0", ["bulk", "0"]]

    assert_equal %w[critical default low bulk], cap.queues
    assert_predicate cap, :strict?
    assert_equal %w[critical default low bulk], cap.queue_order
    cap.queues = "solo"

    assert_equal ["solo"], cap.queues
    cap.queues = [[:sym, 0], ["arr", 2]]

    assert_equal({"sym" => 0, "arr" => 2}, cap.weights)
    assert_raises(ArgumentError) { cap.queues = ["a,1,2"] }
    assert_raises(ArgumentError) { cap.queues = [["a", "x"]] }
  end

  def test_weighted_queues
    cap = Robin::Capsule.new("x", @config)
    cap.queues = ["a,10", ["b", 1], "c"]

    refute_predicate cap, :strict?
    assert_equal({"a" => 10, "b" => 1, "c" => 0}, cap.weights)
    # Unweighted queues still get one slot.
    assert_equal({"a" => 10, "b" => 1, "c" => 1}, cap.instance_variable_get(:@expanded).tally)
    orders = Array.new(600) { cap.queue_order }

    assert(orders.all? { |o| o.sort == %w[a b c] })
    firsts = orders.map(&:first).tally

    # a should come first ~10/12 of the time; b and c ~1/12 each.
    assert_operator firsts.fetch("a"), :>, 400
    assert_operator firsts.fetch("b"), :>, 10
    assert_operator firsts.fetch("c"), :>, 10
    assert_raises(ArgumentError) { cap.queues = ["a,x"] }
  end

  # -- defaults -------------------------------------------------------------

  def test_defaults
    c = Robin::Config.new

    assert_equal 25, c.timeout
    assert_equal 5, c.poll_interval
    assert_equal 20, c.max_retries
    assert_equal 10_000, c.dead_max_jobs
    assert_equal 180 * 86_400, c.dead_timeout
    assert_equal :raise, c.strict_args
    assert_equal "robin:", c.key_prefix
    assert_nil c.tag
    assert_empty c.labels
    assert_equal "development", c.environment
    assert_equal 5, c.heartbeat_interval
    assert_equal 2, c.fetch_timeout
    assert_equal 10, c.fetch_batch
    assert_equal 60, c.process_ttl
    assert_equal 3, c.max_recoveries
  end

  def test_fetch_batch
    c = Robin::Config.new
    c.fetch_batch = "25"

    assert_equal 25, c.fetch_batch
    c.fetch_batch = 1

    assert_equal 1, c.fetch_batch
    error = assert_raises(ArgumentError) { c.fetch_batch = 0 }

    assert_equal "fetch_batch must be at least 1, not 0", error.message
    assert_raises(ArgumentError) { c.fetch_batch = "many" }
    assert_equal 1, c.fetch_batch
  end

  def test_more_defaults
    c = Robin::Config.new

    assert_equal 30, c.backtrace_lines
    assert_nil c.encryption_keys
    assert_equal 20, c.max_rate_limit_retries
    assert_nil c.memory_limit_mb
    assert_nil c.statsd
    assert_nil c.push_deferrer
    assert_equal 90, c.metrics_retention_days
    assert_false c.reliable_push
    assert c.shutdown_requeue
    assert_nil c.job_wrapper
    assert_nil c.jid_index
    assert_nil c.backtrace_cleaner
    assert_nil c.health_port
    assert_equal "0.0.0.0", c.health_bind
  end

  def test_connections_are_named_robin
    c = Robin::Config.new
    c.redis = {url: REDIS_URL}

    assert_equal "robin", c.redis { |conn| conn.call("CLIENT", "GETNAME") }
    assert_equal "robin", c.housekeeping_pool.with { |conn| conn.call("CLIENT", "GETNAME") }
    c.redis = {url: REDIS_URL, name: "billing"}

    assert_equal "billing", c.redis { |conn| conn.call("CLIENT", "GETNAME") }
    assert_equal "billing", c.housekeeping_pool.with { |conn| conn.call("CLIENT", "GETNAME") }
  ensure
    c.redis_pool.shutdown
    c.housekeeping_pool.shutdown
  end

  def test_the_current_capsule_is_the_threads
    capsule = Robin::Config.new.default_capsule
    seen = Thread.new do
      Thread.current[:robin_capsule] = capsule
      Robin::Capsule.current
    end.value

    assert_same capsule, seen
    assert_nil Robin::Capsule.current
  end

  def test_freeze_capsules
    c = Robin::Config.new
    c.capsule("serial") { |cap| cap.queues = %w[ledger] }
    c.freeze_capsules!

    error = assert_raises(FrozenError) { c.concurrency = 3 }

    assert_same c.default_capsule, error.receiver
    assert_equal "can't modify frozen Robin::Capsule: #{c.default_capsule.inspect}", error.message
    c.default_capsule.resized(8) # a running capsule's worker count still changes

    assert_equal 8, c.concurrency
    assert_equal 8, c.total_concurrency - c.capsules["serial"].concurrency
    assert_raises(FrozenError) { c.queues = %w[other] }
    assert_raises(FrozenError) { c.capsule("late") { nil } }
    assert_raises(FrozenError) { c.capsules["serial"].weights["more"] = 1 }
    assert_equal %w[ledger], c.capsule("serial").queue_order
    assert_equal %w[default], c.queues
    c.timeout = 9 # other settings can still change

    assert_equal 9, c.timeout
  end

  def test_frozen_weighted_capsules_still_shuffle
    c = Robin::Config.new
    c.queues = ["a,2", "b,1"]
    c.freeze_capsules!

    assert_equal %w[a b], c.default_capsule.queue_order.sort
  end

  def test_health_port
    ENV["ROBIN_HEALTH_PORT"] = "7433"

    assert_equal 7433, Robin::Config.new.health_port
    c = Robin::Config.new
    c.health_port = "80"

    assert_equal 80, c.health_port
    c.health_port = nil

    assert_nil c.health_port
    assert_raises(ArgumentError) { c.health_port = "x" }
  ensure
    ENV.delete("ROBIN_HEALTH_PORT")
  end

  def test_jid_index
    c = Robin::Config.new
    c.jid_index = true

    assert_equal 604_800, c.jid_index
    assert_equal 604_800, Robin::Config::JID_INDEX_TTL
    c.jid_index = "60"

    assert_equal 60, c.jid_index
    c.jid_index = false

    assert_false c.jid_index
    c.jid_index = nil

    assert_nil c.jid_index
    assert_nil c.backtrace_cleaner
    assert_raises(TypeError) { c.jid_index = :yes }
  end

  def test_default_handlers_and_events
    c = Robin::Config.new

    assert_equal [Robin::Config::DEFAULT_ERROR_HANDLER], c.error_handlers
    assert_empty c.death_handlers
    assert_empty c.recovery_handlers
    assert_equal [], c.event_handlers
    assert_true c.leader_candidate
    assert_true c.gvl_monitoring
    assert_false c.idle_gc
    assert_same RUBY_ENGINE != "ruby", c.jit_warmup
    assert_same Robin::Config::JIT_WARMUP, c.jit_warmup
    assert_nil c.retry_backoff
    assert_empty c.periodic_blocks
    assert_equal Robin::Config::LIFECYCLE_EVENTS.to_h { |e| [e, []] }, c.lifecycle
    assert_equal %i[startup quiet shutdown leader follower heartbeat exit fork], Robin::Config::LIFECYCLE_EVENTS
    assert_equal ["default"], c.capsules.keys
    assert_empty c.redis_options
  end

  def test_idle_gc_takes_a_number_of_jobs
    c = Robin::Config.new
    c.idle_gc = true

    assert_equal 1, c.idle_gc
    c.idle_gc = 500

    assert_equal 500, c.idle_gc
    c.idle_gc = nil

    assert_false c.idle_gc
    [0, -1, 1.5, "1"].each do |bad|
      error = assert_raises(ArgumentError) { c.idle_gc = bad }

      assert_equal "idle_gc must be true, false or a number of jobs (at least 1), not #{bad.inspect}", error.message
    end
    assert_false c.idle_gc
  end

  def test_environment_detection
    assert_equal "development", Robin::Config.new.environment
    ENV["RACK_ENV"] = "rack"

    assert_equal "rack", Robin::Config.new.environment
    ENV["RAILS_ENV"] = "rails" # the Rails integration takes Rails.env instead

    assert_equal "rack", Robin::Config.new.environment
    ENV["APP_ENV"] = "app"

    assert_equal "app", Robin::Config.new.environment
  end

  def test_default_capsule_and_chains_belong_to_the_config
    cap = @config.default_capsule

    assert_equal "default", cap.name
    assert_same @config, cap.config
    aware = Class.new do
      include Robin::Middleware::ConfigAware

      def call(*) = yield
    end
    @config.client_middleware.add(aware)
    @config.server_middleware.add(aware)

    assert_same @config, @config.client_middleware.entries.last.build.config
    assert_same @config, @config.server_middleware.entries.last.build.config
  end

  def test_default_middleware
    assert_equal [Robin::Unique::ClientMiddleware, Robin::Debounce::ClientMiddleware,
      Robin::Batch::ClientMiddleware, Robin::Encryption::ClientMiddleware], @config.client_middleware.map(&:klass)
    assert_equal [Robin::Encryption::ServerMiddleware, Robin::Expiry::ServerMiddleware,
      Robin::Limiter::ServerMiddleware, Robin::Unique::ServerMiddleware, Robin::Debounce::ServerMiddleware,
      Robin::Batch::ServerMiddleware, Robin::Profiler::ServerMiddleware], @config.server_middleware.map(&:klass)
  end

  def test_middleware_accessors_yield_the_chain
    yielded = nil
    chain = @config.client_middleware { |c| yielded = c }

    assert_same chain, yielded
    assert_instance_of Robin::Middleware::Chain, chain
    server = @config.server_middleware { |c| yielded = c }

    assert_same server, yielded
    refute_same chain, server
    assert_same server, @config.server_middleware
  end

  # -- capsules on the config -----------------------------------------------

  def test_default_capsule_shortcuts
    cap = @config.default_capsule

    assert_same @config.capsules["default"], cap
    @config.concurrency = 7
    @config.queues = %w[a b]

    assert_equal 7, cap.concurrency
    assert_equal 7, @config.concurrency
    assert_equal %w[a b], cap.queues
    assert_equal %w[a b], @config.queues
  end

  def test_capsule
    yielded = nil
    cap = @config.capsule(:serial) do |c|
      yielded = c
      c.concurrency = 1
    end

    assert_same cap, yielded
    assert_equal "serial", cap.name
    assert_same @config, cap.config
    assert_same cap, @config.capsule("serial")
    assert_same cap, @config.capsules["serial"]
    assert_equal 6, @config.total_concurrency
  end

  # -- redis ----------------------------------------------------------------

  def test_redis_pool_for_clients
    @config.concurrency = 3
    @config.redis = {"url" => "redis://example.test:1/2", "connect_timeout" => 0.5, "pool_size" => 4}
    @config.redis = @config.redis_options.except(:pool_size)
    pool = @config.redis_pool

    assert_equal({url: "redis://example.test:1/2", connect_timeout: 0.5}, @config.redis_options)
    assert_same pool, @config.redis_pool
    assert_equal 10, pool.size
    assert_in_delta 3.0, pool.timeout
    conn = pool.with { |c| c }

    assert_equal "example.test", conn.options[:host]
    assert_in_delta 0.5, conn.options[:connect_timeout]
  end

  def test_redis_pool_for_servers_and_explicit_sizes
    Robin.server!
    @config.concurrency = 3

    assert_equal 8, @config.redis_pool.size
    @config.redis = {url: "redis://h", pool_size: 2, pool_timeout: 0.25}
    pool = @config.redis_pool

    assert_equal({url: "redis://h", pool_size: 2, pool_timeout: 0.25}, @config.redis_options)
    assert_equal 2, pool.size
    assert_in_delta 0.25, pool.timeout
    assert_nil pool.idle_timeout
    assert_equal "h", pool.with { |c| c.options[:host] }
  end

  def test_fit_redis_pool_grows_a_pool_robin_sized
    Robin.server!
    @config.concurrency = 3
    pool = @config.redis_pool

    assert_equal 8, pool.size
    assert @config.fit_redis_pool(10)
    assert_same pool, @config.redis_pool
    assert_equal 15, pool.size
    assert @config.fit_redis_pool(4)
    assert_equal 15, pool.size, "it never shrinks"
  end

  def test_fit_redis_pool_sizes_a_clients_pool_like_robin_does
    @config.concurrency = 3

    assert @config.fit_redis_pool(8)
    assert_equal 10, @config.redis_pool.size
    refute @config.fit_redis_pool(9)
    assert_equal 10, @config.redis_pool.size
  end

  def test_fit_redis_pool_leaves_a_set_size_alone
    Robin.server!
    @config.redis = {url: "redis://h", pool_size: 6}

    assert @config.fit_redis_pool(4)
    refute @config.fit_redis_pool(5)
    assert_equal 6, @config.redis_pool.size
  end

  def test_idle_timeout_goes_to_the_main_pool
    @config.redis = {url: REDIS_URL, idle_timeout: 30}

    assert_equal 30, @config.redis_pool.idle_timeout
    assert_equal "PONG", @config.redis { |c| c.call("PING") }
    assert_nil @config.housekeeping_pool.idle_timeout
    assert_equal "PONG", @config.housekeeping_pool.with { |c| c.call("PING") }
  ensure
    @config.redis_pool.shutdown
    @config.housekeeping_pool.shutdown
  end

  def test_setting_redis_shuts_down_the_old_pool
    shut = []
    fake = Object.new
    fake.define_singleton_method(:shutdown) { shut << :down }
    @config.redis_pool = fake
    @config.redis = {url: "redis://h"}

    assert_equal [:down], shut
    refute_same fake, @config.redis_pool
    @config.redis = {url: "redis://h2"}
  end

  def test_redis_checks_out_a_connection
    @config.redis = {url: REDIS_URL}

    assert_equal "PONG", @config.redis { |c| c.call("PING") }
  ensure
    @config.redis_pool.shutdown
  end

  def test_key
    assert_equal "robin:a:b:1", @config.key("a", "b", 1)
    @config.key_prefix = "x/"

    assert_equal "x/q", @config.key("q")
    assert_equal "x/", @config.key
    @config.internal_key_prefix = "own:"

    assert_equal "x/queue:q", @config.key("queue", "q")
    assert_equal "own:q", @config.key("q")
  end

  def test_internal_key_prefix_defaults_to_key_prefix
    assert_equal "robin:", @config.internal_key_prefix
    @config.key_prefix = "x/"

    assert_equal "x/", @config.internal_key_prefix
    @config.internal_key_prefix = "own:"

    assert_equal "own:", @config.internal_key_prefix
    assert_equal "x/", @config.key_prefix
  end

  def test_shared_keys_use_key_prefix_and_others_the_internal_one
    @config.key_prefix = ""
    @config.internal_key_prefix = "robin:"

    assert_equal %w[queue queues schedule retry dead paused processes stat], Robin::Config::SHARED_KEYS
    assert_predicate Robin::Config::SHARED_KEYS, :frozen?
    Robin::Config::SHARED_KEYS.each { |name| assert_equal "#{name}:a", @config.key(name, "a") }
    assert_equal "robin:batch:b1", @config.key("batch", "b1")
    assert_equal "robin:proc:p", @config.key("proc", "p")
    assert_equal "robin:", @config.key
  end

  def test_process_key_is_the_identity_under_key_prefix
    @config.internal_key_prefix = "own:"

    assert_equal "robin:host:1:abc", @config.process_key("host:1:abc")
    @config.key_prefix = ""

    assert_equal "host:1:abc", @config.process_key("host:1:abc")
  end

  def test_default_logger
    out, = capture_io do
      fresh = Robin::Config.new
      fresh.logger.info("hello")
      fresh.logger.debug("hidden")

      assert_same fresh.logger, fresh.logger
    end

    assert_match(/INFO: hello/, out)
    refute_match(/hidden/, out)
    logger = Robin::Config.new.logger

    assert_equal Logger::INFO, logger.level
    assert_instance_of Robin::JobLogger::Formatter, logger.formatter
    assert_same logger, Robin::Config.new.tap { |c| c.logger = logger }.logger
  end

  # -- events and errors ----------------------------------------------------

  def test_lifecycle_events
    calls = []
    @config.on(:startup) { calls << 1 }
    @config.on(:startup) { raise "boom" }
    @config.on(:startup) { calls << 3 }
    handled = []
    @config.error_handlers.replace([->(ex, ctx, cfg) { handled << [ex.message, ctx, cfg] }])

    @config.fire_event(:startup)

    assert_equal [1, 3], calls
    assert_equal [["boom", {context: "lifecycle event startup"}, @config]], handled
    @config.fire_event(:startup, reverse: true)

    assert_equal [1, 3, 3, 1], calls
    @config.fire_event(:quiet)
    error = assert_raises(ArgumentError) { @config.on(:nope) { nil } }
    assert_equal "unknown event :nope", error.message
    assert_raises(KeyError) { @config.fire_event(:nope) }
  end

  def test_periodic_blocks
    block = proc {}
    @config.periodic(&block)

    assert_equal [block], @config.periodic_blocks
  end

  def test_handle_exception
    seen = []
    @config.error_handlers << ->(_ex, _ctx, _cfg) { raise "handler broke" }
    @config.error_handlers << ->(ex, ctx, cfg) { seen << [ex, ctx, cfg] }
    error = RuntimeError.new("bad")
    @config.handle_exception(error)
    @config.handle_exception(error, {job: 1})

    assert_equal [[error, {}, @config], [error, {job: 1}, @config]], seen
    assert_includes @log.string, "ERROR -- : !!! error handler raised: RuntimeError: handler broke\n"
  end

  def test_default_error_handler
    error = RuntimeError.new("kaboom")
    error.set_backtrace(Array.new(25) { |i| "line#{i}" })
    Robin::Config::DEFAULT_ERROR_HANDLER.call(error, {"job" => 1}, @config)

    assert_equal 1, @log.string.scan(" WARN ").size, "one entry"
    assert_match(/WARN -- : RuntimeError: kaboom\n\{"job":1\}\nline0\n.*line19\n\z/m, @log.string)
    refute_includes @log.string, "line20"
  end

  def test_default_error_handler_without_context_or_backtrace
    Robin::Config::DEFAULT_ERROR_HANDLER.call(RuntimeError.new("plain"), {}, @config)

    assert_equal 1, @log.string.lines.size
    assert_match(/WARN -- : RuntimeError: plain\n\z/, @log.string)
  end

  def test_inspect
    @config.capsule("x").concurrency = 2

    assert_equal '#<Robin::Config concurrency=7 capsules=["default", "x"] prefix="robin:">', @config.inspect
  end

  def test_duplicate_queues_are_rejected
    error = assert_raises(ArgumentError) { @config.queues = ["a,2", "b", "a"] }

    assert_equal 'queue "a" is listed twice; give it one weight instead', error.message
    error = assert_raises(ArgumentError) { @config.queues = [" a ", "a"] }

    assert_match(/queue "a" is listed twice/, error.message)
  end

  def test_fire_event_can_reraise
    errors = []
    @config.error_handlers.replace([->(ex, ctx, _) { errors << [ex.message, ctx] }])
    ran = []
    @config.on(:startup) { raise "first" }
    @config.on(:startup) { ran << :second }
    @config.fire_event(:startup)

    assert_equal [:second], ran
    error = assert_raises(RuntimeError) { @config.fire_event(:startup, reraise: true) }

    assert_equal "first", error.message
    assert_equal [:second], ran, "later callbacks don't run once one has raised"
    assert_equal [["first", {context: "lifecycle event startup"}]] * 2, errors
  end

  def test_housekeeping_pool_is_small_and_separate
    @config.redis = {url: REDIS_URL, pool_size: 50, pool_timeout: 9}
    pool = @config.housekeeping_pool

    assert_equal 2, pool.size
    assert_in_delta 3.0, pool.timeout
    refute_same @config.redis_pool, pool
    assert_same pool, @config.housekeeping_pool
    assert_equal "PONG", pool.with { |c| c.call("PING") }
    expected = Robin::Redis::Connection.parse_url(REDIS_URL)

    assert_equal expected, pool.with { |c| c.options.slice(*expected.keys) }
    conn = pool.with { |c| c }
    @config.redis = {url: REDIS_URL}

    refute_same pool, @config.housekeeping_pool
    assert_nil conn.instance_variable_get(:@sock), "the old housekeeping pool is shut down"
  ensure
    @config.housekeeping_pool.shutdown
    @config.redis_pool.shutdown
  end
end
