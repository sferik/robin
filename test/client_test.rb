# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"
require "date"
require "stringio"

module ClientTestJobs
  class Opts
    include Robin::Job

    robin_options queue: "opts", retry: 2, tags: ["t"]
  end

  class Bare
    def self.name = "ClientTestJobs::Bare"
  end

  class Unique
    include Robin::Job

    robin_options unique_for: 60
  end

  class Debounced
    include Robin::Job

    robin_options debounce: 30
  end
end

class ClientTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Client*"

  Client = Robin::Client

  def queue_items(queue = "default")
    redis("LRANGE", config.key("queue", queue), 0, -1).reverse.map { |raw| JSON.parse(raw) }
  end

  def scheduled
    redis("ZRANGE", config.key("schedule"), 0, -1, "WITHSCORES").each_slice(2).map { |raw, score| [JSON.parse(raw), Float(score)] }
  end

  def with_interceptor(callable)
    previous = Client.interceptor
    Client.interceptor = callable
    yield
  ensure
    Client.interceptor = previous
  end

  def test_rewriters_rewrite_pushed_jobs_in_order
    previous = Client.rewriters.dup # e.g. the Rails integration's, in one process
    seen = []
    Client.rewriters << ->(item) { seen << item.keys && item.merge("args" => item["args"] + [1]) }
    Client.rewriters << ->(item) { item.merge("queue" => "rewritten#{item["args"].size}") }
    Client.new.push(:class => "T", "args" => [0])
    Client.new.push_bulk("class" => "T", "args" => [[5]])

    assert_equal [%w[class args]], seen
    assert_equal [[0, 1]], queue_items("rewritten2").map { |i| i["args"] }
    assert_equal [[5]], queue_items.map { |i| i["args"] }
  ensure
    Client.rewriters.replace(previous)
  end

  def test_interceptor_that_handles_the_push_skips_redis
    seen = []
    with_interceptor(->(payloads) { seen.concat(payloads) }) do
      jid = Client.push("class" => "Job", "args" => [1])

      assert_equal [jid], seen.map { |p| p.fetch("jid") }
    end

    assert_empty queue_items
  end

  def test_batch_jobs_are_never_deferred
    deferred = []
    config.push_deferrer = ->(payloads, &_deliver) { deferred.concat(payloads) }
    Client.push("class" => "Job", "args" => [1], "bid" => "b1")

    assert_empty deferred
    assert_equal [[1]], queue_items.map { |item| item.fetch("args") }
    Client.push("class" => "Job", "args" => [2])

    assert_equal [[2]], deferred.map { |p| p.fetch("args") }
    assert_equal 1, queue_items.size
  end

  def test_without_an_interceptor_pushes_go_to_redis
    with_interceptor(nil) { Client.push("class" => "Job", "args" => [3]) }

    assert_equal [[3]], queue_items.map { |item| item.fetch("args") }
  end

  # Without the date library, Time doesn't respond to #to_time.
  BareTime = Class.new(Time) { undef_method :to_time if method_defined?(:to_time) }

  def test_timestamp_ms_handles_time_without_to_time
    time = BareTime.at(1_800_000_000, 250, :millisecond)

    refute_respond_to time, :to_time
    assert_equal 1_800_000_000_250, Client.timestamp_ms(time, 0)
  end

  def test_explicit_nil_at_pushes_immediately
    Client.push("class" => "Job", "args" => [4], "at" => nil)

    assert_equal [[4]], queue_items.map { |item| item.fetch("args") }
  end

  def test_interceptor_that_declines_falls_through_to_redis
    seen = []
    with_interceptor(->(payloads) { seen.concat(payloads) && false }) do
      Client.push("class" => "Job", "args" => [2])
    end

    assert_equal 1, seen.size
    assert_equal [[2]], queue_items.map { |item| item.fetch("args") }
  end

  def with_now(ms)
    original = Robin.method(:now_ms)
    Robin.define_singleton_method(:now_ms) { ms }
    yield
  ensure
    Robin.define_singleton_method(:now_ms, original)
  end

  def halting_middleware(&decide)
    Class.new do
      define_method(:call) { |_klass, payload, _queue, _redis, &blk| decide.call(payload) ? blk.call : nil }
    end
  end

  # -- timestamps -----------------------------------------------------------

  def test_timestamp_ms_returns_integers
    [Time.at(1.0005), 0.0015, 1_000_000_000.0005, 100_000_000_000.5, 3.0004, Date.new(2030, 1, 2)].each do |value|
      assert_kind_of Integer, Client.timestamp_ms(value, 7), value.inspect
    end
    assert_kind_of Integer, Client.timestamp_ms(Struct.new(:to_f).new(0.0015), 7)
    assert_equal 100_000_000_000, Client.timestamp_ms(100_000_000_000.5, 7)
  end

  def test_timestamp_ms
    now = 5_000

    assert_equal 1_500, Client.timestamp_ms(Time.at(1.5), now)
    assert_equal 7_500, Client.timestamp_ms(2.5, now)
    assert_equal 5_000 + 1_000_000_000_000, Client.timestamp_ms(1_000_000_000, now)
    assert_equal 1_000_000_001_000, Client.timestamp_ms(1_000_000_001, now)
    assert_equal 100_000_000_000_000, Client.timestamp_ms(100_000_000_000, now)
    assert_equal 100_000_000_001, Client.timestamp_ms(100_000_000_001, now)
    assert_equal 1_700_000_000_500, Client.timestamp_ms(1_700_000_000.5, now)
  end

  def test_timestamp_ms_for_other_objects
    now = 1_000
    date = Date.new(2030, 1, 2)

    assert_equal (date.to_time.to_r * 1000).to_i, Client.timestamp_ms(date, now)
    duration = Struct.new(:secs) do
      def to_f = secs

      def to_time = raise("durations are relative")

      def parts = {seconds: secs}
    end

    assert_equal 4_000, Client.timestamp_ms(duration.new(3), now)
    plain = Struct.new(:to_f)

    assert_equal 1_250, Client.timestamp_ms(plain.new(0.25), now)
    assert_in_delta Robin.now_ms + 1_000, Client.timestamp_ms(1), 1_000
    error = assert_raises(Client::ArgumentError) { Client.timestamp_ms(nil) }
    assert_equal "a time is required, not nil", error.message
  end

  # -- construction ---------------------------------------------------------

  def test_construction
    client = Client.new

    assert_same Robin.config, client.config
    assert_same Robin.config.redis_pool, client.redis_pool
    pool = Robin::Redis::Pool.new { nil }

    assert_same pool, Client.new(pool: pool).redis_pool
    other = Robin::Config.new

    assert_same other, Client.new(config: other).config
  end

  # -- shards ---------------------------------------------------------------

  def shard_items(pool, queue = "default")
    pool.call("LRANGE", config.key("queue", queue), 0, -1).reverse.map { |raw| JSON.parse(raw) }
  end

  def test_via_sends_pushes_to_another_pool
    with_shard do |shard|
      other = Robin::Redis::Pool.new { nil }
      Client.via(shard) do
        assert_same shard, Client.current_pool
        assert_same shard, Client.new.redis_pool
        assert_same other, Client.new(pool: other).redis_pool
        Client.push("class" => "Thing", "args" => [1])

        Client.via(other) { assert_same other, Client.current_pool }

        assert_same shard, Client.current_pool
      end

      assert_nil Client.current_pool
      assert_raises(RuntimeError) { Client.via(shard) { raise "boom" } }
      assert_nil Client.current_pool
      assert_equal [[1]], shard_items(shard).map { |i| i["args"] }
      assert_empty queue_items
    end
  end

  def test_via_is_per_thread
    with_shard do |shard|
      Client.via(shard) { Thread.new { assert_nil Client.current_pool }.join }
    end
  end

  def test_reliable_push_buffers_per_pool
    config.reliable_push = true
    down = Robin::Redis::Pool.new(size: 1) { Robin::Redis::Connection.new(url: "redis://127.0.0.1:1/0", connect_timeout: 0.2) }
    Client.via(down) { Client.push("class" => "Thing", "args" => [2]) }

    assert_equal 1, Robin::ReliablePush.for(config, down).size
    assert_equal 0, Robin::ReliablePush.for(config).size
  ensure
    Robin::ReliablePush.for(config, down).instance_variable_get(:@retrier)&.kill
    down.shutdown
  end

  # -- jid index ------------------------------------------------------------

  def test_jid_index_records_each_jobs_queue
    config.jid_index = 120
    assert_roundtrips(1) { Client.push("class" => "Thing", "args" => [], "jid" => "now", "queue" => "q1") }
    assert_roundtrips 1 do
      Client.push_bulk("class" => "Thing", "args" => [[1], [2]], "jids" => %w[b1 b2], "queue" => "q2", "at" => Time.now.to_f + 60)
    end

    assert_equal %w[q1 q2 q2], %w[now b1 b2].map { |jid| redis("GET", config.key("jid", jid)) }
    assert_in_delta 120, redis("TTL", config.key("jid", "now")), 2
  end

  def test_no_jid_index_by_default
    Client.push("class" => "Thing", "args" => [], "jid" => "plain")

    assert_nil redis("GET", config.key("jid", "plain"))
  end

  # -- push -----------------------------------------------------------------

  def test_class_level_push
    jid = assert_roundtrips(1) { Client.push("class" => "Thing", "args" => [1]) }

    assert_equal jid, queue_items.first["jid"]
    jids = assert_roundtrips(1) { Client.push_bulk("class" => "Thing", "args" => [[2], [3]]) }

    assert_equal jids, queue_items.drop(1).map { |i| i["jid"] }
  end

  def test_push_enqueues_with_defaults
    with_now(1_000) do
      item = {"class" => "Thing", "args" => [1, "a"]}
      jid = Client.new.push(item)

      assert_equal({"class" => "Thing", "args" => [1, "a"]}, item)
      assert_equal [{"class" => "Thing", "args" => [1, "a"], "queue" => "default", "retry" => true,
                     "jid" => jid, "created_at" => 1_000, "enqueued_at" => 1_000}], queue_items
      assert_equal ["default"], redis("SMEMBERS", config.key("queues"))
    end
  end

  def test_push_with_symbol_keys_and_class_options
    jid = Client.new.push(class: ClientTestJobs::Opts, args: [], queue: :fast, jid: "given", created_at: 5)
    item = queue_items("fast").first

    assert_equal "given", jid
    assert_equal "ClientTestJobs::Opts", item["class"]
    assert_equal 2, item["retry"]
    assert_equal ["t"], item["tags"]
    assert_equal 5, item["created_at"]
  end

  def test_push_schedules_future_jobs
    with_now(10_000) do
      # A job pushed again (e.g. copied from another) drops its old
      # enqueued_at while it waits.
      assert_roundtrips(1) { Client.new.push("class" => "Thing", "args" => [], "at" => 20.0, "enqueued_at" => 5) }
      Client.new.push("class" => "Thing", "args" => [], "at" => 0)
    end
    (item, score), = scheduled

    assert_in_delta 30.0, score, 0
    refute item.key?("at")
    refute item.key?("enqueued_at")
    assert_equal 1, queue_items.size
    refute queue_items.first.key?("at")
  end

  def test_jobs_due_exactly_now_are_enqueued
    now = 200_000_000_000
    with_now(now) do
      Client.new.push("class" => "Thing", "args" => [], "at" => now)
      Client.new.push("class" => "Thing", "args" => [], "at" => now + 1)
    end

    assert_equal [now], queue_items.map { |i| i["enqueued_at"] }
    assert_equal [200_000_000.001], scheduled.map(&:last)
  end

  def test_immediate_jobs_have_no_at
    seen = []
    mw = Class.new do
      define_method(:call) do |_klass, payload, _queue, _redis, &blk|
        seen << payload.key?("at")
        blk.call
      end
    end
    config.client_middleware { |c| c.add mw }
    Client.new.push("class" => "Thing", "args" => [])
    Client.new.push_bulk("class" => "Thing", "args" => [[1]])

    assert_equal [false, false], seen
  end

  def test_push_does_not_change_the_callers_hash
    item = {"class" => "Thing", "args" => [], "jids" => ["x"]}
    Client.new.push_bulk(item)

    assert_equal({"class" => "Thing", "args" => [], "jids" => ["x"]}, item)
  end

  def test_push_bulk_needs_a_jid_per_job
    assert_raises(IndexError) { Client.new.push_bulk("class" => "T", "args" => [[1], [2]], "jids" => ["only-one"]) }
  end

  def test_subclasses_of_native_types_are_fine
    key = Class.new(String).new("k")
    list = Class.new(Array).new([1])

    assert Client.new.normalize("class" => "T", "args" => [{key => 1}])
    assert Client.new.normalize("class" => "T", "args" => list)
    assert_equal [[1]], Client.new.push_bulk("class" => "T", "args" => Class.new(Array).new([[1]])).then { |jids| queue_items.map { |i| i["args"] } }
  end

  def test_strict_args_checks_every_hash_value
    error = assert_raises(Client::ArgumentError) { Client.new.normalize("class" => "T", "args" => [{"ok" => 1, "bad" => :sym}]) }
    assert_includes error.message, "got :sym (Symbol)"
  end

  def test_bulk_ats_can_be_array_subclasses
    with_now(1_000) do
      Client.new.push_bulk("class" => "T", "args" => [[1], [2]], "at" => Class.new(Array).new([50, 60]))
    end

    assert_equal [51.0, 61.0], scheduled.map(&:last)
    error = assert_raises(Client::ArgumentError) { Client.new.push_bulk("class" => "T", "args" => [[1]], "at" => Class.new(Array).new([1, 2])) }
    assert_match(/same size/, error.message)
  end

  def test_strict_args_only_checks_args
    assert Client.new.normalize("class" => "T", "args" => [1], "meta" => Object.new)
  end

  def test_expires_in_accepts_durations
    with_now(1_000) do
      duration = Struct.new(:to_f).new(1.5)
      item = Client.new.normalize("class" => "T", "args" => [], "expires_in" => duration)

      assert_same 2_500, item["expires_at"]
      assert_same 1_001, Client.new.normalize("class" => "T", "args" => [], "expires_in" => 0.0015)["expires_at"]
    end
  end

  def test_push_middleware_can_change_or_stop_jobs
    config.client_middleware { |c| c.add halting_middleware { |p| p["args"] != ["stop"] } }

    assert_nil assert_roundtrips(0) { Client.new.push("class" => "Thing", "args" => ["stop"]) }
    assert Client.new.push("class" => "Thing", "args" => ["go"])
    assert_equal [["go"]], queue_items.map { |i| i["args"] }
  end

  def test_a_client_may_have_its_own_chain
    config.client_middleware { |c| c.add halting_middleware { |_p| false } }
    own = Robin::Middleware::Chain.new(config).add(halting_middleware { |p| p["args"] != ["stop"] })
    client = Client.new(chain: own)

    assert_same own, client.middleware
    assert_same config.client_middleware, Client.new.middleware
    assert_nil client.push("class" => "Thing", "args" => ["stop"])
    assert client.push("class" => "Thing", "args" => ["go"])
    assert_equal [nil], client.push_bulk("class" => "Thing", "args" => [["stop"]])
    assert_nil Client.new.push("class" => "Thing", "args" => ["go"])
    assert_equal [["go"]], queue_items.map { |i| i["args"] }
  end

  def test_middleware_receives_class_queue_and_pool
    seen = []
    mw = Class.new do
      define_method(:call) do |klass, payload, queue, redis, &blk|
        seen << [klass, payload["jid"], queue, redis]
        blk.call
      end
    end
    config.client_middleware { |c| c.add mw }
    pool = config.redis_pool
    jid = Client.new(pool: pool).push("class" => "Thing", "args" => [], "queue" => "q")
    jids = Client.new.push_bulk("class" => "Thing", "args" => [[1]], "queue" => "q2")

    assert_equal [["Thing", jid, "q", pool], ["Thing", jids.first, "q2", pool]], seen
  end

  # -- push_bulk ------------------------------------------------------------

  def test_push_bulk
    with_now(1_000) do
      jids = assert_roundtrips(1) { Client.new.push_bulk("class" => "Thing", "args" => [[1], [2]], "queue" => "bulk") }

      assert_equal 2, jids.compact.uniq.size
      assert_equal [[1], [2]], queue_items("bulk").map { |i| i["args"] }
    end
  end

  def test_push_bulk_in_a_batch_registers_its_jobs_in_one_go
    batch = Robin::Batch.new(config: config)
    registered = []
    batch.define_singleton_method(:queue_register) do |tx, members|
      registered << members
      super(tx, members)
    end
    jids = nil
    # The batch made, its jobs registered and pushed, the block closed.
    assert_roundtrips(3) { batch.jobs { jids = Client.new.push_bulk("class" => "Thing", "args" => [[1], [2]], "queue" => "bulk") } }

    assert_equal [jids], registered
    assert_equal [batch.bid] * 2, queue_items("bulk").map { |i| i["bid"] }
  end

  def test_push_bulk_with_symbols_ats_and_jids
    with_now(1_000) do
      jids = Client.new.push_bulk(:class => "Thing", :args => [[1], [2], [3]], :at => [0, 50, 100], "jids" => %w[a b c])

      assert_equal %w[a b c], jids
      assert_equal [["a", 1_000]], queue_items.map { |i| [i["jid"], i["enqueued_at"]] }
      assert_equal [["b", 51.0], ["c", 101.0]], scheduled.map { |i, s| [i["jid"], s] }
      Client.new.push_bulk(class: "Thing", args: [[4], [5]], at: 30)

      assert_equal [31.0, 31.0], scheduled.select { |i, _| i["args"].first > 3 }.map(&:last)
    end
  end

  def test_push_bulk_shares_what_jobs_have_in_common
    with_now(1_000) do
      Client.new.push_bulk("class" => ClientTestJobs::Opts, "args" => [[1], [2]], "expires_in" => 5, "jids" => ["a", nil])
    end
    first, second = queue_items("opts").sort_by { |i| i["args"] }

    assert_equal ["a", 1_000, 6_000, ["t"]], first.values_at("jid", "created_at", "expires_at", "tags")
    assert_match(/\A\h{24}\z/, second.fetch("jid"))
    assert_equal [1_000, 6_000, ["t"]], second.values_at("created_at", "expires_at", "tags")
    refute_includes first.keys, "expires_in"
  end

  def test_push_bulk_with_one_jid_gives_it_to_every_job
    assert_equal %w[same same], Client.new.push_bulk("class" => "T", "args" => [[1], [2]], "jid" => "same")
  end

  def test_push_bulk_ats_may_leave_some_jobs_unscheduled
    with_now(1_000) { Client.new.push_bulk("class" => "T", "args" => [[1], [2]], "at" => [nil, 5]) }

    assert_equal [[1]], queue_items.map { |i| i["args"] }
    assert_equal [[[2], 6.0]], scheduled.map { |i, at| [i["args"], at] }
    refute queue_items.first.key?("at")
  end

  def test_push_bulk_middleware_changes_stay_with_their_job
    mw = Class.new do
      define_method(:call) do |_klass, payload, _queue, _redis, &blk|
        payload["mark"] = payload["args"].first
        blk.call
      end
    end
    config.client_middleware { |c| c.add mw }
    Client.new.push_bulk("class" => "T", "args" => [[1], [2]])

    assert_equal [1, 2], queue_items.map { |i| i["mark"] }.sort
  end

  def test_push_bulk_checks_every_jobs_arguments
    error = assert_raises(Client::ArgumentError) { Client.new.push_bulk("class" => "T", "args" => [[1], [:bad]]) }
    assert_includes error.message, "Job arguments for T must be JSON-native types"
    assert_includes error.message, "got :bad (Symbol)"
    assert_empty queue_items
    config.strict_args = false
    Client.new.push_bulk("class" => "T", "args" => [[:fine]])

    assert_equal [["fine"]], queue_items.map { |i| i["args"] }
  end

  def test_push_bulk_makes_one_jid_per_job_and_checks_arguments_once
    log = StringIO.new
    config.logger = Logger.new(log)
    config.strict_args = :warn
    made = 0
    real = Robin.method(:generate_jid)
    stub_method(Robin, :generate_jid, -> { (made += 1) && real.call }) do
      Client.new.push_bulk("class" => "T", "args" => [[:sym], [2]])
    end

    assert_equal 2, made
    assert_equal 1, log.string.scan("must be JSON-native").size
    assert_equal [%w[args class created_at enqueued_at jid queue retry]] * 2, queue_items.map { |i| i.keys.sort }
  end

  def test_push_bulk_middleware_can_stop_some_jobs
    config.client_middleware { |c| c.add halting_middleware { |p| p["args"] != [2] } }
    jids = Client.new.push_bulk("class" => "Thing", "args" => [[1], [2], [3]])

    assert_nil jids[1]
    assert_equal 2, jids.compact.size
    assert_equal [[1], [3]], queue_items.map { |i| i["args"] }
    assert_equal [nil, nil], assert_roundtrips(0) { Client.new.push_bulk("class" => "Thing", "args" => [[2], [2]]) }
  end

  def test_spread
    with_now(1_700_000_000_000) do
      assert_equal [1_700_000_000_000, 1_700_000_002_500, 1_700_000_005_000, 1_700_000_007_500], Client.spread(4, 10)
      assert_equal [1_700_000_060_000, 1_700_000_060_333, 1_700_000_060_666], Client.spread(3, 1, 60)
      assert_equal [1_700_000_000_000, 1_700_000_000_750], Client.spread(2, 1.5)
      assert(Client.spread(3, 0.01).all?(Integer))
      assert_empty Client.spread(0, 1)
    end
    [0, -1, "5", nil].each do |bad|
      error = assert_raises(Client::ArgumentError) { Client.spread(1, bad) }
      assert_equal "'spread_interval' must be a positive number of seconds", error.message
    end
  end

  def test_push_bulk_spreads_jobs_over_an_interval
    with_now(1_700_000_000_000) do
      Client.new.push_bulk(:class => "T", :args => [[1], [2], [3]], "spread_interval" => 30)
      Client.new.push_bulk("class" => "T", "args" => [[4], [5]], "spread_interval" => 10, "at" => 100)
    end

    assert_equal [[1]], queue_items.map { |i| i["args"] }
    assert_equal [[[2], 1_700_000_010.0], [[3], 1_700_000_020.0], [[4], 1_700_000_100.0], [[5], 1_700_000_105.0]],
      scheduled.map { |i, at| [i["args"], at] }.sort
    refute scheduled.first.first.key?("spread_interval")
    error = assert_raises(Client::ArgumentError) { Client.new.push_bulk("class" => "T", "args" => [[1]], "at" => [1], "spread_interval" => 5) }
    assert_equal "push_bulk takes 'spread_interval' or an 'at' per job, not both", error.message
    ats = Class.new(Array).new([1])
    error = assert_raises(Client::ArgumentError) { Client.new.push_bulk("class" => "T", "args" => [[1]], "at" => ats, "spread_interval" => 5) }
    assert_equal "push_bulk takes 'spread_interval' or an 'at' per job, not both", error.message
  end

  def test_push_bulk_validation
    [nil, [1], [[1], 2], "x"].each do |bad|
      error = assert_raises(Client::ArgumentError) { Client.new.push_bulk("class" => "Thing", "args" => bad) }
      assert_equal "push_bulk needs 'args' to be an Array of Arrays", error.message
    end
    error = assert_raises(Client::ArgumentError) { Client.new.push_bulk("class" => "Thing") }
    assert_equal "push_bulk needs 'args' to be an Array of Arrays", error.message
    error = assert_raises(Client::ArgumentError) { Client.new.push_bulk("class" => "Thing", "args" => [[1]], "at" => [1, 2]) }
    assert_equal "push_bulk 'at' must have the same size as 'args'", error.message
    assert_empty Client.new.push_bulk("class" => "Thing", "args" => [])
    assert_kind_of ::ArgumentError, error
  end

  # -- normalize ------------------------------------------------------------

  def test_normalize
    with_now(7) do
      item = Client.new.normalize({class: "Thing", args: [], queue: "", wait: 1, wait_until: 2, sync: true,
                                   at: nil, expires_in: 2.5, retry: false})

      assert_equal({"class" => "Thing", "args" => [], "queue" => "default", "retry" => false,
                    "jid" => item["jid"], "created_at" => 7, "expires_at" => 2_507}, item)
      assert_match(/\A\h{24}\z/, item["jid"])
    end
  end

  def test_normalize_stores_at_in_epoch_seconds_and_expires_from_it
    with_now(1_000) do
      later = Client.new.normalize("class" => "T", "args" => [], "at" => 2.5, "expires_in" => 10)
      past = Client.new.normalize("class" => "T", "args" => [], "at" => Time.at(0.5), "expires_in" => 1)

      assert_in_delta 3.5, later["at"], 0
      assert_same 13_500, later["expires_at"]
      assert_in_delta 0.5, past["at"], 0
      assert_same 2_000, past["expires_at"]
    end
  end

  def test_push_bulk_expiry_counts_from_each_jobs_own_time
    with_now(1_000) do
      Client.new.push_bulk("class" => "T", "args" => [[1], [2], [3]], "at" => [nil, 5, Time.at(0.5)], "expires_in" => 2)
      Client.new.push_bulk("class" => "T", "args" => [[4]], "at" => 9, "expires_in" => 2)
      Client.new.push_bulk("class" => "T", "args" => [[5]], "at" => [11], "expires_at" => nil)
    end

    assert_equal [[[1], 3_000], [[3], 3_000]], queue_items.map { |i| i.values_at("args", "expires_at") }
    assert_equal [[[2], 8_000, 6.0], [[4], 12_000, 10.0], [[5], nil, 12.0]],
      scheduled.map { |i, score| [*i.values_at("args", "expires_at"), score] }
  end

  def test_normalize_classes
    assert_equal "ClientTestJobs::Bare", Client.new.normalize("class" => ClientTestJobs::Bare, "args" => [])["class"]
    assert_equal "Thing", Client.new.normalize("class" => :Thing, "args" => [])["class"]
    opts = Client.new.normalize("class" => ClientTestJobs::Opts, "args" => [], "retry" => 9)

    assert_equal ["opts", 9, ["t"]], opts.values_at("queue", "retry", "tags")
    assert_equal "q", Client.new.normalize("class" => "T", "args" => [], "queue" => :q)["queue"]
  end

  def test_normalize_validation
    error = assert_raises(Client::ArgumentError) { Client.new.normalize("args" => []) }
    assert_equal "job must have a 'class'", error.message
    error = assert_raises(Client::ArgumentError) { Client.new.normalize("class" => "T", "args" => "x") }
    assert_equal "job 'args' must be an Array", error.message
    assert_raises(Client::ArgumentError) { Client.new.normalize("class" => "T") }
  end

  def test_retry_for_and_retry_queue
    [0, -1, "60"].each do |bad|
      error = assert_raises(Client::ArgumentError) { Client.new.normalize("class" => "T", "args" => [], "retry_for" => bad) }
      assert_equal "job 'retry_for' must be a positive number of seconds", error.message
    end
    assert_in_delta(0.5, Client.new.normalize("class" => "T", "args" => [], "retry_for" => 0.5)["retry_for"])
    refute Client.new.normalize("class" => "T", "args" => [], "retry_for" => nil)["retry_for"]
    assert_equal "slow", Client.new.normalize("class" => "T", "args" => [], "retry_queue" => :slow)["retry_queue"]
    refute Client.new.normalize("class" => "T", "args" => []).key?("retry_queue")
    assert_nil Client.new.normalize("class" => "T", "args" => [], "retry_queue" => nil)["retry_queue"]
  end

  # -- strict args ----------------------------------------------------------

  def test_strict_args
    ok = [1, 1.5, "s", true, false, nil, [1, ["deep"]], {"k" => {"n" => [nil]}}]

    assert Client.new.normalize("class" => "T", "args" => ok)
    [:sym, Time.now, {k: 1}, {"k" => :v}, [[:nested]], [{"a" => [Object.new]}]].each do |bad|
      error = assert_raises(Client::ArgumentError) { Client.new.normalize("class" => "T", "args" => [bad]) }
      assert_match(/\AJob arguments for T must be JSON-native types .*; got .* \(\w+\)\. Pass IDs or plain values instead of objects\.\z/, error.message)
    end
  end

  def test_strict_args_reports_the_offending_value
    error = assert_raises(Client::ArgumentError) { Client.new.normalize("class" => "T", "args" => [1, {"a" => [2, :bad]}]) }
    assert_includes error.message, "got :bad (Symbol)"
    error = assert_raises(Client::ArgumentError) { Client.new.normalize("class" => "T", "args" => [{1 => "a"}]) }
    assert_includes error.message, "got 1 (Integer)"
    error = assert_raises(Client::ArgumentError) { Client.new.normalize("class" => "T", "args" => [[1, [:x]], :y]) }
    assert_includes error.message, "got :x (Symbol)"
  end

  def test_strict_args_modes
    log = StringIO.new
    config.logger = Logger.new(log)
    config.strict_args = :warn

    assert Client.new.normalize("class" => "T", "args" => [:sym])
    assert_includes log.string, "Job arguments for T must be JSON-native types"
    config.strict_args = false

    assert Client.new.normalize("class" => "T", "args" => [:sym])
    config.strict_args = :anything_else

    assert_raises(Client::ArgumentError) { Client.new.normalize("class" => "T", "args" => [:sym]) }
  end

  # -- delivery -------------------------------------------------------------

  def test_reliable_push_buffers_when_redis_is_down
    down = Robin::Config.new
    down.logger = Logger.new(nil)
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    down.redis = {host: "127.0.0.1", port: port}
    assert_raises(Robin::Redis::ConnectionError) { Client.new(config: down).push("class" => "T", "args" => []) }
    down.reliable_push = true

    assert Client.new(config: down).push("class" => "T", "args" => [])
    assert_equal 1, Robin::ReliablePush.for(down).size
  ensure
    Robin::ReliablePush.for(down).instance_variable_get(:@retrier)&.kill
  end

  def test_reliable_push_when_redis_is_up
    config.reliable_push = true
    assert_roundtrips(1) { Client.new.push("class" => "T", "args" => []) }

    assert_equal 1, queue_items.size
  end

  def test_push_deferrer_can_hold_jobs_until_later
    held = []
    seen = []
    config.push_deferrer = lambda do |payloads, &deliver|
      seen << payloads.map { |p| p.fetch("args") }
      held << deliver
      true
    end
    jid = Client.new.push("class" => "T", "args" => [1])
    Client.new.push_bulk("class" => "T", "args" => [[2], [3]])

    assert_empty queue_items
    assert_equal [[[1]], [[2], [3]]], seen
    held.each(&:call)

    assert_equal [[1], [2], [3]], queue_items.map { |i| i["args"] }
    assert_equal jid, queue_items.first["jid"]
  end

  def test_push_deferrer_can_deliver_now
    config.push_deferrer = ->(_payloads, &_deliver) {}
    Client.new.push("class" => "T", "args" => [1])

    assert_equal 1, queue_items.size
  end

  def test_jobs_pushed_inside_an_atomic_batch_block_wait_for_it
    inside = nil
    jids = nil
    Robin::Batch.new(config: config).jobs(atomic: true) do
      jids = [Client.new.push("class" => "T", "args" => [1]), *Client.new.push_bulk("class" => "T", "args" => [[2], [3]])]
      inside = [queue_items, Robin::Batch.hold.pushes.map { |client, payloads| [client.class, payloads.size] }]
    end

    assert_equal [[], [[Client, 1], [Client, 2]]], inside
    assert_equal jids, queue_items.map { |i| i.fetch("jid") }
  end

  # -- a push inside a batch's jobs block ----------------------------------------

  # The queued jobs that aren't batch callbacks.
  def jobs = queue_items.reject { |i| i["batch_callback"] }

  # The round trips of +pool+'s calls, each as [kind, commands].
  def trips(pool) = pool.calls.slice_before { |c| c[0] != :tx && c[0] != :pipe }.map { |trip| [trip.first.first, trip.drop(1).map { |c| c[1] }] }

  def test_a_push_in_a_batch_is_registered_and_sent_in_one_transaction
    batch = Robin::Batch.new(config: config)
    batch.jobs {} # created
    jid = nil
    pool = recording_pool { batch.jobs { jid = Client.push("class" => "T", "args" => [1]) } }

    assert_equal [[:call, []], [:multi, %w[SADD EXPIRE HINCRBY HINCRBY SADD LPUSH]], [:evalsha, []]], trips(pool)
    assert_equal [[jid, batch.bid]], jobs.map { |i| i.values_at("jid", "bid") }
    assert_equal [1, 1], [batch.status.pending, batch.status.total]
  end

  def test_a_push_to_another_redis_is_registered_first_then_sent_there
    batch = Robin::Batch.new(config: config)
    batch.jobs {}
    with_shard do |shard|
      pool = recording_pool { batch.jobs { Client.via(shard) { Client.push("class" => "T", "args" => [1]) } } }

      assert_equal [[:call, []], [:multi, %w[SADD EXPIRE HINCRBY HINCRBY]], [:evalsha, []]], trips(pool)
      assert_equal [batch.bid], shard_items(shard).map { |i| i["bid"] }
    end
  end

  def test_a_push_that_may_not_go_straight_to_redis_is_registered_first
    batch = Robin::Batch.new(config: config)
    batch.jobs {}
    config.reliable_push = true
    pool = recording_pool { batch.jobs { Client.push("class" => "T", "args" => [1]) } }

    assert_equal [[:call, []], [:multi, %w[SADD EXPIRE HINCRBY HINCRBY]], [:pipelined, %w[SADD LPUSH]], [:evalsha, []]], trips(pool)
    assert_equal [batch.bid], jobs.map { |i| i["bid"] }
  end

  def test_a_stopped_push_in_a_batch_still_registers_like_before
    batch = Robin::Batch.new(config: config)
    batch.jobs {}
    pool = recording_pool { batch.jobs { assert_nil Client.new(chain: stop_after_batch).push("class" => "T", "args" => [1]) } }

    assert_equal [[:call, []], [:multi, %w[SADD EXPIRE HINCRBY HINCRBY]], [:evalsha, []]], trips(pool)
    assert_empty jobs
  end

  # A chain whose batch middleware registers the job, then stops its push.
  def stop_after_batch
    Robin::Middleware::Chain.new(config).add(Robin::Batch::ClientMiddleware).add(Class.new { def call(*) = nil })
  end

  # The commands of each round trip +pool+ recorded: [kind, commands].
  def round_trips(pool) = pool.calls.slice_before { |c| c[0] != :pipe }.map { |trip| [trip.first.first, trip.drop(1).map { |c| c[1] }] }

  def test_push_bulk_takes_unique_locks_in_one_round_trip
    pool = recording_pool { assert_roundtrips(2) { Client.new.push_bulk("class" => ClientTestJobs::Unique, "args" => [[1], [2]]) } }

    assert_equal [[:pipelined, %w[SET SET]], [:pipelined, %w[SADD LPUSH]]], round_trips(pool)
  end

  def test_a_debounce_claim_goes_with_the_payload_a_middleware_returns_instead
    config.client_middleware.add(Class.new { def call(_c, payload, *) = yield && {**payload, "tag" => 1} })
    earlier = Client.push("class" => ClientTestJobs::Debounced, "args" => [1])
    later = assert_roundtrips(1) { Client.push("class" => ClientTestJobs::Debounced, "args" => [1]) }

    assert_equal [later], Robin::ScheduledSet.new(config: config).map(&:jid), "the earlier #{earlier} went"
  end

  def test_push_bulk_makes_debounce_claims_as_it_pushes
    pool = recording_pool { assert_roundtrips(1) { Client.new.push_bulk("class" => ClientTestJobs::Debounced, "args" => [[1], [2]]) } }

    assert_equal [[:pipelined, [:evalsha, :evalsha, "ZADD"]]], round_trips(pool)
  end

  def test_direct
    client = Client.new
    batch_job = {"bid" => "b"}

    assert client.direct?([{}])
    config.push_deferrer = ->(*) {}

    refute client.direct?([{}])
    refute client.direct?([])
    assert client.direct?([{}, batch_job])
    config.reliable_push = true

    refute client.direct?([batch_job])
    config.reliable_push = false

    with_interceptor(->(_) {}) { refute client.direct?([batch_job]) }
  end

  # -- Client.together -----------------------------------------------------------

  def queued(queue = "default") = Robin::Queue.new(queue, config: config).map(&:args)

  def test_together_sends_every_push_in_one_round_trip
    jids = assert_roundtrips(1) do
      Client.together do
        [Client.push("class" => "T", "args" => [1]), Client.push_bulk("class" => "T", "args" => [[2], [3]], "queue" => "q"),
          Client.push("class" => "T", "args" => [4], "at" => Time.now + 60)]
      end
    end

    assert_equal 4, jids.flatten.compact.size
    assert_equal [[4], [1]], [Robin::ScheduledSet.new(config: config).map(&:args).first, *queued]
    assert_equal [[2], [3]], queued("q")
  end

  def test_together_holds_the_pushes_until_the_block_finishes
    Client.together do
      Client.together { Client.push("class" => "T", "args" => [1]) }

      assert_empty queued, "the outer block sends it"
    end

    assert_equal [[1]], queued
    assert_roundtrips(0) { assert_equal :none, Client.together { :none } }
    assert_roundtrips(1) { Client.together { 2.times { |i| Client.push("class" => "T", "args" => [i]) } } }
    assert_equal [[1], [0], [1]], queued, "another block holds its pushes too"
  end

  def test_together_sends_nothing_if_the_block_raises
    assert_raises(RuntimeError) do
      Client.together do
        Client.push("class" => "T", "args" => [1])
        raise "boom"
      end
    end

    assert_empty queued
    Client.push("class" => "T", "args" => [2])

    assert_equal [[2]], queued, "and holds nothing back after"
  end

  def test_together_sends_each_push_its_own_way_unless_they_go_straight_to_one_redis
    seen = []
    with_interceptor(->(payloads) { seen << payloads.map { |p| p["args"] } }) do
      Client.together { 2.times { |i| Client.push("class" => "T", "args" => [i]) } }
    end

    assert_equal [[[0]], [[1]]], seen
    with_shard do |shard|
      assert_roundtrips(2) do
        Client.together do
          Client.push("class" => "T", "args" => [1])
          Client.via(shard) { Client.push("class" => "T", "args" => [2]) }
        end
      end
      assert_equal [[1]], queued
      assert_equal 1, shard.with { |c| c.call("LLEN", config.key("queue", "default")) }
    end
  end

  def test_plain
    client = Client.new

    assert_predicate client, :plain?
    config.reliable_push = true

    refute_predicate client, :plain?
    config.reliable_push = false

    with_interceptor(->(_) {}) { refute_predicate client, :plain? }
  end

  def test_deferred_jobs_go_through_reliable_push
    down = Robin::Config.new
    down.logger = Logger.new(nil)
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    down.redis = {host: "127.0.0.1", port: port}
    down.reliable_push = true
    held = nil
    down.push_deferrer = ->(_payloads, &deliver) { held = deliver }
    Client.new(config: down).push("class" => "T", "args" => [])
    held.call

    assert_equal 1, Robin::ReliablePush.for(down).size
  ensure
    Robin::ReliablePush.for(down).instance_variable_get(:@retrier)&.kill
  end
end
