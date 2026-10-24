# frozen_string_literal: true

require_relative "test_helper"

class TickJob
  include Robin::Job

  robin_options queue: "cron"
  def perform(*) = nil
end

class PeriodicTest < RobinTest
  def registry
    reg = Robin::Periodic::Registry.new
    @id = reg.register("* * * * * *", TickJob, args: [1], tz: "UTC", description: "tick")
    reg.entries
  end

  def armed!(entries, at)
    entries.each_key { |id| redis("HSET", "#{key_prefix_for_test}periodic:armed", id, at) }
    entries.each { |id, e| redis("HSET", "#{key_prefix_for_test}periodic", id, JSON.generate(e)) }
  end

  def test_tick_enqueues_exactly_once_under_contention
    entries = registry
    crons = entries.to_h { |id, e| [id, Robin::Cron.new(e["cron"], tz: e["tz"])] }
    armed!(entries, Robin.now_ms - 60_000)
    now = Time.at(Time.now.to_i + 0.5)
    results = Array.new(8) { Thread.new { Robin::Periodic.tick(config, entries, crons, now) } }.flat_map(&:value)

    assert_equal 1, results.size
    assert_equal 1, Robin::Queue.new("cron").size
    job = Robin::Queue.new("cron").first

    assert_equal [1], job.args
    assert_equal @id, job["periodic"]
  end

  def test_ticks_before_registration_are_skipped
    entries = registry
    crons = entries.to_h { |id, e| [id, Robin::Cron.new(e["cron"], tz: e["tz"])] }
    armed!(entries, Robin.now_ms + 10_000)

    assert_empty Robin::Periodic.tick(config, entries, crons)
  end

  def test_list_history_pause_enqueue_now
    entries = registry
    armed!(entries, Robin.now_ms)
    list = Robin::Periodic.list

    assert_equal 1, list.size
    row = list.first

    assert_equal %w[args armed_at class cron description id last_at last_jid next_at paused queue tz], row.keys.sort
    assert_equal "TickJob", row["class"]
    assert_equal "tick", row["description"]
    refute row["paused"]
    jid = Robin::Periodic.enqueue_now(@id)

    assert_equal jid, Robin::Periodic.history(@id).first["jid"]
    assert_equal jid, assert_roundtrips(2) { Robin::Periodic.list }.first["last_jid"]
    second = Robin::Periodic.enqueue_now(@id)
    detailed = assert_roundtrips(2) { Robin::Periodic.list(history: 1) }.first

    assert_equal [second], detailed.fetch("history").map { |run| run["jid"] }
    assert_equal({}, detailed.fetch("options"))
    assert_equal (row.keys + %w[history options]).sort, detailed.keys.sort
    Robin::Periodic.pause!(@id)

    assert Robin::Periodic.list.first["paused"]
    crons = entries.to_h { |id, e| [id, Robin::Cron.new(e["cron"], tz: e["tz"])] }

    assert_empty Robin::Periodic.tick(config, entries, crons, Time.now + 5)
    Robin::Periodic.unpause!(@id)

    refute Robin::Periodic.list.first["paused"]
  end

  def test_two_launchers_enqueue_each_tick_once
    config.heartbeat_interval = 0.2
    config.poll_interval = 100
    config.queues = ["unused"]
    config.concurrency = 1
    config.periodic { |cron| cron.register("* * * * * *", "TickJob", description: "every second") }
    Robin.server!
    a = Robin::Launcher.new(config).run
    b = Robin::Launcher.new(config).run
    sleep 3.2
    a.stop
    b.stop
    jobs = Robin::Queue.new("cron").to_a
    id = Robin::Periodic.list.first["id"]
    history = Robin::Periodic.history(id, limit: 100)

    assert_operator jobs.size, :>=, 2
    assert_equal jobs.size, history.size
    assert_equal history.map { |h| h["at"] }.uniq.size, history.size
  end
end
