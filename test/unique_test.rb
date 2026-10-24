# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class UniqueJob
  include Robin::Job

  robin_options unique_for: 60
  def perform(x)
    raise "fail" if x == "fail"
  end
end

class UniqueStartJob
  include Robin::Job

  robin_options unique_for: 60, unique_until: :start
  def perform(_) = nil
end

class UniqueByFirstArg
  include Robin::Job

  robin_options unique_for: 60
  def self.robin_unique_args(args) = args.first(1)

  def perform(*) = nil
end

class UniqueTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Unique*"

  def server_mw = Robin::Unique::ServerMiddleware.new.tap { |m| m.config = config }

  def client_mw = Robin::Unique::ClientMiddleware.new.tap { |m| m.config = config }

  def lock_ttl(klass, args, queue: "default")
    redis("PTTL", Robin::Unique.lock_key(config, Robin::Unique.digest(klass, queue, args)))
  end

  def lock_owner(klass, args, queue: "default")
    redis("GET", Robin::Unique.lock_key(config, Robin::Unique.digest(klass, queue, args)))
  end

  def test_digest
    d = Robin::Unique.digest("UniqueJob", "default", [1, {"a" => 2}])

    assert_equal Digest::SHA256.hexdigest(JSON.generate(["UniqueJob", "default", [1, [["a", 2]]]])), d
    refute_equal d, Robin::Unique.digest("UniqueJob", "other", [1, {"a" => 2}])
    refute_equal d, Robin::Unique.digest("Other", "default", [1, {"a" => 2}])
    assert_equal Robin::Unique.digest("UniqueByFirstArg", "q", [1]), Robin::Unique.digest("UniqueByFirstArg", "q", [1, "x"])
    refute_equal Robin::Unique.digest("UniqueByFirstArg", "q", [1]), Robin::Unique.digest("UniqueByFirstArg", "q", [2])
    assert_equal Digest::SHA256.hexdigest(JSON.generate(["UniqueByFirstArg", "q", [1]])), Robin::Unique.digest("UniqueByFirstArg", "q", [1, "x"])
    assert_equal Digest::SHA256.hexdigest(JSON.generate(["No::Such::Job", "q", [1, 2]])), Robin::Unique.digest("No::Such::Job", "q", [1, 2])
  end

  def test_canonical
    assert_equal [["a", 1], ["b", [["c", 2], ["d", 3]]]], Robin::Unique.canonical({"b" => {"d" => 3, :c => 2}, :a => 1})
    assert_equal [1, [["x", nil]], "s"], Robin::Unique.canonical([1, {"x" => nil}, "s"])
    assert_equal 5, Robin::Unique.canonical(5)
    assert_equal [], Robin::Unique.canonical({})
  end

  def test_lock_key
    assert_equal "#{key_prefix_for_test}unique:abc", Robin::Unique.lock_key(config, "abc")
  end

  def test_locked
    refute assert_roundtrips(1) { Robin::Unique.locked?("UniqueJob", [1]) }
    redis("SET", Robin::Unique.lock_key(config, Robin::Unique.digest("UniqueJob", "default", [1])), "j")

    assert Robin::Unique.locked?("UniqueJob", [1])
    refute Robin::Unique.locked?("UniqueJob", [1], queue: "other")
    other = Robin::Config.new
    other.redis = {url: REDIS_URL}
    other.key_prefix = "#{key_prefix_for_test}other:"

    refute Robin::Unique.locked?("UniqueJob", [1], config: other)
  ensure
    other&.redis_pool&.shutdown
  end

  def test_release
    pool = recording_pool { assert_nil Robin::Unique.release(config, {"jid" => "j"}) }

    assert_empty pool.recorders
    recording { |c| assert_nil Robin::Unique.eval_release(c, config, {"jid" => "j"}) }.then { |rec| assert_empty rec.calls }
    key = Robin::Unique.lock_key(config, "d")
    redis("SET", key, "owner")

    assert_equal 0, assert_roundtrips(1) { Robin::Unique.release(config, {"unique_digest" => "d", "jid" => "other"}) }
    assert_equal "owner", redis("GET", key)
    assert_equal 1, Robin::Unique.release(config, {"unique_digest" => "d", "jid" => "owner"})
    assert_nil redis("GET", key)
  end

  def test_client_middleware_passes_through_without_option
    payload = {"args" => [1], "jid" => "j"}

    assert_equal :pushed, client_mw.call("UniqueJob", payload, "default", nil) { :pushed }
    refute payload.key?("unique_digest")
    already = {"args" => [1], "jid" => "j", "unique_for" => 60, "unique_digest" => "x"}

    assert_equal :pushed, client_mw.call("UniqueJob", already, "default", nil) { :pushed }
    assert_equal "x", already["unique_digest"]
    refute Robin::Unique.locked?("UniqueJob", [1])
  end

  def test_client_middleware_locks_and_suppresses
    first = {"args" => [1], "jid" => "a", "unique_for" => 60}

    assert_equal :pushed, client_mw.call("UniqueJob", first, "default", nil) { :pushed }
    assert_equal Robin::Unique.digest("UniqueJob", "default", [1]), first["unique_digest"]
    assert_equal "a", lock_owner("UniqueJob", [1])
    assert_in_delta 60_000, lock_ttl("UniqueJob", [1]), 1_000
    second = {"args" => [1], "jid" => "b", "unique_for" => 60}
    ran = false

    assert_nil client_mw.call("UniqueJob", second, "default", nil) { ran = true }
    refute ran
    refute second.key?("unique_digest")
    assert_equal "a", lock_owner("UniqueJob", [1])
  end

  # The expiry (epoch ms) the lock the block takes is set to, as the SET
  # asked for it (PEXPIRETIME needs Redis 7); Redis keeps it.
  def lock_expiry(&)
    _, set, key, _, nx, pxat, at = recording_pool(&).calls.find { |c| c[1] == "SET" }

    assert_equal %w[SET NX PXAT], [set, nx, pxat]
    assert_in_delta at - Robin.now_ms, redis("PTTL", key), 1_000
    at
  end

  def test_client_middleware_ttl
    before = Robin.now_ms
    expiry = lock_expiry { client_mw.call("UniqueJob", {"args" => [2], "jid" => "a", "unique_for" => 0.5}, "default", nil) { :ok } }

    assert_includes (before + 500)..(Robin.now_ms + 500), expiry
    at = Robin.now_ms + 3_600_123
    expiry = lock_expiry { client_mw.call("UniqueJob", {"args" => [4], "jid" => "a", "unique_for" => 60, "at" => Robin.epoch_seconds(at)}, "default", nil) { :ok } }

    assert_equal at + 60_000, expiry
    past = Robin.epoch_seconds(Robin.now_ms - 3_600_000)
    before = Robin.now_ms
    expiry = lock_expiry { client_mw.call("UniqueJob", {"args" => [5], "jid" => "a", "unique_for" => 60, "at" => past}, "default", nil) { :ok } }

    assert_includes (before + 60_000)..(Robin.now_ms + 60_000), expiry
  end

  # Nothing to lock: no round trip.
  def test_client_middleware_zero_or_negative_ttl_does_not_lock
    [0, -1, 0.0, nil].each do |ttl|
      payload = {"args" => [3], "jid" => "a", "unique_for" => ttl}
      pool = recording_pool { assert_equal :ok, client_mw.call("UniqueJob", payload, "default", nil) { :ok } }

      assert_empty pool.recorders
      refute payload.key?("unique_digest")
    end
    refute Robin::Unique.locked?("UniqueJob", [3])
    pool = recording_pool { assert_equal %w[j0], Robin::Client.new.push_bulk("class" => UniqueJob, "args" => [[3]], "unique_for" => 0, "jids" => %w[j0]) }

    assert_equal [:pipelined], pool.calls.map(&:first).uniq - [:pipe]
    assert_equal 1, pool.recorders.size
    refute Robin::Unique.locked?("UniqueJob", [3])
  end

  def test_client_middleware_releases_when_later_middleware_halts
    payload = {"args" => [6], "jid" => "a", "unique_for" => 60}

    assert_nil client_mw.call("UniqueJob", payload, "default", nil) { nil }
    refute Robin::Unique.locked?("UniqueJob", [6])
  end

  def test_client_middleware_logs_suppressed_duplicates
    log = StringIO.new
    config.logger = Logger.new(log, level: Logger::DEBUG)
    client_mw.call("UniqueJob", {"args" => [7], "jid" => "a", "unique_for" => 60}, "default", nil) { :ok }
    client_mw.call("UniqueJob", {"args" => [7], "jid" => "b", "unique_for" => 60}, "default", nil) { :ok }

    assert_includes log.string, "suppressed duplicate UniqueJob [7]; locked by a\n"
  end

  def test_through_the_client
    jid = assert_roundtrips(2) { UniqueJob.perform_async(1) } # the lock, then the push

    assert jid
    assert_nil assert_roundtrips(1) { UniqueJob.perform_async(1) }
    assert UniqueJob.perform_async(2)
    assert UniqueJob.set(queue: "other").perform_async(1)
    assert_equal 3, Robin::Stats.new.enqueued
    assert UniqueJob.perform_async({"a" => 1, "b" => 2})
    assert_nil UniqueJob.perform_async({"b" => 2, "a" => 1})
  end

  def locked_payload(args, **extra)
    payload = {"args" => args, "jid" => "j1", "unique_for" => 60}.merge(extra.transform_keys(&:to_s))
    client_mw.call("UniqueJob", payload, "default", nil) { :ok }
    payload
  end

  # -- push_bulk takes its jobs' locks together -----------------------------------

  def bulk(args, jids: nil, client: Robin::Client.new)
    client.push_bulk("class" => UniqueJob, "args" => args, "jids" => jids || args.each_index.map { |i| "j#{i}" })
  end

  # A middleware after Unique's that runs +action+ for the job with jid
  # +jid+.
  def on_jid(jid, &action)
    config.client_middleware.add(Class.new do
      define_method(:call) { |_c, payload, _q, _r, &blk| (payload["jid"] == jid) ? action.call : blk.call }
    end)
  end

  def test_push_bulk_takes_the_locks_in_one_round_trip
    redis("SET", Robin::Unique.lock_key(config, Robin::Unique.digest("UniqueJob", "default", [4])), "other")
    jids = nil
    pool = recording_pool { jids = bulk([[1], [2], [1], [3], [4]]) }

    assert_equal ["j0", "j1", nil, "j3", nil], jids
    # The second [1] tries in its turn, as it would have.
    assert_equal [[:pipelined, :pipe, :pipe, :pipe, :pipe], [:call], [:pipelined, :pipe, :pipe]],
      pool.calls.map(&:first).slice_before { |kind| kind != :pipe }.to_a
    assert_equal %w[j0 j1 j3 other], [[1], [2], [3], [4]].map { |args| lock_owner("UniqueJob", args) }
    assert_equal [[:pipe, "SET", Robin::Unique.lock_key(config, Robin::Unique.digest("UniqueJob", "default", [1])), "j0", "NX", "PXAT"]],
      [pool.calls.fetch(1).take(6)]
  end

  def test_push_bulk_with_a_lock_held_by_a_stopped_push_takes_it_in_turn
    on_jid("j0") { nil }

    assert_equal [nil, "j1"], bulk([[1], [1]])
    assert_equal "j1", lock_owner("UniqueJob", [1])
  end

  def test_push_bulk_that_raises_gives_back_the_locks_it_never_got_to
    on_jid("j1") { raise "boom" }

    redis("SET", Robin::Unique.lock_key(config, Robin::Unique.digest("UniqueJob", "default", [4])), "other")
    pool = recording_pool { assert_raises(RuntimeError) { bulk([[1], [2], [3], [4], [2]]) } }
    released = pool.calls.select { |c| c[1] == :evalsha }

    assert_equal [[:pipe, :evalsha, Robin::Scripts::RELEASE, [Robin::Unique.lock_key(config, Robin::Unique.digest("UniqueJob", "default", [3]))], ["j2"]]], released
    assert_equal ["j0", "j1", nil, "other"], [[1], [2], [3], [4]].map { |args| lock_owner("UniqueJob", args) }
    config.strict_args = true

    assert_raises(Robin::Client::ArgumentError) { bulk([[5], [:sym], [6]]) }
    assert_equal ["j0", nil, nil], [[5], [:sym], [6]].map { |args| lock_owner("UniqueJob", args) }
  end

  def test_push_bulk_takes_locks_in_turn_when_unique_isnt_the_first_middleware
    config.client_middleware.prepend(Class.new { def call(*) = yield })
    pool = recording_pool { assert_equal %w[j0 j1], bulk([[1], [2]]) }

    assert_equal [:call, :call, :pipelined], pool.calls.map(&:first).reject { |kind| kind == :pipe }
  end

  def test_push_bulk_without_unique_jobs_takes_no_locks
    pool = recording_pool { Robin::Client.new.push_bulk("class" => "Plain", "args" => [[1]]) }
    chain = Robin::Middleware::Chain.new(config)
    other = recording_pool { bulk([[1]], client: Robin::Client.new(chain: chain)) }

    assert_equal [[:pipelined], [:pipelined]], [pool, other].map { |p| p.calls.map(&:first) - [:pipe] }
    assert_equal [1, 1], [pool.recorders.size, other.recorders.size]
    assert_nil lock_owner("UniqueJob", [1])
    # (An empty pipeline: nothing goes out.)
    assert_equal [[:pipelined]], recording_pool { assert_empty bulk([]) }.calls
  end

  def test_claiming_holds_its_claims_only_while_the_bulk_push_runs
    claims = Robin::Unique::CLAIMS
    outer = Thread.current[claims] = {}.compare_by_identity
    job = {"class" => "UniqueJob", "args" => [1], "queue" => "default", "jid" => "j", "unique_for" => 60}
    inside = Robin::Unique.claiming(config.client_middleware, [job]) { Thread.current[claims] }

    assert_equal [job], inside.keys
    assert_same outer, Thread.current[claims]
    assert_nil lock_owner("UniqueJob", [1]), "given back: the job wasn't pushed"
    [[{}], []].each do |payloads|
      assert_same outer, Robin::Unique.claiming(config.client_middleware, payloads) { Thread.current[claims] }
    end
  ensure
    Thread.current[claims] = nil
  end

  def test_push_bulk_skips_jobs_already_locked
    pool = recording_pool { bulk([[1]]).then { |jids| assert_equal ["j0"], jids } }
    digest = Robin::Unique.digest("UniqueJob", "default", [1])
    locked = {"class" => "UniqueJob", "args" => [1], "queue" => "default", "jid" => "x", "unique_for" => 60, "unique_digest" => digest}
    fresh = locked.merge("args" => [2], "jid" => "y").except("unique_digest")
    claims = Robin::Unique::ClientMiddleware.new.tap { |m| m.config = config }.claim_all([locked, {}, fresh])

    assert_equal [fresh], claims.keys
    assert_equal "y", lock_owner("UniqueJob", [2])
    assert_equal 2, pool.calls.count { |c| c[0] == :pipelined }
  end

  def test_server_middleware_without_digest
    assert_equal :ran, server_mw.call(nil, {"jid" => "x"}, "default") { :ran }
  end

  def test_server_middleware_releases_after_success
    payload = locked_payload([1])
    ran = assert_roundtrips(2) do # the check below, and the release
      server_mw.call(nil, payload, "default") {
        assert Robin::Unique.locked?("UniqueJob", [1])
        :ran
      }
    end

    assert_equal :ran, ran
    refute Robin::Unique.locked?("UniqueJob", [1])
  end

  def test_server_middleware_until_start
    payload = locked_payload([1], unique_until: "start")

    assert_equal :ran, server_mw.call(nil, payload, "default") {
      refute Robin::Unique.locked?("UniqueJob", [1])
      :ran
    }
    payload = locked_payload([2], unique_until: :start)

    server_mw.call(nil, payload, "default") { refute Robin::Unique.locked?("UniqueJob", [2]) }
  end

  # The lock went before the job ran, so nothing is released afterwards:
  # one round trip per job, whatever the outcome.
  def test_server_middleware_until_start_releases_once
    key = Robin::Unique.lock_key(config, Robin::Unique.digest("UniqueJob", "default", [1]))
    release = [:evalsha, Robin::Scripts::RELEASE, [key], ["j1"]]
    [-> { :ran }, -> { raise Robin::Discard }, -> { raise "boom" }].each do |outcome|
      payload = locked_payload([1], unique_until: :start)
      pool = recording_pool do
        server_mw.call(nil, payload, "default", &outcome)
      rescue Robin::Discard, RuntimeError
        nil
      end

      assert_equal [release], pool.calls
      refute Robin::Unique.locked?("UniqueJob", [1])
    end
  end

  def test_server_middleware_keeps_lock_for_iteration_interrupted_jobs
    payload = locked_payload([1])
    server_mw.call(nil, payload, "default") { payload["iteration_interrupted"] = true }

    assert Robin::Unique.locked?("UniqueJob", [1])
    payload = locked_payload([2])
    server_mw.call(nil, payload, "default") { payload["iteration_interrupted"] = false }

    refute Robin::Unique.locked?("UniqueJob", [2])
  end

  def test_server_middleware_keeps_lock_when_rate_limited
    payload = locked_payload([1])
    over = Robin::Limiter::OverLimit.new(Robin::Limiter.concurrent("u", 1, config: config))

    assert_raises(Robin::Limiter::OverLimit) { server_mw.call(nil, payload, "default") { raise over } }
    assert Robin::Unique.locked?("UniqueJob", [1])
    payload["failures"] = config.max_retries # even when the next failure would be final

    assert_raises(Robin::Limiter::OverLimit) { server_mw.call(nil, payload, "default") { raise over } }
    assert Robin::Unique.locked?("UniqueJob", [1])
  end

  def test_server_middleware_releases_on_discard
    payload = locked_payload([1])

    assert_raises(Robin::Discard) { server_mw.call(nil, payload, "default") { raise Robin::Discard } }
    refute Robin::Unique.locked?("UniqueJob", [1])
  end

  def test_server_middleware_keeps_the_lock_on_failure
    # The retrier releases it once the job won't run again.
    payload = locked_payload([1], retry: false, failures: config.max_retries)

    assert_raises(RuntimeError) { server_mw.call(nil, payload, "default") { raise "boom" } }
    assert Robin::Unique.locked?("UniqueJob", [1])
  end

  def test_server_middleware_keeps_lock_on_shutdown
    Robin.const_get(:Processor) # loads processor.rb, which defines Robin::Shutdown
    payload = locked_payload([1], retry: false)

    assert_raises(Robin::Shutdown) { server_mw.call(nil, payload, "default") { raise Robin::Shutdown } }
    assert Robin::Unique.locked?("UniqueJob", [1])
  end

  def test_lock_owned_by_other_jid_is_kept
    payload = locked_payload([5])
    server_mw.call(nil, payload.merge("jid" => "someone-else"), "default") { :ok }

    assert Robin::Unique.locked?("UniqueJob", [5])
  end

  def test_scheduled_lock_covers_wait
    UniqueJob.perform_in(3600, 9)

    assert_operator lock_ttl("UniqueJob", [9]), :>, 3_600_000
  end

  def test_custom_unique_args
    assert UniqueByFirstArg.perform_async(1, "x")
    assert_nil UniqueByFirstArg.perform_async(1, "y")
  end

  def test_client_middleware_only_applies_to_lockable_jobs
    middleware = Robin::Unique::ClientMiddleware

    assert_true middleware.applies?(nil, {"unique_for" => 60}, "q", nil)
    refute middleware.applies?(nil, {"unique_for" => 60, "unique_digest" => "d"}, "q", nil)
    refute middleware.applies?(nil, {"jid" => "j"}, "q", nil)
  end

  def test_server_middleware_only_applies_to_unique_jobs
    middleware = Robin::Unique::ServerMiddleware

    assert_true middleware.applies?(nil, {"unique_digest" => 1}, "q")
    assert_false middleware.applies?(nil, {"jid" => "j"}, "q")
  end
end

# End-to-end; left out of mutant's selection (needs a server).
class UniqueIntegrationTest < RobinTest
  def test_end_to_end
    config.heartbeat_interval = 0.2
    Robin.server!
    launcher = Robin::Launcher.new(config).run
    UniqueJob.perform_async(42)
    eventually { !Robin::Unique.locked?("UniqueJob", [42]) }

    assert UniqueJob.perform_async(42)
    UniqueStartJob.perform_async(1)
    eventually { !Robin::Unique.locked?("UniqueStartJob", [1]) }
  ensure
    launcher&.stop
  end
end
