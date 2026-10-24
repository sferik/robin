# frozen_string_literal: true

require_relative "test_helper"
require "robin/testing"
require_relative "support/lock_assertions"

# The whole suite shares one process: keep real Redis for every other test.
Robin::Testing.disable!

module TestingTest
  CALLS = []

  class Adder
    include Robin::Job

    def perform(a, b)
      CALLS << a + b
      Chained.perform_async(a) if a == 1
      a + b
    end
  end

  class Chained
    include Robin::Job

    robin_options queue: "other"
    def perform(x) = CALLS << [:chained, x]
  end

  # Not a Robin::Job: no jid= / payload= accessors.
  class Plain
    def perform(x) = CALLS << [:plain, x]
  end

  class Seen
    def initialize(log) = @log = log

    def call(job, payload, queue)
      @log << [job.class, payload["jid"], queue]
      yield
    end
  end
end

# A top-level job whose name collides with a constant inside
# Robin::Testing: job class names must resolve from the top level.
class JobMethods
  def perform = TestingTest::CALLS << :top_level
end

class TestingModeTest < Minitest::Test
  include TestingTest
  include LockAssertions

  cover "Robin::Testing*"

  def setup
    Robin.config = Robin::Config.new
    Robin.config.logger = Logger.new(nil)
    Robin.config.redis = {url: "redis://127.0.0.1:1/0", connect_timeout: 0.1} # unreachable on purpose
    Robin::Testing.fake!
    Robin::Testing.clear_all
    CALLS.clear
  end

  def teardown
    Robin::Testing.disable!
  end

  def push(*payloads) = Robin::Testing.push(payloads)

  def test_intercept_routes_pushes_by_mode
    payload = {"class" => "TestingTest::Adder", "queue" => "default", "args" => [1, 2], "jid" => "j1"}

    payloads = [payload]

    assert_same payloads, Robin::Client.interceptor.call(payloads)
    assert_equal ["j1"], Robin::Testing.jobs.map { |j| j.fetch("jid") }
    Robin::Testing.disable!

    assert_nil Robin::Client.interceptor.call([payload.merge("jid" => "j2")])
    assert_equal ["j1"], Robin::Testing.jobs.map { |j| j.fetch("jid") }
  end

  def test_modes
    assert_nil Robin::Testing.fake!
    assert_equal :fake, Robin::Testing.mode
    assert_predicate Robin::Testing, :fake?
    refute_predicate Robin::Testing, :inline?
    refute_predicate Robin::Testing, :disabled?
    Robin::Testing.inline!

    assert_equal :inline, Robin::Testing.mode
    assert_predicate Robin::Testing, :inline?
    refute_predicate Robin::Testing, :fake?
    Robin::Testing.disable!

    assert_equal :disable, Robin::Testing.mode
    assert_predicate Robin::Testing, :disabled?
    refute_predicate Robin::Testing, :fake?
  end

  def test_block_forms_restore_previous_mode
    assert_equal :r, Robin::Testing.inline! { :r }
    assert_predicate Robin::Testing, :fake?
    Robin::Testing.disable! do
      Robin::Testing.fake! { assert_predicate Robin::Testing, :fake? }

      assert_predicate Robin::Testing, :disabled?
    end
    assert_raises(RuntimeError) { Robin::Testing.inline! { raise "x" } }
    assert_predicate Robin::Testing, :fake?
  end

  def test_block_forms_only_affect_the_current_thread
    other = nil
    Robin::Testing.inline! do
      other = Thread.new { Robin::Testing.mode }.value

      assert_equal :inline, Robin::Testing.mode
      # The default can still change underneath (for other threads).
      Robin::Testing.disable!

      assert_equal :inline, Robin::Testing.mode
      assert_equal :disable, Thread.new { Robin::Testing.mode }.value
    end

    assert_equal :fake, other
    assert_equal :disable, Robin::Testing.mode
    assert_nil Thread.current[Robin::Testing::MODE_KEY]
  end

  def test_fake_mode_collects_jobs
    jid = Adder.perform_async(2, 3)

    assert_equal 1, Adder.jobs.size
    assert_equal jid, Adder.jobs.first["jid"]
    assert_equal [2, 3], Adder.jobs.first["args"]
    assert_kind_of Integer, Adder.jobs.first["enqueued_at"]
    Adder.perform_in(60, 1, 1)

    refute Adder.jobs.last.key?("enqueued_at")
    Chained.perform_async(9)

    assert_equal 3, Robin::Testing.jobs.size
    assert_equal %w[default other], Robin::Testing.queues.keys
    assert_equal [9], Chained.jobs.map { |j| j["args"].first }
    Adder.clear

    assert_empty Adder.jobs
    assert_equal 1, Chained.jobs.size
    Robin::Testing.clear_all

    assert_empty Robin::Testing.jobs
  end

  def test_push_round_trips_through_json_and_keeps_enqueued_at
    push({"class" => "X", "queue" => "q", "args" => [{"a" => 1.5}], "enqueued_at" => 7, "jid" => "j"})
    job = Robin::Testing.jobs.first

    assert_equal 7, job["enqueued_at"]
    assert_equal [{"a" => 1.5}], job["args"]
    original = {"class" => "X", "queue" => "q", "args" => ["s"], "jid" => "k"}
    push(original)

    refute original.key?("enqueued_at")
    refute_same original, Robin::Testing.jobs.last
  end

  def test_drain_runs_jobs_including_pushed_ones
    Adder.perform_async(1, 2)
    Adder.perform_async(5, 5)
    Adder.drain

    assert_equal [3, 10], CALLS
    assert_equal 1, Chained.jobs.size
    Robin::Testing.drain_all

    assert_equal [3, 10, [:chained, 1]], CALLS
    assert_empty Robin::Testing.jobs
  end

  def test_jobs_with_nil_at_get_enqueued_at
    push({"class" => "X", "queue" => "q", "args" => [], "at" => nil, "jid" => "n"})

    assert_kind_of Integer, Robin::Testing.jobs.first["enqueued_at"]
  end

  def undated(queue, tag) = Robin::Testing.queues[queue] << {"class" => "TestingTest::Plain", "queue" => queue, "args" => [tag], "jid" => tag}

  def dated(queue, tag, at) = Robin::Testing.queues[queue] << {"class" => "TestingTest::Plain", "queue" => queue, "args" => [tag], "jid" => tag, "enqueued_at" => at}

  def test_undated_jobs_sort_as_time_zero
    dated("a", "one", 1)
    undated("b", "undated")
    Robin::Testing.drain_all

    assert_equal [[:plain, "undated"], [:plain, "one"]], CALLS
    CALLS.clear
    undated("a", "undated")
    dated("b", "negative", -1)
    Robin::Testing.drain_all

    assert_equal [[:plain, "negative"], [:plain, "undated"]], CALLS
  end

  def test_job_classes_resolve_from_the_top_level
    Robin::Testing.execute({"class" => "JobMethods", "args" => [], "jid" => "t"})

    assert_equal [:top_level], CALLS
  end

  def test_disabled_mode_pushes_only_to_redis
    Robin.config.redis = {url: REDIS_URL}
    Robin.config.key_prefix = "robintest:#{Process.pid}:testing:"
    Robin::Testing.disable! { Adder.perform_async(1, 1) }

    assert_empty Robin::Testing.jobs
    assert_equal 1, Robin::Queue.new("default").size
  ensure
    Robin::Queue.new("default").clear
    Robin.config.redis_pool.shutdown
  end

  def test_shared_state_is_locked
    lock = Robin::Testing.instance_variable_get(:@mutex)
    Adder.perform_async(1, 2)

    assert_equal 1, assert_waits_for(lock) { Robin::Testing.jobs.size }
    assert_equal 1, assert_waits_for(lock) { Robin::Testing.jobs_for("TestingTest::Adder").size }
    assert_waits_for(lock) { push({"class" => "X", "queue" => "q", "args" => [], "jid" => "x"}) }
    assert_waits_for(lock) { Robin::Testing.clear("X") }
    push({"class" => "TestingTest::Plain", "queue" => "q", "args" => [1], "jid" => "p"})
    assert_waits_for(lock) { Robin::Testing.perform_one("TestingTest::Plain") }
    assert_waits_for(lock) { Robin::Testing.clear_all }

    assert_empty Robin::Testing.jobs
  end

  def test_drain_order_uses_enqueued_at_then_at
    push({"class" => "TestingTest::Plain", "queue" => "b", "args" => [:late], "enqueued_at" => 30, "jid" => "1"},
      {"class" => "TestingTest::Plain", "queue" => "a", "args" => [:scheduled], "at" => 0.02, "jid" => "2"},
      {"class" => "TestingTest::Plain", "queue" => "b", "args" => [:early], "enqueued_at" => 10, "jid" => "3"})
    Robin::Testing.queues["c"] << {"class" => "TestingTest::Plain", "queue" => "c", "args" => ["undated"], "jid" => "4"}
    Robin::Testing.drain_all

    assert_equal [[:plain, "undated"], [:plain, "early"], [:plain, "scheduled"], [:plain, "late"]], CALLS
  end

  def test_perform_one
    Adder.perform_async(2, 2)
    Chained.perform_async(1)

    assert_equal 4, Adder.perform_one
    assert_equal [4], CALLS
    error = assert_raises(Robin::Testing::EmptyQueue) { Adder.perform_one }
    assert_equal "no TestingTest::Adder jobs to perform", error.message
    assert_equal 1, Chained.jobs.size
  end

  def test_inline_mode_runs_immediately
    Robin::Testing.inline! do
      Adder.perform_async(1, 2)

      assert_predicate Robin::Testing, :inline?
    end
    assert_predicate Robin::Testing, :fake?
    assert_equal [3, [:chained, 1]], CALLS
    assert_empty Robin::Testing.jobs
  end

  def test_execute_runs_server_middleware_with_given_config
    log = []
    custom = Robin::Config.new
    custom.server_middleware { |c| c.add Seen, log }
    payload = {"class" => "TestingTest::Adder", "args" => [4, 4], "jid" => "abc", "queue" => "q"}

    assert_equal 8, Robin::Testing.execute(payload, config: custom)
    assert_equal [[TestingTest::Adder, "abc", "q"]], log
    Robin.config.server_middleware { |c| c.add Seen, log }
    Robin::Testing.execute(payload)

    assert_equal 2, log.size
  end

  def test_execute_sets_jid_and_payload
    seen = nil
    klass = Class.new do
      include Robin::Job

      define_method(:perform) { seen = [jid, payload["k"]] }
    end
    TestingTest.const_set(:Introspect, klass) unless TestingTest.const_defined?(:Introspect)
    Robin::Testing.execute({"class" => "TestingTest::Introspect", "args" => [], "jid" => "J", "k" => "v"})

    assert_equal %w[J v], seen
  end

  def test_execute_plain_classes
    Robin::Testing.execute({"class" => "TestingTest::Plain", "args" => [1], "jid" => "p"})

    assert_equal [[:plain, 1]], CALLS
  end

  def test_client_middleware_still_runs
    mw = Class.new do
      def call(_k, payload, _q, _r)
        payload["tagged"] = true
        yield
      end
    end
    Robin.config.client_middleware { |c| c.add mw }
    Adder.perform_async(1, 1)

    assert Adder.jobs.first["tagged"]
  end

  def test_disable_uses_redis
    Robin::Testing.disable! do
      assert_raises(Robin::Redis::ConnectionError) { Adder.perform_async(1, 1) }
    end
  end
end
