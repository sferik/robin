# frozen_string_literal: true

require_relative "helper"
require "robin/active_job"

ActiveJob::Base.logger = Logger.new(nil)

module AJUnit
  SEEN = []

  class BaseJob < ActiveJob::Base
    self.queue_adapter = :robin

    def perform(*args)
      SEEN << {args: args, provider_job_id: provider_job_id, current: Thread.current[:robin_active_job]}
      raise ArgumentError, "requested" if args.first == "boom"
    end
  end

  class OptionJob < BaseJob
    queue_as :mail
    robin_options retry: 4, queue: "ignored", class: "ignored", args: [], jid: "x", at: 1, tags: [:a], dead: :nope
  end

  class ChildJob < OptionJob; end

  # Stands in for ActionMailer::MailDeliveryJob (ActionMailer isn't loaded).
  class MailDelivery < BaseJob
    def self.name = "ActionMailer::MailDeliveryJob"
  end

  class CustomMailDelivery < MailDelivery
    def self.name = "AJUnit::CustomMailDelivery"
  end

  class Halt
    def call(*) = nil
  end

  # Records payloads as the client middleware sees them (before JSON).
  class Spy
    @seen = []
    class << self
      attr_reader :seen
    end

    def call(_klass, payload, _queue, _redis)
      self.class.seen << payload.dup
      yield
    end
  end

  # A job-like object from an ActiveJob without +successfully_enqueued=+
  # and a class without +robin_options+.
  class LegacyJob
    attr_accessor :provider_job_id

    def queue_name = "legacy"

    def scheduled_at = nil

    def serialize = {"job_class" => "AJUnit::LegacyJob", "arguments" => []}
  end
end

class ActiveJobUnitTest < RobinTest
  include AJUnit

  cover "Robin::ActiveJob*"
  cover "ActiveJob::QueueAdapters::RobinAdapter*"

  def setup
    super
    SEEN.clear
  end

  def adapter = ActiveJob::QueueAdapters::RobinAdapter.new

  def items(queue = "default") = Robin::Queue.new(queue).to_a

  def test_wrapper_executes_with_provider_job_id_and_thread_marker
    wrapper = Robin::ActiveJob::Wrapper.new
    wrapper.jid = "J1"
    wrapper.perform(BaseJob.new("x").serialize)

    assert_equal [{args: ["x"], provider_job_id: "J1", current: wrapper}], SEEN
    assert_nil Thread.current[:robin_active_job]
    assert_raises(ArgumentError) { wrapper.perform(BaseJob.new("boom").serialize) }
    assert_nil Thread.current[:robin_active_job]
  end

  def test_robin_options
    parent = Class.new(ActiveJob::Base)
    child = Class.new(parent)

    assert_equal({}, parent.robin_options)
    parent.robin_options(retry: 4, tags: [:a], dead: :nope)

    assert_equal({"retry" => 4, "tags" => [:a], "dead" => "nope"}, parent.robin_options)
    assert_equal parent.robin_options, child.robin_options
    child.robin_options(retry: 1, queue: :q)

    assert_equal({"retry" => 1, "tags" => [:a], "dead" => "nope", "queue" => "q"}, child.robin_options)
    assert_equal 4, parent.robin_options["retry"]
    parent.robin_options(extra: "s")

    assert_equal "s", parent.robin_options["extra"]
    assert_equal "nope", parent.robin_options["dead"]
  end

  def test_robin_options_without_inheritable_parent
    klass = Class.new { include Robin::ActiveJob::Options }

    assert_equal({}, klass.robin_options)
  end

  def test_enqueue_payload
    job = OptionJob.new("ann")
    jid = adapter.enqueue(job)
    item = items("mail").first.item

    assert_equal jid, job.provider_job_id
    refute_equal "x", jid # robin_options can't fix the jid
    assert_predicate job, :successfully_enqueued?
    assert_equal %w[args class created_at dead display_class enqueued_at jid queue retry tags wrapped], item.keys.sort
    assert_equal "Robin::ActiveJob::Wrapper", item["class"]
    assert_equal "AJUnit::OptionJob", item["wrapped"]
    assert_equal "AJUnit::OptionJob", item["display_class"]
    assert_equal "mail", item["queue"]
    assert_equal 4, item["retry"]
    assert_equal ["a"], item["tags"]
    assert_equal 1, item["args"].size
    assert_equal job.job_id, item["args"][0]["job_id"]
    assert_equal ["ann"], item["args"][0]["arguments"]
  end

  def test_the_client_wraps_active_job_classes
    assert_includes Robin::Client.rewriters, Robin::ActiveJob::WRAP_ACTIVE_JOB_CLASSES
    jid = Robin::Client.push("class" => OptionJob, "args" => ["ann", 2], "retry" => 9, "periodic" => "p1", "jid" => "nope")
    item = items("mail").first.item

    assert_equal jid, item["jid"]
    refute_equal "nope", jid
    assert_equal %w[args class created_at dead display_class enqueued_at jid periodic queue retry tags wrapped], item.keys.sort
    assert_equal ["Robin::ActiveJob::Wrapper", "AJUnit::OptionJob", "AJUnit::OptionJob", 9, "p1", ["a"]],
      item.values_at("class", "wrapped", "display_class", "retry", "periodic", "tags")
    assert_equal ["ann", 2], item["args"].first["arguments"]
    Robin::Client.push("class" => BaseJob, "args" => [], "queue" => "elsewhere", "at" => Time.now + 60)

    assert_empty items
    entry = Robin::ScheduledSet.new.first

    assert_equal ["elsewhere", "AJUnit::BaseJob"], entry.item.values_at("queue", "display_class")
    assert_equal "elsewhere", entry.item["args"].first["queue_name"]
    assert_in_delta Time.now.to_f + 60, entry.score, 5
    refute entry.item.key?("at")
  end

  def test_the_client_leaves_other_jobs_alone
    wrap = Robin::ActiveJob::WRAP_ACTIVE_JOB_CLASSES
    plain = {"class" => "AJUnit::OptionJob", "args" => [1]}

    assert_same plain, wrap.call(plain)
    robin = {"class" => Robin::ActiveJob::Wrapper, "args" => []}

    assert_same robin, wrap.call(robin)
    other = {"class" => String, "args" => []}

    assert_same other, wrap.call(other)
  end

  def test_periodic_active_jobs_run
    registry = Robin::Periodic::Registry.new
    id = registry.register("* * * * *", "AJUnit::BaseJob", args: ["tick"])
    Robin::Periodic.write_registry(config, registry.entries)
    jid = Robin::Periodic.enqueue_now(id, config: config)
    item = items.first

    assert_equal [jid, "AJUnit::BaseJob", id], [item.jid, item.display_class, item["periodic"]]
    Robin::ActiveJob::Wrapper.new.tap { |w| w.jid = jid }.perform(item.args.first)

    assert_equal [["tick"], jid], SEEN.map { |s| s.values_at(:args, :provider_job_id) }.first
  end

  def test_wrapped_and_display_class_are_strings_before_serialization
    Spy.seen.clear
    config.client_middleware { |c| c.add Spy }
    adapter.enqueue(OptionJob.new(1))

    assert_equal [%w[AJUnit::OptionJob AJUnit::OptionJob]], Spy.seen.map { |p| p.values_at("wrapped", "display_class") }
    assert_instance_of String, Spy.seen.first["wrapped"]
    assert_instance_of String, Spy.seen.first["display_class"]
  end

  def test_mail_deliveries_show_the_mail_they_send
    Spy.seen.clear
    config.client_middleware { |c| c.add Spy }
    adapter.enqueue(MailDelivery.new("UserMailer", "welcome", "deliver_now", {args: [1]}))
    adapter.enqueue(CustomMailDelivery.new("BillingMailer", "receipt", "deliver_now", {args: []}))

    assert_equal ["UserMailer#welcome", "BillingMailer#receipt"], Spy.seen.map { |p| p["display_class"] }
  end

  def test_enqueue_all_pushes_one_bulk_per_group
    calls = 0
    original = Robin::Client.method(:push_bulk)
    Robin::Client.define_singleton_method(:push_bulk) do |item|
      calls += 1
      original.call(item)
    end
    adapter.enqueue_all([BaseJob.new(1), BaseJob.new(2), OptionJob.new(3), OptionJob.new(4)])

    assert_equal 2, calls
  ensure
    Robin::Client.singleton_class.define_method(:push_bulk, original.unbind)
  end

  def test_enqueue_all_separates_classes_on_one_queue
    other = Class.new(BaseJob) { def self.name = "AJUnit::OtherJob" }
    adapter.enqueue_all([BaseJob.new(1), other.new(2)])

    assert_equal %w[AJUnit::BaseJob AJUnit::OtherJob], items.map(&:display_class).sort
  end

  def test_enqueue_all_separates_queues_of_one_class
    a = BaseJob.new(1)
    b = BaseJob.new(2).tap { |j| j.queue_name = "elsewhere" }
    adapter.enqueue_all([a, b])

    assert_equal [1], items.map { |j| j.args[0]["arguments"][0] }
    assert_equal [2], items("elsewhere").map { |j| j.args[0]["arguments"][0] }
  end

  def test_default_retry_is_true
    adapter.enqueue(BaseJob.new(1))

    assert_true items.first["retry"]
  end

  def test_enqueue_at
    at = Time.now.to_f + 300
    job = BaseJob.new(2)
    jid = adapter.enqueue_at(job, at)
    entry = Robin::ScheduledSet.new.first

    assert_equal jid, entry.jid
    assert_in_delta at, entry.at.to_f, 0.01
  end

  def test_halted_push_is_not_successful
    config.client_middleware { |c| c.add Halt }
    job = BaseJob.new(3)

    assert_nil adapter.enqueue(job)
    refute_predicate job, :successfully_enqueued?
    assert_nil job.provider_job_id
  end

  def test_legacy_jobs_without_success_flag_or_options
    job = LegacyJob.new
    jid = adapter.enqueue(job)

    assert_equal jid, job.provider_job_id
    item = items("legacy").first.item

    assert_true item["retry"]
    assert_equal "AJUnit::LegacyJob", item["display_class"]
    count = adapter.enqueue_all([LegacyJob.new])

    assert_equal 1, count
  end

  def test_enqueue_all_groups_by_class_queue_and_time
    later = Time.at(Time.now.to_i + 600)
    jobs = [BaseJob.new(1), OptionJob.new(2), BaseJob.new(3), BaseJob.new(4).tap { |j| j.scheduled_at = later }]

    assert_equal 4, assert_roundtrips(1) { adapter.enqueue_all(jobs) }
    assert(jobs.all?(&:successfully_enqueued?))
    assert_equal [1, 3], items.map { |j| j.args[0]["arguments"][0] }
    assert_equal [2], items("mail").map { |j| j.args[0]["arguments"][0] }
    scheduled = Robin::ScheduledSet.new.first

    assert_equal [4], scheduled.args[0]["arguments"]
    assert_in_delta later.to_f, scheduled.at.to_f, 0.01
    assert_equal jobs.map(&:provider_job_id).sort, (items + items("mail") + [scheduled]).map(&:jid).sort
    assert_equal ["AJUnit::OptionJob"], items("mail").map(&:display_class)
  end

  def test_enqueue_all_sets_nothing_on_jobs_if_their_push_fails
    jobs = [BaseJob.new(1), OptionJob.new(2)]
    config.redis_pool.shutdown
    port = TCPServer.new("127.0.0.1", 0).then { |server| server.addr[1].tap { server.close } }
    config.redis = {host: "127.0.0.1", port: port}

    assert_raises(Robin::Redis::ConnectionError) { adapter.enqueue_all(jobs) }
    assert_equal [nil, nil], jobs.map(&:provider_job_id)
  ensure
    config.redis_pool.shutdown
    config.redis = {url: REDIS_URL}
  end

  def test_enqueue_all_counts_only_enqueued
    config.client_middleware { |c| c.add Halt }
    jobs = [BaseJob.new(1), BaseJob.new(2)]

    assert_equal 0, adapter.enqueue_all(jobs)
    refute(jobs.any?(&:successfully_enqueued?))
    assert_nil jobs.first.provider_job_id
  end

  def test_stopping
    a = adapter

    assert_false a.stopping?
    a.stopping = true

    assert_true a.stopping?
    wrapper = Robin::ActiveJob::Wrapper.new
    Thread.current[:robin_active_job] = wrapper

    refute_predicate a, :stopping?
    wrapper.interrupt_requested = true

    assert_predicate a, :stopping?
  ensure
    Thread.current[:robin_active_job] = nil
  end

  def test_robin_job_cannot_be_included_in_active_job_classes
    aj = Class.new(ActiveJob::Base)
    error = assert_raises(ArgumentError) { aj.include(Robin::Job) }

    assert_equal "Robin::Job can't be included in ActiveJob classes", error.message
    refute_includes aj.ancestors, Robin::Job
    assert_raises(ArgumentError) { ActiveJob::Base.include(Robin::Job) }
    refute_includes ActiveJob::Base.ancestors, Robin::Job
    assert_includes Robin::Job.inclusion_checks, Robin::ActiveJob::REJECT_ACTIVE_JOB_CLASSES
    plain = Class.new { include Robin::Job }

    assert_includes plain.ancestors, Robin::Job
    assert_includes Module.new { include Robin::Job }.ancestors, Robin::Job
  end

  def test_adapter_file_loads_the_integration
    assert require("active_job/queue_adapters/robin_adapter") || true
    assert_kind_of ActiveJob::QueueAdapters::RobinAdapter, BaseJob.queue_adapter
  end
end
