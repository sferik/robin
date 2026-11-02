# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/api"
require "delegate"

class StatsApiTest < RobinTest
  include ApiTestSupport

  cover "Robin::Stats*"

  def test_empty_cluster
    stats = assert_roundtrips(1) { Robin::Stats.new(config: alt_config) }

    assert_equal({"processed" => 0, "failed" => 0, "scheduled" => 0, "retries" => 0, "dead" => 0,
                  "processes" => 0, "busy" => 0, "enqueued" => 0, "default_latency" => 0.0}, stats.to_h)
    assert_equal({}, stats.queues)
  end

  def test_counts_sizes_and_processes
    alt("SET", alt_key("stat", "processed"), "7")
    alt("SET", alt_key("stat", "failed"), "2")
    alt("ZADD", alt_key("schedule"), 1, "a")
    alt("ZADD", alt_key("retry"), 1, "a", 2, "b")
    alt("ZADD", alt_key("dead"), 1, "a", 2, "b", 3, "c")
    push("default", job("1"), job("2"), job("3"))
    push("b", job("4"))
    push("a", job("5"))
    alt("SADD", alt_key("processes"), "p1", "p2", "gone")
    alt("HSET", alt_config.process_key("p1"), "busy", "3")
    alt("HSET", alt_config.process_key("p2"), "busy", "0")
    stats = assert_roundtrips(1) { Robin::Stats.new(config: alt_config) }

    assert_equal 7, stats.processed
    assert_equal 2, stats.failed
    assert_equal 1, stats.scheduled_size
    assert_equal 2, stats.retry_size
    assert_equal 3, stats.dead_size
    assert_equal [["default", 3], ["a", 1], ["b", 1]], stats.queues.to_a
    assert_equal 5, stats.enqueued
    assert_equal 2, stats.processes_size
    assert_equal 3, stats.workers_size
  end

  def test_default_queue_latency_uses_oldest_job
    now = Robin.now_ms
    push("default", job("old", enqueued_at: now - 4_000), job("mid", enqueued_at: now - 2_000), job("new", enqueued_at: now))

    assert_in_delta 4.0, Robin::Stats.new(config: alt_config).default_queue_latency, 0.5
  end

  def test_fetch_refreshes_and_returns_self
    stats = Robin::Stats.new(config: alt_config)
    alt("SET", alt_key("stat", "processed"), "3")

    assert_same stats, stats.fetch
    assert_equal 3, stats.processed
  end

  def test_defaults_to_global_config
    redis("SET", config.key("stat", "processed"), "4")

    assert_equal 4, Robin::Stats.new.processed
  end

  def test_history_uses_utc_days
    alt("SET", alt_key("stat", "processed", "2026-01-01"), "5")
    alt("SET", alt_key("stat", "failed", "2025-12-31"), "1")
    now = Time.new(2026, 1, 2, 0, 30, 0, "+05:00") # 2026-01-01 19:30 UTC
    history = Robin::Stats.new(config: alt_config).history(days: 2, now: now)

    assert_equal 18_000, now.utc_offset, "the caller's Time must not be converted"

    assert_equal({"processed" => {"2026-01-01" => 5, "2025-12-31" => 0},
                  "failed" => {"2026-01-01" => 0, "2025-12-31" => 1}}, history)
  end

  def test_history_steps_back_whole_days
    alt("SET", alt_key("stat", "processed", "2025-12-31"), "2")
    history = Robin::Stats.new(config: alt_config).history(days: 3, now: Time.utc(2026, 1, 2))

    assert_equal({"2026-01-02" => 0, "2026-01-01" => 0, "2025-12-31" => 2}, history["processed"])
  end

  def test_history_counts_back_from_the_end_of_a_day
    history = Robin::Stats.new(config: alt_config).history(days: 2, now: Time.utc(2026, 1, 2, 23, 59, 59))

    assert_equal %w[2026-01-02 2026-01-01], history["processed"].keys
  end

  def test_history_defaults
    alt("SET", alt_key("stat", "processed", Time.now.utc.strftime("%Y-%m-%d")), "9")
    history = Robin::Stats.new(config: alt_config).history

    assert_equal 30, history["processed"].size
    assert_equal 9, history["processed"].values.first
  end

  def test_reset
    %w[processed failed other].each { |n| alt("SET", alt_key("stat", n), "1") }
    stats = Robin::Stats.new(config: alt_config)
    stats.reset

    assert_equal [nil, nil, "1"], %w[processed failed other].map { |n| alt("GET", alt_key("stat", n)) }
    alt("SET", alt_key("stat", "processed"), "1")
    stats.reset("other")

    assert_equal ["1", nil, nil], %w[processed failed other].map { |n| alt("GET", alt_key("stat", n)) }
  end
end

class QueueApiTest < RobinTest
  include ApiTestSupport

  cover "Robin::Queue*"

  def queue(name = "default") = Robin::Queue.new(name, config: alt_config)

  def test_all_is_sorted_and_uses_config
    push("b", job("1"), job("2"))
    push("a", job("3"))

    assert_equal [%w[a 1], %w[b 2]], Robin::Queue.all(config: alt_config).map { |q| [q.name, q.size.to_s] }
    redis("SADD", config.key("queues"), "z")

    assert_equal ["z"], Robin::Queue.all.map(&:name)
  end

  def test_name_and_defaults
    assert_equal "critical", Robin::Queue.new(:critical).name
    assert_equal "default", Robin::Queue.new.name
    push("default", job("1"), config: config)

    assert_equal 1, Robin::Queue.new.size
  end

  def test_latency_of
    assert_in_delta(0.0, Robin::Queue.latency_of(nil, 10_000))
    assert_in_delta(0.0, Robin::Queue.latency_of("not json", 10_000))
    assert_in_delta(0.0, Robin::Queue.latency_of(Robin.dump_json({}), 10_000))
    assert_in_delta(1.5, Robin::Queue.latency_of(Robin.dump_json({"enqueued_at" => 8_500}), 10_000))
    assert_in_delta(0.5, Robin::Queue.latency_of(Robin.dump_json({"at" => 9.5}), 10_000))
    assert_in_delta(0.25, Robin::Queue.latency_of(Robin.dump_json({"enqueued_at" => 1_000, "at" => 9.75}), 10_000))
    assert_in_delta(0.25, Robin::Queue.latency_of(Robin.dump_json({"enqueued_at" => 9_750, "at" => 1.0}), 10_000))
    assert_in_delta(1.5, Robin::Queue.latency_of(Robin.dump_json({"enqueued_at" => 8.5}), 10_000))
    assert_in_delta(0.0, Robin::Queue.latency_of(Robin.dump_json({"enqueued_at" => 12_000}), 10_000))
    assert_in_delta 2.0, Robin::Queue.latency_of(Robin.dump_json({"enqueued_at" => Robin.now_ms - 2_000})), 0.5
  end

  def test_size_and_latency_use_the_oldest_job
    now = Robin.now_ms
    push("default", job("old", enqueued_at: now - 6_000), job("mid", enqueued_at: now - 3_000), job("new", enqueued_at: now - 1_000))

    assert_equal 3, queue.size
    assert_in_delta 6.0, queue.latency, 0.5
  end

  def test_pausing
    refute_predicate queue, :paused?
    queue.pause!

    assert_predicate queue, :paused?
    assert_equal ["default"], Robin::Queue.paused(config: alt_config)
    assert_empty Robin::Queue.paused
    queue.unpause!

    refute_predicate queue, :paused?
  end

  def test_each_runs_next_job_first_across_pages
    push("default", *Array.new(250) { |i| job(i.to_s, queue: "elsewhere") })

    # A round trip a page (with the queue's size), and one finding the end.
    assert_equal Array.new(250) { |i| i.to_s }, assert_roundtrips(4) { queue.each.map(&:jid) }
    assert(queue.all? { |j| j.queue == "default" })
    assert queue.first.delete
  end

  def test_deleting_while_iterating_visits_every_job
    push("default", *Array.new(250) { |i| job(i.to_s) })
    seen = queue.each.map { |j| j.delete && j.jid }

    assert_equal Array.new(250) { |i| i.to_s }, seen
    assert_equal 0, queue.size
  end

  def test_deleting_some_while_iterating_visits_every_job_once
    push("default", *Array.new(250) { |i| job(i.to_s) })
    seen = queue.each.map do |j|
      j.delete if j.jid.to_i.even?
      j.jid
    end

    assert_equal Array.new(250) { |i| i.to_s }, seen
    assert_equal 125, queue.size
  end

  def test_jobs_pushed_while_iterating_dont_cause_skips
    push("default", *Array.new(150) { |i| job(i.to_s) })
    seen = queue.each.map do |j|
      push("default", job("new-#{j.jid}")) if j.jid == "0" # lands at the head, behind us
      j.jid
    end

    assert_equal Array.new(150) { |i| i.to_s } + ["new-0"], seen
  end

  def test_unvisited_jobs_removed_by_others_while_iterating
    push("default", *Array.new(250) { |i| job(i.to_s) })
    seen = queue.each.map do |j|
      # Another client drops the 150 jobs nearest the tail, including 50 we haven't reached.
      alt("LTRIM", alt_key("queue", "default"), 0, 99) if j.jid == "0"
      j.jid
    end

    assert_equal Array.new(100) { |i| i.to_s } + Array.new(100) { |i| (150 + i).to_s }, seen
  end

  def test_a_queue_emptied_while_iterating_ends_cleanly
    push("default", *Array.new(150) { |i| job(i.to_s) })
    seen = queue.each.map do |j|
      alt("DEL", alt_key("queue", "default")) if j.jid == "0"
      j.jid
    end

    assert_equal Array.new(100) { |i| i.to_s }, seen
  end

  def test_each_with_exact_page_and_empty_queue
    push("default", *Array.new(100) { |i| job(i.to_s) })

    assert_equal 100, queue.count
    assert_empty queue("empty").to_a
  end

  def test_page
    push("default", *Array.new(30) { |i| job(i.to_s, queue: "elsewhere") })

    assert_equal %w[0 1], assert_roundtrips(1) { queue.page(1, per_page: 2).map(&:jid) }
    assert_equal %w[4 5], queue.page(3, per_page: 2).map(&:jid)
    assert_equal 25, queue.page(1).size
    assert_equal %w[25 26 27 28 29], queue.page(2).map(&:jid)
    assert_equal ["default"], queue.page(1, per_page: 1).map(&:queue)
    assert queue.page(1).first.delete
  end

  def test_find_job
    push("default", job("a"), job("b"))

    assert_equal "b", queue.find_job("b").jid
    assert_nil queue.find_job("zzz")
  end

  # Counts the searches #find_job sends to Redis.
  def counting_searches
    calls = []
    real = alt_config.method(:redis)
    alt_config.define_singleton_method(:redis) do |&blk|
      real.call do |conn|
        spy = SimpleDelegator.new(conn)
        spy.define_singleton_method(:evalsha) { |script, keys, argv| (calls << argv) && conn.evalsha(script, keys, argv) }
        blk.call(spy)
      end
    end
    yield
    calls
  ensure
    alt_config.singleton_class.remove_method(:redis)
  end

  def test_find_job_searches_slices_from_the_tail
    push("default", *%w[a b c d e].map { |j| job(j) })
    with_constant(Robin::Queue, :FIND_SLICE, 2) do
      found = nil
      calls = counting_searches { found = queue.find_job("a") }

      assert_equal [job("a"), "default", alt_config], [found.item, found.queue, found.instance_variable_get(:@config)]
      assert_equal [["a", -2, -1]], calls
      calls = counting_searches { found = queue.find_job("e") }

      assert_equal "e", found.jid
      assert_equal [["e", -2, -1], ["e", -4, -3], ["e", -6, -5]], calls
      assert_equal 3, counting_searches { assert_nil queue.find_job("zz") }.size
    end
    assert_equal 5_000, Robin::Queue::FIND_SLICE
  end

  def test_delete_by_class
    wrapped = job("w", class: "Robin::ActiveJob::Wrapper", display_class: "Mailer")
    odd = job("n", class: "Mailer", display_class: 7)
    push("default", job("a"), job("b", class: "Other", args: ["SomeJob"]), wrapped, job("c"), odd)
    alt("LPUSH", alt_key("queue", "default"), '"SomeJob"')
    alt("LPUSH", alt_key("queue", "default"), '{"class":"SomeJob"')

    assert_equal 2, queue.delete_by_class("SomeJob")
    assert_equal ['{"class":"SomeJob"', '"SomeJob"', Robin.dump_json(odd), Robin.dump_json(wrapped), Robin.dump_json(job("b", class: "Other", args: ["SomeJob"]))],
      alt("LRANGE", alt_key("queue", "default"), 0, -1)
    assert_equal 0, queue.delete_by_class("Robin::ActiveJob::Wrapper")
    assert_equal 2, queue.delete_by_class("Mailer")
    push("default", job("q", class: "Robin::Queue"))

    assert_equal 1, queue.delete_by_class(Robin::Queue)
    assert_equal 0, queue("empty").delete_by_class("Mailer")
    e = assert_raises(ArgumentError) { queue.delete_by_class("") }
    assert_equal "a class name is required", e.message
  end

  def test_delete_by_class_searches_slices_from_the_tail
    push("default", *%w[a b c d e].map { |j| job(j, class: (j == "c") ? "Keep" : "SomeJob") })
    with_constant(Robin::Queue, :FIND_SLICE, 2) do
      deleted = nil
      calls = counting_searches { deleted = queue.delete_by_class("SomeJob") }

      assert_equal 4, deleted
      assert_equal [["SomeJob", -2, -1], ["SomeJob", -2, -1], ["SomeJob", -3, -2]], calls
      assert_equal %w[c], queue.map(&:jid)
    end
  end

  # Once the jobs looked at reach the queue's length, it's done.
  def test_delete_by_class_stops_at_the_end_of_a_queue_a_slice_long
    push("default", job("a", class: "Keep"), job("b", class: "Keep"))

    with_constant(Robin::Queue, :FIND_SLICE, 2) do
      assert_equal 0, assert_roundtrips(1) { queue.delete_by_class("SomeJob") }
    end
  end

  def test_find_job_in_a_queue_that_fits_one_slice
    push("default", job("a"), job("b"))

    assert_equal 1, counting_searches { queue.find_job("zz") }.size
    with_constant(Robin::Queue, :FIND_SLICE, 2) do
      assert_equal 1, counting_searches { queue.find_job("zz") }.size
    end
  end

  def test_found_jobs_belong_to_the_queue_they_are_in
    push("moved", job("m", queue: "original"))

    assert_equal "moved", queue("moved").find_job("m").queue
  end

  def test_find_job_matches_the_jid_field_only
    push("default", job("x", args: ["a"]), job("y", other: "a"), job("a b"))
    alt("LPUSH", alt_key("queue", "default"), '"a"', 'not json "a"', '{"jid":"a"')

    assert_nil queue.find_job("a")
    alt("LPUSH", alt_key("queue", "default"), '{"class": "Spaced", "jid" : "s"}')

    assert_equal "Spaced", queue.find_job("s")["class"]
    assert_equal "a b", queue.find_job("a b").jid
  end

  def test_delete_jobs
    push("default", job("a"), job("b"), job("a"))
    a, b, = queue.to_a

    assert_equal 2, assert_roundtrips(1) { queue.delete_jobs([a, b]) }
    assert_equal %w[a], queue.map(&:jid), "one copy of each"
    assert_equal 0, assert_roundtrips(0) { queue.delete_jobs([]) }
  end

  def test_clear
    push("default", job("a"))
    push("other", job("b"))
    queue.pause!

    assert_true assert_roundtrips(1) { queue.clear }
    assert_equal 0, queue.size
    assert_equal ["other"], alt("SMEMBERS", alt_key("queues"))
    refute_predicate queue, :paused?
    assert_true queue("other").delete
    assert_empty alt("SMEMBERS", alt_key("queues"))
  end

  # Queues named for this test alone, so nothing else in Redis (keys
  # mutated code left unprefixed, say) can say they're paused.
  def test_to_h
    name = "to-h-#{SecureRandom.hex(4)}"
    now = Robin.now_ms
    push(name, job("a", enqueued_at: now - 20_000), job("b", enqueued_at: now - 10_000), job("c", enqueued_at: now))
    queue(name).pause!
    h = assert_roundtrips(1) { queue(name).to_h }

    assert_equal %w[latency name paused size], h.keys.sort
    assert_equal [name, 3, true], h.values_at("name", "size", "paused")
    assert_in_delta 20.0, h["latency"], 1.0, "the oldest job's"
    refute queue("other-#{SecureRandom.hex(4)}").to_h["paused"]
  end
end

class JobRecordApiTest < RobinTest
  include ApiTestSupport

  cover "Robin::JobRecord*"

  def record(item, queue = nil) = Robin::JobRecord.new(item, queue, config: alt_config)

  def test_error_backtrace
    packed = Robin::Retrier.pack_backtrace(%w[a:1 b:2])

    assert_equal %w[a:1 b:2], record(job("j", error_backtrace: packed)).error_backtrace
    assert_equal %w[old:1], record(job("j", error_backtrace: %w[old:1])).error_backtrace
    assert_nil record(job("j")).error_backtrace
  end

  def test_from_hash_and_string
    item = job("j1", "queue" => "q")
    from_hash = record(item)
    from_string = record(Robin.dump_json(item))

    assert_same item, from_hash.item
    assert_equal Robin.dump_json(item), from_hash.value
    assert_equal item, from_string.item
    assert_equal Robin.dump_json(item), from_string.value
    assert_equal "q", from_hash.queue
    assert_equal "override", record(item, "override").queue
  end

  def test_unparseable
    rec = record("{nope")

    assert_equal({"class" => "<unparseable>", "args" => [], "raw" => "{nope"}, rec.item)
    assert_equal "{nope", rec.value
    assert_nil rec.queue
  end

  def test_defaults_to_global_config
    push("default", job("x"), config: config)

    assert Robin::JobRecord.new(Robin.dump_json(job("x"))).delete
  end

  def test_readers
    rec = record(job("j", "bid" => "b1", "tags" => %w[t1], "error_class" => "E", "error_message" => "m", "retry_count" => 2))

    assert_equal "j", rec["jid"]
    assert_nil rec["missing"]
    assert_equal "SomeJob", rec.klass
    assert_equal ["j"], rec.args
    assert_equal "j", rec.jid
    assert_equal "b1", rec.bid
    assert_equal %w[t1], rec.tags
    assert_equal "E", rec.error_class
    assert_equal "m", rec.error_message
    assert_equal 3, rec.failures
    assert_empty record(job("j")).tags
    assert_equal 0, record(job("j")).failures
    assert_equal 1, record(job("j", "retry_count" => 0)).failures
    assert_equal 3, record(job("j", "retry_count" => "2")).failures, "as another tool may store it"
  end

  def test_display_class_and_args
    plain = record(job("j"))
    wrapped = record({"class" => "Wrapper", "display_class" => "MailJob", "wrapped" => true, "args" => [{"arguments" => [1, 2]}]})
    wrapped_scalar = record({"class" => "Wrapper", "wrapped" => true, "args" => [5]})
    wrapped_empty = record({"class" => "Wrapper", "wrapped" => true})
    wrapped_name = record({"class" => "Wrapper", "wrapped" => "MailJob", "args" => [{"arguments" => [3]}]})
    renamed = record({"class" => "Wrapper", "wrapped" => "MailJob", "display_class" => "Shown"})
    hash_arg = record(job("j", "args" => [{"arguments" => [9]}]))
    encrypted = record(job("j", "encrypted" => 1))

    assert_equal "SomeJob", plain.display_class
    assert_equal "MailJob", wrapped.display_class
    assert_equal "Wrapper", wrapped_scalar.display_class
    assert_equal "MailJob", wrapped_name.display_class
    assert_equal "Shown", renamed.display_class
    assert_equal [3], wrapped_name.display_args
    assert_equal ["j"], plain.display_args
    assert_equal [1, 2], wrapped.display_args
    assert_equal [5], wrapped_scalar.display_args
    assert_nil wrapped_empty.display_args
    assert_equal ["[encrypted]"], encrypted.display_args
    assert_equal [{"arguments" => [9]}], hash_arg.display_args
  end

  def test_times
    rec = record(job("j", "created_at" => 1_700_000_000_123, "enqueued_at" => 1_700_000_001_500,
      "failed_at" => 1_700_000_002_001, "retried_at" => 1_700_000_003_999))

    assert_equal Time.at(1_700_000_000, 123, :millisecond), rec.created_at
    assert_equal Time.at(1_700_000_001, 500, :millisecond), rec.enqueued_at
    assert_equal Time.at(1_700_000_002, 1, :millisecond), rec.failed_at
    assert_equal Time.at(1_700_000_003, 999, :millisecond), rec.retried_at
    assert_nil record(job("j")).created_at
    legacy = record(job("j", "created_at" => 1_700_000_000.123, "enqueued_at" => 1_700_000_001.5))

    assert_equal Time.at(1_700_000_000, 123, :millisecond), legacy.created_at
    assert_equal Time.at(1_700_000_001, 500, :millisecond), legacy.enqueued_at
  end

  def test_waiting_since_and_latency
    now = Robin.now_ms

    assert_equal 20, record({"enqueued_at" => 10, "at" => 0.02}).waiting_since
    assert_equal 20, record({"enqueued_at" => 20, "at" => 0.01}).waiting_since
    assert_equal 10, record({"enqueued_at" => 10}).waiting_since
    assert_equal 30, record({"at" => 0.03}).waiting_since
    assert_equal 1_700_000_000_500, record({"enqueued_at" => 1_700_000_000.5}).waiting_since
    assert_nil record({}).waiting_since
    assert_in_delta 3.0, record({"enqueued_at" => now - 3_000}).latency, 0.5
  end

  def test_delete_removes_one_copy
    push("default", job("a"), job("a"))
    rec = record(Robin.dump_json(job("a")))

    assert rec.delete
    assert_equal 1, alt("LLEN", alt_key("queue", "default"))
    assert rec.delete
    refute rec.delete
  end

  def test_to_h
    item = job("j", "display_class" => "D")

    assert_equal({"jid" => "j", "class" => "SomeJob", "display_class" => "D", "args" => ["j"], "queue" => "default",
                  "item" => item}, record(item).to_h)
    secret = job("s", "encrypted" => 1, "args" => ["cipher"])

    assert_equal ["[encrypted]"], record(secret).to_h["item"]["args"]
    assert_equal ["cipher"], secret["args"]
  end
end

class JobSetApiTest < RobinTest
  include ApiTestSupport

  cover "Robin::SortedEntry*"
  cover "Robin::JobSet*"
  cover "Robin::ScheduledSet*"
  cover "Robin::RetrySet*"
  cover "Robin::DeadSet*"

  def set(name = "retry") = Robin::JobSet.new(name, config: alt_config)

  def add(name, score, item) = alt("ZADD", alt_key(name), score, Robin.dump_json(item))

  def test_named_sets
    assert_equal "schedule", Robin::ScheduledSet.new(config: alt_config).name
    assert_equal "retry", Robin::RetrySet.new(config: alt_config).name
    assert_equal "dead", Robin::DeadSet.new(config: alt_config).name
    assert_equal config.key("retry"), Robin::RetrySet.new.key
    assert_equal config.key("dead"), Robin::DeadSet.new.key
    assert_equal config.key("schedule"), Robin::ScheduledSet.new.key
    assert_equal config.key("x"), Robin::JobSet.new("x").key
    assert_same alt_config, set.config
    assert_equal [alt_key("schedule"), alt_key("retry"), alt_key("dead")],
      [Robin::ScheduledSet, Robin::RetrySet, Robin::DeadSet].map { |k| k.new(config: alt_config).key }
  end

  def test_size_clear_and_schedule
    set.schedule(1_700_000_000_000, job("a", "at" => 5))
    set.schedule(1_700_000_001_000, Robin.dump_json(job("b", "at" => 6)))

    assert_equal 2, set.size
    assert_equal [["a", 1_700_000_000.0, nil], ["b", 1_700_000_001.0, 6]], set.map { |e| [e.jid, e.score, e["at"]] }
    set.clear

    assert_equal 0, set.size
    set.schedule(60, job("later"))

    assert_in_delta Robin.epoch_seconds(Robin.now_ms + 60_000), set.first.score, 2
  end

  def test_deleting_while_iterating_visits_every_entry
    250.times { |i| add("retry", i, job(i.to_s)) }

    assert_equal Array.new(250) { |i| i.to_s }, set.each.map { |e| e.delete && e.jid }
    assert_equal 0, set.size
    250.times { |i| add("retry", i, job(i.to_s)) }

    assert_equal Array.new(250) { |i| (249 - i).to_s }, set.each(reverse: true).map { |e| e.delete && e.jid }
  end

  def test_deleting_some_entries_while_iterating_visits_each_once
    250.times { |i| add("retry", i, job(i.to_s)) }
    seen = set.each.map do |e|
      e.delete if e.jid.to_i.even?
      e.jid
    end

    assert_equal Array.new(250) { |i| i.to_s }, seen
    assert_equal 125, set.size
    seen = set.each(reverse: true).map do |e|
      e.delete if (e.jid.to_i % 4) == 1
      e.jid
    end

    assert_equal(Array.new(125) { |i| (249 - (2 * i)).to_s }, seen)
  end

  def test_entries_added_while_iterating_dont_cause_skips
    150.times { |i| add("retry", i, job(i.to_s)) }
    seen = set.each.map do |e|
      add("retry", 1_000, job("late")) if e.jid == "0"
      e.jid
    end

    assert_equal Array.new(150) { |i| i.to_s } + ["late"], seen
  end

  def test_unvisited_entries_removed_by_others_while_iterating
    250.times { |i| add("retry", i, job(i.to_s)) }
    seen = set.each.map do |e|
      alt("ZREMRANGEBYRANK", set.key, 0, 149) if e.jid == "0" # drops 50 we haven't reached
      e.jid
    end

    assert_equal Array.new(100) { |i| i.to_s } + Array.new(100) { |i| (150 + i).to_s }, seen
  end

  def test_a_set_emptied_while_iterating_ends_cleanly
    150.times { |i| add("retry", i, job(i.to_s)) }
    seen = set.each.map do |e|
      alt("DEL", set.key) if e.jid == "0"
      e.jid
    end

    assert_equal Array.new(100) { |i| i.to_s }, seen
  end

  def test_each_pages_in_both_directions
    250.times { |i| add("retry", i, job(i.to_s)) }

    assert_equal Array.new(250) { |i| i.to_s }, set.map(&:jid)
    assert_equal Array.new(250) { |i| (249 - i).to_s }, set.each(reverse: true).map(&:jid)
    assert_equal ["249"], set.each(reverse: true).first(1).map(&:jid)
    assert_empty set("empty").to_a
  end

  def test_page
    30.times { |i| add("retry", i, job(i.to_s)) }

    assert_equal %w[2 3], set.page(2, per_page: 2).map(&:jid)
    assert_equal %w[27 26], set.page(2, per_page: 2, reverse: true).map(&:jid)
    assert_equal 25, set.page(1).size
    assert_equal "25", set.page(2).first.jid
  end

  def test_sorted_entry_basics
    add("retry", 1_500, job("j", "queue" => "q"))
    entry = set.first

    assert_in_delta 1500.0, entry.score
    assert_equal Time.at(1_500), entry.at
    assert_equal "1500.0-j", entry.id
    assert_equal set.key, entry.parent.key
    assert_equal "q", entry.queue
    assert_equal({"score" => 1500.0, "at" => 1500.0, "id" => "1500.0-j", "set" => "retry", "jid" => "j", "class" => "SomeJob",
                  "display_class" => "SomeJob", "args" => ["j"], "queue" => "q", "item" => entry.item}, entry.to_h)
    assert entry.delete
    refute entry.delete
  end

  def test_fractional_scores
    add("retry", 1.2346, job("j"))
    entry = set.first

    assert_in_delta 1.2346, entry.score
    assert_equal Time.at(1, 235, :millisecond), entry.at
    assert_in_delta 1.2346, entry.to_h["at"]
    assert_equal "1.2346-j", entry.id
    assert_equal "j", set.find_by_id(entry.id).jid
  end

  def test_add_to_queue_and_retry
    add("retry", 1, job("a", "at" => 5, "enqueued_at" => 6, "queue" => "q"))
    add("retry", 2, job("b"))
    a, b = set.to_a

    # Taken out of the set first, so two can't both push it.
    assert_true assert_roundtrips(2) { a.add_to_queue }
    assert_equal 5, a["at"]
    refute a.add_to_queue
    assert b.retry!
    queued = Robin.load_json(alt("LINDEX", alt_key("queue", "q"), 0))

    assert_equal "a", queued["jid"]
    refute queued.key?("at")
    refute_equal 6, queued["enqueued_at"]
    assert_equal 0, set.size
    assert_equal 1, alt("LLEN", alt_key("queue", "default"))
  end

  def test_reschedule
    add("retry", 1, job("a", "at" => 1))
    entry = set.first
    assert_roundtrips(1) { entry.reschedule(100_000_002_500) }
    moved = set.first

    assert_equal 1, set.size
    assert_in_delta 100_000_002.5, moved.score, 0
    refute moved.item.key?("at")
    assert_equal job("a"), moved.item
    moved.reschedule(30)

    assert_in_delta Robin.epoch_seconds(Robin.now_ms + 30_000), set.first.score, 2
  end

  def test_kill
    add("retry", 1, job("a", "at" => 1, "enqueued_at" => 2))
    entry = set.first

    assert_true assert_roundtrips(2) { entry.kill! }
    refute entry.kill!
    dead = Robin::DeadSet.new(config: alt_config).first

    assert_equal "a", dead.jid
    assert_in_delta Robin.epoch_seconds(Robin.now_ms), dead.score, 2
    refute dead.item.key?("at")
    refute dead.item.key?("enqueued_at")
    assert_equal 0, set.size
  end

  def test_scan_matches_literally
    add("retry", 1, job("a*b"))
    add("retry", 2, job("axxb"))
    add("retry", 3, job("c?d[1]\\"))
    add("retry", 4, job("cxd1"))

    assert_equal [["a*b", 1.0]], set.scan("a*b").map { |e| [e.jid, e.score] }
    assert_equal ["c?d[1]\\"], set.scan("c?d[1]\\").map(&:jid)
    assert_equal ["c?d[1]\\"], set.scan("[1]").map(&:jid)
    assert_empty set.scan("")
    assert_empty set.scan(nil)
    assert_equal ["a*b"], set.scan(:"a*b").map(&:jid)
  end

  def test_scan_walks_cursor_and_honors_limit
    2_000.times { |i| add("retry", i, job("big-#{i}", "pad" => "x" * 64)) }

    assert_equal 2_000, set.scan("big-", limit: 5_000).size
    assert_equal 500, set.scan("big-").size
    assert_equal 3, set.scan("big-", limit: 3).size
  end

  def test_scan_stops_as_soon_as_the_limit_is_reached
    2_000.times { |i| add("retry", i, job("big-#{i}", "pad" => "x" * 64)) }
    _, first_batch = alt("ZSCAN", alt_key("retry"), "0", "MATCH", "*big-*", "COUNT", 1000)
    spy = ApiTestSupport::SpyPool.new(alt_config.redis_pool)
    alt_config.redis_pool = spy

    assert_equal first_batch.size / 2, set.scan("big-", limit: first_batch.size / 2).size
    assert_equal [["ZSCAN", alt_key("retry"), "0", "MATCH", "*big-*", "COUNT", 1000]], spy.commands
    spy.commands.clear

    assert_equal 3, set.scan("big-", limit: 3).size
    assert_equal 1, spy.commands.size
  end

  def test_find_job
    add("retry", 1, job("xabc"))
    add("retry", 2, job("abc"))
    add("retry", 3, job("abcd"))

    spy = ApiTestSupport::SpyPool.new(alt_config.redis_pool)
    alt_config.redis_pool = spy

    assert_equal "abc", set.find_job("abc").jid
    assert_equal ["ZSCAN"], spy.commands.map(&:first)
    assert_equal %w[xabc abc abcd], set.scan("abc").map(&:jid), "soonest first"
    assert_nil set.find_job("zzz")
  end

  def test_fetch_and_find_by_id
    add("retry", 5, job("v"))
    add("retry", 7, job("x"))
    add("retry", 7, job("y-z"))
    add("retry", 8, job("w"))

    assert_equal %w[x y-z], set.fetch(7).map(&:jid).sort
    assert_equal ["y-z"], set.fetch(7, "y-z").map(&:jid)
    assert_equal [7.0], set.fetch(7, "x").map(&:score)
    assert_empty set.fetch(7, "w")
    assert_equal "y-z", set.find_by_id("7-y-z").jid
    assert_nil set.find_by_id("7-nope")
  end

  def test_delete_by_jid
    add("retry", 7, job("x"))

    refute set.delete_by_jid(7, "nope")
    assert set.delete_by_jid(7, "x")
    assert_equal 0, set.size
  end

  def test_retry_all_and_kill_all
    retries = Robin::RetrySet.new(config: alt_config)
    3.times { |i| add("retry", i, job(i.to_s)) }

    # The set's size, the page, the jobs taken, the jobs pushed.
    assert_equal 3, assert_roundtrips(4) { retries.retry_all }
    assert_equal 3, alt("LLEN", alt_key("queue", "default"))
    2.times { |i| add("retry", i, job(i.to_s)) }

    assert_equal 2, assert_roundtrips(4) { retries.kill_all }
    assert_equal 2, Robin::DeadSet.new(config: alt_config).size
    assert_equal 0, retries.size
  end

  def test_set_actions_take_their_entries_first_a_page_at_a_time
    add("retry", 1, job("a"))
    add("retry", 2, job("b", "queue" => "q"))
    entries = set.to_a
    alt("ZREM", alt_key("retry"), entries.first.value) # taken by someone else meanwhile

    assert_equal 1, assert_roundtrips(2) { set.retry_entries(entries) }
    assert_equal ["b"], Robin::Queue.new("q", config: alt_config).map(&:jid)
    assert_equal 0, assert_roundtrips(0) { set.retry_entries([]) }
    assert_equal 0, assert_roundtrips(1) { set.kill_entries(entries) }, "gone already: nothing to kill"
    add("retry", 3, job("c-1"))
    add("retry", 3, job("c-1", "args" => [2])) # a twin, at the same score
    add("retry", 3, job("c-2")) # the same score, not asked for
    add("retry", 4, job("d", "args" => [1])) # an earlier run of it
    add("retry", 4.5, job("d"))

    found = assert_roundtrips(1) { set.find_all_by_id(["3.0-c-1", "4.5-d", "5-nope"]) }

    assert_equal [["c-1", 3.0, "3.0-c-1"], ["c-1", 3.0, "3.0-c-1"], ["d", 4.5, "4.5-d"]], found.map { |e| [e.jid, e.score, e.id] }
    assert_equal 2, assert_roundtrips(1) { set.delete_entries(found.first(2)) }
    assert_equal 1, assert_roundtrips(2) { set.kill_entries(found.last(1)) }
    assert_equal %w[d], Robin::DeadSet.new(config: alt_config).map(&:jid)
    assert_equal [["c-2", 3.0], ["d", 4.0]], set.map { |e| [e.jid, e.score] }
  end

  def test_page_and_size
    5.times { |i| add("retry", i, job("j#{i}")) }
    entries, size = assert_roundtrips(1) { set.page_and_size(3, per_page: 2, reverse: false) }

    assert_equal [%w[j4], 5], [entries.map(&:jid), size]
    assert_equal %w[j2 j1], set.page_and_size(2, per_page: 2, reverse: true).first.map(&:jid)
  end

  def test_drain_goes_page_by_page_and_skips_what_the_block_keeps
    retries = Robin::RetrySet.new(config: alt_config)
    7.times { |i| add("retry", i, job("j#{i}")) }
    seen = []
    ranges = []
    real = retries.method(:range)
    retries.define_singleton_method(:range) { |*a| (ranges << a) && real.call(*a) }
    removed = with_constant(Robin::JobSet, :PAGE, 3) do
      retries.drain do |entry|
        seen << entry.jid
        # Keep the odd ones; remove the rest.
        entry.jid.delete_prefix("j").to_i.odd? ? false : entry.delete
      end
    end

    assert_equal %w[j0 j1 j2 j3 j4 j5 j6], seen
    assert_equal 4, removed
    # Each page starts after the entries kept so far; the last is short.
    assert_equal [[0, 3, false], [1, 3, false], [3, 1, false]], ranges
    assert_equal %w[j1 j3 j5], retries.map(&:jid)
  end

  def test_drain_ignores_entries_added_meanwhile
    retries = Robin::RetrySet.new(config: alt_config)
    2.times { |i| add("retry", i, job("old#{i}")) }
    seen = []
    removed = retries.drain do |entry|
      seen << entry.jid
      add("retry", 100 + seen.size, job("new#{seen.size}"))
      entry.delete
    end

    assert_equal [%w[old0 old1], 2], [seen, removed]
    assert_equal %w[new1 new2], retries.map(&:jid)
  end

  def test_drain_stops_when_the_set_empties_early
    retries = Robin::RetrySet.new(config: alt_config)
    3.times { |i| add("retry", i, job("j#{i}")) }
    seen = []
    removed = with_constant(Robin::JobSet, :PAGE, 1) do
      retries.drain do |entry|
        seen << entry.jid
        retries.clear
      end
    end

    assert_equal [%w[j0], 1], [seen, removed]
    assert_equal 0, Robin::RetrySet.new(config: alt_config).drain { flunk "nothing to drain" }
  end

  def test_dead_retry_all
    dead = Robin::DeadSet.new(config: alt_config)
    2.times { |i| add("dead", i, job(i.to_s)) }

    assert_equal 2, assert_roundtrips(4) { dead.retry_all }
    assert_equal 0, dead.size
  end

  def test_dead_kill_trims_by_age
    # A long timeout makes off-by-a-factor mistakes visible without being
    # sensitive to scheduling delays.
    alt_config.dead_timeout = 100_000
    dead = Robin::DeadSet.new(config: alt_config)
    now = Robin.epoch_seconds(Robin.now_ms)
    add("dead", -1, job("corrupt"))
    add("dead", now - 100_050, job("expired"))
    add("dead", now - 99_950, job("old"))

    assert_true dead.kill(Robin.dump_json(job("fresh")))
    assert_equal %w[old fresh], dead.map(&:jid)
  end

  def test_dead_kill_trims_by_size
    alt_config.dead_max_jobs = 3
    dead = Robin::DeadSet.new(config: alt_config)
    now = Robin.epoch_seconds(Robin.now_ms)
    3.times { |i| add("dead", now - 10 + i, job("recent#{i}")) }
    dead.kill(Robin.dump_json(job("fresh")))

    assert_equal %w[recent1 recent2 fresh], dead.map(&:jid)
  end

  def test_dead_kill_acknowledges_and_notifies
    fetcher = Robin::Fetcher.new(alt_config.default_capsule, "me")
    set = alt_key("inflight", "me")
    raw = Robin.dump_json(job("a"))
    unit = Robin::Fetcher::UnitOfWork.new("default", raw, fetcher, "#{set}:1")
    alt("SADD", set, "#{set}:1", "#{set}:2")
    alt("RPUSH", "#{set}:1", raw)
    alt("RPUSH", "#{set}:2", raw)
    seen = []
    alt_config.death_handlers << ->(payload, ex) { seen << [payload, ex] }
    dead = Robin::DeadSet.new(config: alt_config)
    dead.kill(raw, ack: unit)

    assert_equal ["#{set}:2"], alt("SMEMBERS", set)
    assert_equal [0, 1], ["#{set}:1", "#{set}:2"].map { |key| alt("EXISTS", key) }
    acknowledged = []
    in_tx = Object.new
    in_tx.define_singleton_method(:acknowledge) { |tx = :alone| acknowledged << tx.class }
    dead.kill(raw, ack: in_tx)

    assert_equal [Robin::Redis::Pipeline], acknowledged, "in the transaction that kills it"
    assert_empty seen
    dead.kill(raw, notify: true)

    assert_equal [[job("a"), nil]], seen
  end
end

class ProcessApiTest < RobinTest
  include ApiTestSupport

  cover "Robin::ProcessRecord*"
  cover "Robin::ProcessSet*"
  cover "Robin::WorkSet*"

  INFO = {"hostname" => "h", "concurrency" => 4}.freeze

  def add_process(identity, **fields)
    alt("SADD", alt_key("processes"), identity)
    data = {"info" => Robin.dump_json(INFO), "busy" => "2", "beat" => "1700000000.25", "quiet" => "false", "leader" => "0",
            "rss" => "300", "rtt_us" => "40"}.merge(fields.transform_keys(&:to_s))
    alt("HSET", alt_config.process_key(identity), *data.flatten)
  end

  def test_process_record
    add_process("b", quiet: "true", leader: "1")
    record = Robin::ProcessSet.new(config: alt_config).first

    assert_equal "b", record.identity
    assert_equal INFO, record.info
    assert_equal "h", record["hostname"]
    assert_equal [2, 1_700_000_000_250, 300, 40], [record.busy, record.beat, record.rss, record.rtt_us]
    assert_nil record.started_at
    assert_predicate record, :quiet?
    assert_predicate record, :leader?
    assert_equal INFO.merge("identity" => "b", "busy" => 2, "beat" => 1_700_000_000_250, "quiet" => true, "leader" => true,
      "rss_kb" => 300, "rtt_us" => 40), record.to_h
  end

  def test_process_record_times_and_capsules
    info = {"hostname" => "h", "started_at" => 1_700_000_000.125, "weights" => [{"a" => 1}],
            "capsules" => {"default" => {"concurrency" => 2, "mode" => "weighted", "weights" => {"a" => 1}}, "bare" => {}}}
    record = Robin::ProcessRecord.new("p", {"info" => Robin.dump_json(info)})

    assert_equal 1_700_000_000_125, record.started_at
    assert_equal({"hostname" => "h", "started_at" => 1_700_000_000_125, "weights" => [{"a" => 1}],
                  "capsules" => {"default" => {"concurrency" => 2, "queues" => {"a" => 1}}, "bare" => {"concurrency" => nil, "queues" => nil}},
                  "identity" => "p", "busy" => 0,
                  "beat" => 0, "quiet" => false, "leader" => false, "rss_kb" => 0, "rtt_us" => 0}, record.to_h)
  end

  def test_process_record_gvl_contention
    record = Robin::ProcessRecord.new("g", {"gvl" => "37.5"})

    assert_in_delta 37.5, record.gvl_contention
    assert_instance_of Float, record.gvl_contention
    assert_in_delta 37.5, record.to_h.fetch("gvl_contention")
    assert_in_delta 0.0, Robin::ProcessRecord.new("g", {"gvl" => "0"}).to_h.fetch("gvl_contention")
  end

  def test_process_record_defaults
    record = Robin::ProcessRecord.new("x", {})

    assert_nil record.gvl_contention

    assert_empty record.info
    assert_nil record["missing"]
    assert_equal({"identity" => "x", "busy" => 0, "beat" => 0, "quiet" => false, "leader" => false, "rss_kb" => 0,
                  "rtt_us" => 0}, record.to_h)
    assert_equal [0, 0, 0, 0], [record.busy, record.beat, record.rss, record.rtt_us]
    refute_predicate record, :quiet?
    refute_predicate record, :leader?
  end

  def test_signals
    record = Robin::ProcessRecord.new("p", {}, config: alt_config)

    assert_true record.quiet!
    assert_true record.stop!
    assert_true record.dump_threads
    key = "#{alt_config.process_key("p")}-signals"

    assert_equal %w[TTIN TERM TSTP], alt("LRANGE", key, 0, -1)
    assert_includes 59_001..60_000, alt("PTTL", key)
    Robin::ProcessRecord.new("q", {}).quiet!

    assert_equal ["TSTP"], redis("LRANGE", "#{config.process_key("q")}-signals", 0, -1)
  end

  def test_resize
    record = Robin::ProcessRecord.new("p", {}, config: alt_config)

    assert_true record.resize!(3)
    assert_true record.resize!(12, capsule: "bulk")
    key = "#{alt_config.process_key("p")}-signals"

    assert_equal ["RESIZE 12 bulk", "RESIZE 3 default"], alt("LRANGE", key, 0, -1)
    assert_includes 59_001..60_000, alt("PTTL", key)
    [0, -2, 1.5, "4", nil].each do |count|
      error = assert_raises(ArgumentError) { record.resize!(count) }

      assert_equal "a capsule needs a concurrency above 0, not #{count.inspect}", error.message
    end
    assert_equal 2, alt("LLEN", key)
  end

  def test_process_set
    add_process("b", info: Robin.dump_json({"concurrency" => 3}), rss: "10")
    add_process("a", rss: "5")
    add_process("c", info: Robin.dump_json({}), rss: "0")
    alt("SADD", alt_key("processes"), "0dead")
    alt("SET", alt_key("leader"), "a")
    processes = Robin::ProcessSet.new(config: alt_config)

    assert_equal %w[a b c], assert_roundtrips(1) { processes.map(&:identity) }
    assert_equal %w[a b c], processes.each.map(&:identity)
    assert_equal 3, processes.size
    assert_equal 7, processes.total_concurrency
    assert_equal 15, processes.total_rss_kb
    assert_equal "a", processes.leader
    processes.first.quiet!

    assert_equal ["TSTP"], alt("LRANGE", "#{alt_config.process_key("a")}-signals", 0, -1)
    assert_equal 0, Robin::ProcessSet.new.size
  end

  def test_work_set
    alt("SADD", alt_key("processes"), "b", "a")
    entry = ->(queue, payload, run_at) { Robin.dump_json({"queue" => queue, "payload" => payload, "run_at" => run_at}) }
    # Out of order: each process's work comes back sorted by thread.
    alt("HSET", "#{alt_config.process_key("a")}:work", "t3", entry.call("s", {"jid" => "3"}, 2),
      "t1", entry.call("q", Robin.dump_json({"jid" => "1"}), 1_700_000_000.5))
    alt("HSET", "#{alt_config.process_key("b")}:work", "t2", entry.call("r", "{}", 1.25))
    work = Robin::WorkSet.new(config: alt_config)

    assert_equal [["a", "t1", {"queue" => "q", "run_at" => 1_700_000_000_500, "payload" => {"jid" => "1"}}],
      ["a", "t3", {"queue" => "s", "run_at" => 2_000, "payload" => {"jid" => "3"}}],
      ["b", "t2", {"queue" => "r", "run_at" => 1_250, "payload" => {}}]], assert_roundtrips(1) { work.to_a }
    assert_equal 3, work.each.count
    assert_equal 3, work.size
    assert_equal 0, Robin::WorkSet.new.size
  end
end

class JobLocatorApiTest < RobinTest
  include ApiTestSupport

  cover "Robin::JobLocator*"

  def locate(jid) = Robin::JobLocator.new(config: alt_config).locate(jid)

  def summary(results) = results.map { |r| [r.fetch("where"), r["queue"], r.fetch("job").jid] }

  # Records which queues get searched.
  def searched
    names = []
    real = Robin::Queue.instance_method(:find_job)
    Robin::Queue.define_method(:find_job) do |jid|
      names << name
      real.bind_call(self, jid)
    end
    yield
    names
  ensure
    Robin::Queue.define_method(:find_job, real)
  end

  def test_running_and_set_jobs_come_before_queues
    alt("SADD", alt_key("processes"), "p1")
    work = ->(jid, queue) { Robin.dump_json({"queue" => queue, "payload" => Robin.dump_json(job(jid, queue: "pushed-to")), "run_at" => 1.0}) }
    alt("HSET", "#{alt_config.process_key("p1")}:work", "t1", work.call("j", "running-q"), "t2", work.call("other", "x"))
    alt("ZADD", alt_key("retry"), 5, Robin.dump_json(job("j")))
    alt("ZADD", alt_key("dead"), 6, Robin.dump_json(job("j")))
    push("default", job("j"))
    results = nil
    names = searched { results = locate("j") }

    assert_equal [["busy", nil, "j"], ["retries", nil, "j"], ["dead", nil, "j"]], summary(results)
    assert_equal %w[p1 t1], results.first.values_at("identity", "thread")
    busy = results.first.fetch("job")

    assert_equal ["running-q", alt_config], [busy.queue, busy.instance_variable_get(:@config)]
    assert_instance_of Robin::RetrySet, results[1].fetch("job").parent
    assert_empty names
  end

  def test_scheduled_jobs
    alt("ZADD", alt_key("schedule"), 5, Robin.dump_json(job("s")))

    assert_equal [["scheduled", nil, "s"]], summary(locate("s"))
  end

  def test_queues_are_searched_in_order_until_found
    push("a", job("x"))
    push("b", job("j"))
    push("c", job("y"))
    results = nil

    assert_equal %w[a b], searched { results = locate("j") }
    assert_equal [["queue", "b", "j"]], summary(results)
    assert_equal %w[a b c], searched { assert_empty locate("missing") }
  end

  def test_the_jid_index_says_which_queue_to_search_first
    push("a", job("x"))
    push("b", job("j"))
    alt("SET", alt_key("jid", "j"), "b")

    assert_equal %w[b], searched { locate("j") }
    alt("SET", alt_key("jid", "j"), "a")
    results = nil

    assert_equal %w[a b], searched { results = locate("j") }
    assert_equal [["queue", "b", "j"]], summary(results)
  end

  def test_queues_over_the_limit_are_only_searched_when_hinted
    push("big", job("b1"), job("b2"))
    push("small", job("s1"))
    with_constant(Robin::JobLocator, :QUEUE_LIMIT, 1) do
      assert_empty locate("b1")
      alt("SET", alt_key("jid", "b1"), "big")

      assert_equal [["queue", "big", "b1"]], summary(locate("b1"))
      assert_equal [["queue", "small", "s1"]], summary(locate("s1"))
    end
    with_constant(Robin::JobLocator, :QUEUE_LIMIT, 2) { assert_equal [["queue", "big", "b2"]], summary(locate("b2")) }
    assert_equal 1_000_000, Robin::JobLocator::QUEUE_LIMIT
  end

  def test_defaults_to_the_global_config
    push("default", job("g"), config: config)

    assert_equal [["queue", "default", "g"]], summary(Robin::JobLocator.new.locate("g"))
  end
end

class TimeAndClassHelpersApiTest < Minitest::Test
  cover "Robin.epoch_seconds"
  cover "Robin.epoch_ms"
  cover "Robin.ms_of"
  cover "Robin.display_class"

  def test_epoch_seconds
    assert_in_delta 1.5, Robin.epoch_seconds(1_500), 0
    assert_in_delta 0.001, Robin.epoch_seconds(1), 0
    assert_instance_of Float, Robin.epoch_seconds(2_000)
    assert_in_delta 1_700_000_000.123, Robin.epoch_seconds(1_700_000_000_123), 0
  end

  def test_epoch_ms
    assert_same 1_500, Robin.epoch_ms(1.5)
    assert_same 2_000, Robin.epoch_ms(2)
    assert_same 2_250, Robin.epoch_ms("2.25")
    assert_same 1, Robin.epoch_ms(0.0014)
    assert_same 2, Robin.epoch_ms(0.0016)
    assert_equal 1_700_000_000_123, Robin.epoch_ms(1_700_000_000.123)
    assert_raises(TypeError) { Robin.epoch_ms(nil) }
  end

  def test_ms_of_converts_only_legacy_float_seconds
    assert_same 1_700_000_000_500, Robin.ms_of(1_700_000_000.5)
    assert_same 99_999_999_999_000, Robin.ms_of(99_999_999_999.0)
    assert_in_delta 100_000_000_000.0, Robin.ms_of(100_000_000_000.0), 0
    assert_instance_of Float, Robin.ms_of(100_000_000_000.0)
    assert_same 1_700, Robin.ms_of(1_700)
    assert_nil Robin.ms_of(nil)
  end

  def test_display_class
    assert_equal "Job", Robin.display_class({"class" => "Job"})
    assert_equal "Job", Robin.display_class({"class" => "Job", "wrapped" => true})
    assert_equal "Mail", Robin.display_class({"class" => "Wrapper", "wrapped" => "Mail"})
    assert_equal "Shown", Robin.display_class({"class" => "Wrapper", "wrapped" => "Mail", "display_class" => "Shown"})
    assert_equal "Shown", Robin.display_class({"class" => "Job", "display_class" => "Shown"})
    assert_equal "Wrapper", Robin.display_class({"class" => "Wrapper", "wrapped" => Class.new(String).new("Mail")})
    assert_nil Robin.display_class({})
  end
end
