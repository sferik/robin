# frozen_string_literal: true

require_relative "test_helper"

class EventsTest < RobinTest
  cover "Robin::Events*"

  def setup
    super
    @cfg = Robin::Config.new
  end

  def recorder(list) = ->(name, payload) { list << [name, payload] }

  def test_handlers_get_the_name_and_payload
    first = []
    second = []
    @cfg.event_handlers << recorder(first) << recorder(second)

    assert_nil Robin::Events.emit(@cfg, "job.expired", job: {"jid" => "j1"}, extra: 2)
    assert_equal [["job.expired", {job: {"jid" => "j1"}, extra: 2}]], first
    assert_equal [["job.expired", {job: {"jid" => "j1"}, extra: 2}]], second
  end

  def test_an_empty_payload_is_an_empty_hash
    events = []
    @cfg.event_handlers << recorder(events)

    assert_nil Robin::Events.emit(@cfg, "heartbeat.lapsed")
    assert_equal [["heartbeat.lapsed", {}]], events
  end

  def test_a_raising_handler_is_reported_and_the_others_still_run
    errors = []
    @cfg.error_handlers << ->(ex, ctx, _) { errors << [ex, ctx] }
    events = []
    boom = RuntimeError.new("boom")
    @cfg.event_handlers << ->(_, _) { raise boom } << recorder(events)

    assert_nil Robin::Events.emit(@cfg, "jobs.orphaned", count: 3)
    assert_equal [[boom, {context: "event handler", event: "jobs.orphaned"}]], errors
    assert_equal [["jobs.orphaned", {count: 3}]], events
  end

  def test_no_handlers
    assert_empty @cfg.event_handlers
    assert_nil Robin::Events.emit(@cfg, "redis.slow", rtt_us: 1)
  end
end
