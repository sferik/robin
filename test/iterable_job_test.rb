# frozen_string_literal: true

require_relative "test_helper"
require "robin/iterable_job"

module IterTest
  SEEN = Queue.new

  class Walk
    include Robin::IterableJob

    def build_enumerator(count, cursor:)
      array_enumerator((0...count).to_a, cursor: cursor)
    end

    def each_iteration(n, _count)
      SEEN << n
      sleep 0.01
    end

    def on_complete = SEEN << :complete
  end
end

class IterableJobTest < RobinTest
  include IterTest

  def setup
    super
    SEEN.clear
    config.poll_interval = 0.1
    config.heartbeat_interval = 0.2
  end

  def drain_seen
    out = []
    out << SEEN.pop until SEEN.empty?
    out
  end

  def test_runs_all_items_inline
    Walk.perform_inline(5)

    assert_equal [0, 1, 2, 3, 4, :complete], drain_seen
  end

  def test_array_enumerator_resumes_after_cursor
    job = Walk.new

    assert_equal [[3, 3], [4, 4]], job.array_enumerator([0, 1, 2, 3, 4], cursor: 2).to_a
    assert_equal 2, job.array_enumerator([0, 1, 2, 3, 4], cursor: 2).size
  end

  def test_interrupted_job_checkpoints_and_resumes
    config.timeout = 5
    Robin.server!
    config.concurrency = 1
    launcher = Robin::Launcher.new(config)
    jid = Walk.perform_async(300)
    launcher.run
    eventually { SEEN.size > 20 }
    launcher.stop
    first = drain_seen

    refute_includes first, :complete
    state = redis("HGETALL", "#{key_prefix_for_test}iter:#{jid}").each_slice(2).to_h

    assert_equal first.size, state["iterations"].to_i
    requeued = Robin::Queue.new("default").first

    assert_equal jid, requeued.jid

    launcher = Robin::Launcher.new(config)
    launcher.run
    eventually(timeout: 10) { first.concat(drain_seen).include?(:complete) }
    launcher.stop
    numbers = first - [:complete]

    assert_equal (0...300).to_a, numbers
    assert_equal 0, redis("EXISTS", "#{key_prefix_for_test}iter:#{jid}")
  end

  def test_cancellation_stops_iteration
    job = Walk.new
    job.jid = "cancel-me"
    job.payload = {"jid" => "cancel-me", "queue" => "default", "args" => [1000]}
    Robin.cancel!("cancel-me")
    with_constant(Robin::IterableJob, :CHECKPOINT_SECONDS, 0.5) do
      t = Thread.new { job.perform(1000) }

      assert t.join(5), "still running" # stops at the first checkpoint
    end
    seen = drain_seen

    refute_includes seen, :complete
    assert_operator seen.size, :<, 1000
  end
end
