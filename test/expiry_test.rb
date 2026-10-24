# frozen_string_literal: true

require_relative "test_helper"

class ExpiryTest < RobinTest
  class Expiring
    include Robin::Job

    robin_options expires_in: 0.05
    RAN = []
    def perform = RAN << jid
  end

  def test_payload_gets_expires_at
    Expiring.perform_async
    item = Robin::Queue.new("default").first.item

    assert_in_delta item["created_at"] + 50, item["expires_at"], 1
    jid = Expiring.set(expires_in: 3600).perform_async

    assert_operator(Robin::Queue.new("default").find_job(jid)["expires_at"], :>, Robin.now_ms + 3_000_000)
  end

  # A job scheduled further out than it may wait must still run when due.
  def test_scheduled_job_expires_counting_from_when_it_is_due
    jid = Expiring.set(expires_in: 1_800).perform_in(3_600)
    entry = Robin::ScheduledSet.new.find_job(jid)
    due = Robin.epoch_ms(entry.score)

    assert_in_delta Robin.now_ms + 3_600_000, due, 2_000
    assert_equal due + 1_800_000, entry["expires_at"]
    assert_equal 1, Robin::Scheduler.new(config).enqueue_due(due)
    payload = Robin::Queue.new("default").first.item

    assert_equal [jid, due], payload.values_at("jid", "enqueued_at")
    refute Robin::Expiry.expired?(payload, due)
    refute Robin::Expiry.expired?(payload, due + 1_800_000)
    assert Robin::Expiry.expired?(payload, due + 1_800_001)
  end

  def test_expired_jobs_are_skipped
    Robin.server!
    config.concurrency = 1
    config.heartbeat_interval = 0.2
    Expiring::RAN.clear
    Expiring.perform_async
    fresh = Expiring.set(expires_in: 60).perform_async
    sleep 0.1
    launcher = Robin::Launcher.new(config).run
    eventually { Robin::Queue.new("default").size == 0 && Expiring::RAN.any? }
    sleep 0.1
    launcher.stop

    assert_equal [fresh], Expiring::RAN
    assert_equal 0, Robin::RetrySet.new.size
  end

  def test_expired_batch_job_counts_as_done
    b = Robin::Batch.new
    b.jobs { Expiring.perform_async }
    sleep 0.1
    payload = Robin::Queue.new("default").first.item
    mw = Robin::Expiry::ServerMiddleware.new
    mw.config = config
    ran = false
    mw.call(nil, payload, "default") { ran = true }

    refute ran
    assert_predicate b.status, :success?
  end
end
