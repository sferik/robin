# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class JobClassTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::JobClass*"

  def teardown
    Robin::JobClass.store(config, [])
    super
  end

  def job(klass, jid, queue = "default") = Robin.dump_json({"class" => klass, "args" => [], "jid" => jid, "queue" => queue})

  def parked(name) = redis("LRANGE", config.key("classes", "parked", name), 0, -1)

  def queued(name) = redis("LRANGE", config.key("queue", name), 0, -1)

  def test_pausing_and_unpausing
    report = Robin::JobClass.new("ReportJob")

    refute report.paused?
    assert_true report.pause!
    assert report.paused?
    assert_equal ["ReportJob"], Robin::JobClass.paused
    assert_equal 0, report.unpause!
    refute report.paused?
    assert_empty Robin::JobClass.paused
  end

  def test_a_class_or_its_name
    assert_equal "Robin::Batch", Robin::JobClass.new(Robin::Batch).name
    assert_equal "ReportJob", Robin::JobClass.new(:ReportJob).name
  end

  def test_the_paused_classes_are_listed_by_name_with_their_parked_jobs
    assert_empty Robin::JobClass.list
    %w[Zed Alpha].each { |name| Robin::JobClass.new(name).pause! }
    redis("LPUSH", config.key("classes", "parked", "Zed"), "a", "b")

    assert_equal [{"name" => "Alpha", "parked" => 0}, {"name" => "Zed", "parked" => 2}], Robin::JobClass.list
    assert_equal %w[Alpha Zed], Robin::JobClass.paused
    assert_equal 2, Robin::JobClass.new("Zed").parked
  end

  def test_a_heartbeat_s_listing_refreshes_the_local_copy
    redis("SADD", config.key("classes", "paused"), "A")
    names = config.redis { |c| c.call(*Robin::JobClass.listing(config)) }
    Robin::JobClass.store(config, names)

    assert_equal "A", Robin::JobClass.paused_class(config, {"class" => "A"})
    assert_nil Robin::JobClass.paused_class(config, {"class" => "B"})
    assert_nil Robin::JobClass.paused_class(Robin::Config.new, {"class" => "A"}), "another config's"
    assert_nil Robin::JobClass.paused_class(config, {}), "no class at all"
  end

  def test_an_active_job_job_is_paused_by_the_class_it_wraps
    Robin::JobClass.store(config, %w[Mailer Robin::ActiveJob::Wrapper])

    assert_equal "Mailer", Robin::JobClass.paused_class(config, {"class" => "Robin::ActiveJob::Wrapper", "wrapped" => "Mailer"})
    Robin::JobClass.store(config, %w[Robin::ActiveJob::Wrapper])

    assert_equal "Robin::ActiveJob::Wrapper", Robin::JobClass.paused_class(config, {"class" => "Robin::ActiveJob::Wrapper", "wrapped" => "Mailer"})
    Robin::JobClass.store(config, [])

    assert_nil Robin::JobClass.paused_class(config, {"class" => "Mailer"})
  end

  # Before its first heartbeat, a process knows of no paused classes; its
  # own pauses show once it has its copy.
  def test_this_process_s_own_pauses_show_at_once
    fresh = Robin::Config.new.tap { |c| c.redis = TEST_REDIS }
    Robin::JobClass.new("A", config: fresh).pause!

    assert_nil Robin::JobClass.paused_class(fresh, {"class" => "A"})
    Robin::JobClass.store(fresh, [])
    Robin::JobClass.new("A", config: fresh).pause!

    assert_equal "A", Robin::JobClass.paused_class(fresh, {"class" => "A"})
    Robin::JobClass.new("A", config: fresh).unpause!

    assert_nil Robin::JobClass.paused_class(fresh, {"class" => "A"})
  ensure
    Robin::JobClass.store(fresh, []) if fresh
  end

  def test_a_fetched_job_is_parked_only_while_its_class_is_paused
    fetcher = Robin::Fetcher.new(config.default_capsule, "me")
    unit = unit_in_flight(fetcher, job("A", "1"), "default")

    refute Robin::JobClass.park(config, unit, "A"), "not paused"
    assert_equal [job("A", "1")], redis("LRANGE", unit.key, 0, -1)
    Robin::JobClass.new("A").pause!

    assert Robin::JobClass.park(config, unit, "A")
    assert_equal 0, redis("EXISTS", unit.key)
    assert_equal [job("A", "1")], parked("A")
    refute Robin::JobClass.park(config, unit, "A"), "gone from its in-flight key already"
  end

  def test_unpausing_puts_parked_jobs_back_at_the_front_of_their_queues_oldest_first
    redis("RPUSH", config.key("queue", "default"), "later")
    Robin::JobClass.new("A").pause!
    # Parked newest on the left, as the processor parks them.
    [job("A", "1"), job("A", "2", "mail"), job("A", "3")].each { |raw| redis("LPUSH", config.key("classes", "parked", "A"), raw) }

    assert_equal 3, Robin::JobClass.new("A").unpause!
    # Fetched from the right: 1, then 3, then the job queued meanwhile.
    assert_equal ["later", job("A", "3"), job("A", "1")], queued("default")
    assert_equal [job("A", "2", "mail")], queued("mail")
    assert_equal %w[default mail], redis("SMEMBERS", config.key("queues")).sort
    assert_empty parked("A")
    refute Robin::JobClass.new("A").paused?
  end

  def test_a_job_with_no_queue_goes_back_to_the_default_queue
    Robin::JobClass.new("A").pause!
    raw = Robin.dump_json({"class" => "A", "jid" => "1"})
    redis("LPUSH", config.key("classes", "parked", "A"), raw)
    Robin::JobClass.new("A").unpause!

    assert_equal [raw], queued("default")
  end

  def test_a_thousand_parked_jobs_go_back_per_round_trip_by_default
    [[1000, 2], [1001, 3]].each do |count, trips|
      Robin::JobClass.new("A").pause!
      redis("RPUSH", config.key("classes", "parked", "A"), *Array.new(count) { |i| job("A", i.to_s) })

      assert_equal count, assert_roundtrips(trips) { Robin::JobClass.new("A").unpause! }
    end
  end

  def test_many_parked_jobs_go_back_a_chunk_per_round_trip
    Robin::JobClass.new("A").pause!
    raws = Array.new(5) { |i| job("A", i.to_s) }
    raws.each { |raw| redis("LPUSH", config.key("classes", "parked", "A"), raw) }

    assert_equal 5, assert_roundtrips(4) { Robin::JobClass.new("A").unpause!(chunk: 2) }
    assert_equal raws.reverse, queued("default"), "the oldest at the front (the right)"
  end
end
