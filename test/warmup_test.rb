# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class WarmupTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Warmup*"

  class AppClientMiddleware
    def call(*) = raise("the app's client middleware ran")
  end

  class AppServerMiddleware
    def call(*) = raise("the app's server middleware ran")
  end

  # Middleware of Robin's own (by name, once named Robin::...) that
  # records what it's called with.
  class Spy
    def self.calls = (@calls ||= [])

    def call(*args)
      Spy.calls << args
      yield
    end
  end

  def test_defaults
    assert_equal 500, Robin::Warmup::ROUNDS
    assert_equal 100, Robin::Warmup::JOBS
    assert_equal [1, "two", {"three" => 3.0, "four" => [4]}], Robin::Warmup::ARGS
    assert_predicate Robin::Warmup::ARGS, :frozen?
  end

  def test_the_connection_answers_every_command_without_redis
    conn = Robin::Warmup::Connection.new(":1\r\n")

    assert_equal [1, 1], conn.pipelined { |p| 2.times { p.call("LPUSH", "q", "x") } }
    assert_equal 1, conn.call("DEL", "x")
    assert_equal %w[a b], Robin::Warmup::Connection.new("*2\r\n$1\r\na\r\n$1\r\nb\r\n").call("BLMOVE")
  end

  def test_the_connection_encodes_what_it_would_send
    conn = Robin::Warmup::Connection.new(":1\r\n")
    encoded = []
    conn.define_singleton_method(:encode) { |commands| encoded << commands && super(commands) }
    conn.call("DEL", "x")

    assert_equal [[["DEL", "x"]]], encoded
  end

  def test_the_pool_lends_its_one_connection
    pool = Robin::Warmup::Pool.new(:conn)

    assert_equal :conn, pool.with { |c| c }
  end

  def test_own_keeps_only_robins_middleware
    anonymous = Class.new(Spy)
    chain = Robin::Middleware::Chain.new(config)
    chain.add(Robin::Unique::ClientMiddleware)
    chain.add(AppClientMiddleware)
    chain.add(anonymous)
    chain.add(Robin::Batch::ClientMiddleware)
    own = Robin::Warmup.own(chain)

    assert_equal [Robin::Unique::ClientMiddleware, Robin::Batch::ClientMiddleware], own.map(&:klass)
    assert_equal [Robin::Unique::ClientMiddleware, AppClientMiddleware, anonymous, Robin::Batch::ClientMiddleware], chain.map(&:klass),
      "the app's chain is left alone"
  end

  # What a payload the warmup pushed says, leaving out what differs every
  # time.
  def gist(json) = JSON.parse(json).slice("class", "args", "queue", "retry")

  def test_run_pushes_fetches_and_runs_without_redis_or_the_apps_middleware
    Robin.const_set(:WarmupSpy, Class.new(Spy))
    Spy.calls.clear
    warm = Robin::Config.new # on a config of its own, never connected
    warm.key_prefix = "warm:"
    warm.client_middleware.add(AppClientMiddleware)
    warm.client_middleware.add(Robin::WarmupSpy)
    warm.server_middleware.add(AppServerMiddleware)
    warm.server_middleware.add(Robin::WarmupSpy)
    warm.redis_pool = Object.new # nothing to talk to Redis with
    sent = []
    stub_method(Robin::Redis::ENCODER, :encode, ->(cmd, out) { (sent << cmd.dup) && __robin_stubbed_encode(cmd, out) }) do
      Robin::Warmup.run(warm, rounds: 2)
    end
    gist = {"class" => "Robin::Warmup", "args" => [1, "two", {"three" => 3.0, "four" => [4]}], "queue" => "default", "retry" => true}
    queue = ["SADD", "warm:queues", "default"]
    round = [queue, ["LPUSH", "warm:queue:default", *[gist] * 100], *[queue, ["LPUSH", "warm:queue:default", gist]] * 100,
      *[["BLMOVE", "queue", "inflight", "RIGHT", "LEFT", 2], ["DEL", "inflight"]] * 100]

    assert_equal round * 2, sent.map { |cmd| (cmd[0] == "LPUSH") ? [*cmd.first(2), *cmd.drop(2).map { gist(it) }] : cmd }
    jids = sent.select { |cmd| cmd[0] == "LPUSH" }.flat_map { |cmd| cmd.drop(2).map { JSON.parse(it).fetch("jid") } }

    assert_equal 400, jids.uniq.size, "every job its own jid"
    client, server = Spy.calls.partition { |args| args.size == 4 }

    assert_equal 400, client.size
    assert_equal [["Robin::Warmup", gist, "default"]] * 400, client.map { |klass, payload, q, _| [klass, payload.slice(*gist.keys), q] }
    assert_equal [Robin::Warmup::Pool], client.map { |*, redis| redis.class }.uniq
    assert_instance_of Robin::Warmup::Connection, client.first.last.connection
    assert_equal [[nil, gist, "default"]] * 200, server.map { |job, payload, q| [job, payload.slice(*gist.keys), q] }
  ensure
    Robin.send(:remove_const, :WarmupSpy)
  end

  def test_run_does_rounds_rounds
    rounds = 0
    stub_method(Robin::Warmup, :push_bulk, ->(*) { rounds += 1 }) do
      stub_method(Robin::Warmup, :push, ->(*) {}) do
        stub_method(Robin::Warmup, :fetch_and_run, ->(*) {}) { Robin::Warmup.run(config) }
      end
    end

    assert_equal 500, rounds
  end
end
