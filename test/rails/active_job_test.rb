# frozen_string_literal: true

require_relative "helper"
require "robin/active_job"

ActiveJob::Base.logger = Logger.new(nil)

module AJTest
  RAN = Queue.new

  class GreetJob < ActiveJob::Base
    queue_as :mail
    robin_options retry: 4, tags: ["greetings"]

    def perform(name, opts = {})
      RAN << [name, opts]
    end
  end
end

class ActiveJobAdapterTest < RobinTest
  include AJTest

  def setup
    super
    AJTest::GreetJob.queue_adapter = :robin
    RAN.clear
  end

  def test_adapter_lookup
    assert_kind_of ActiveJob::QueueAdapters::RobinAdapter, AJTest::GreetJob.queue_adapter
  end

  def test_enqueue_builds_wrapped_payload
    job = GreetJob.perform_later("ann", {"loud" => true})
    record = Robin::Queue.new("mail").first

    assert_equal "Robin::ActiveJob::Wrapper", record.klass
    assert_equal "AJTest::GreetJob", record.display_class
    assert_equal "AJTest::GreetJob", record["wrapped"]
    assert_equal "AJTest::GreetJob", Robin::JobRecord.new(record.item.except("display_class")).display_class
    assert_equal job.provider_job_id, record.jid
    assert_equal 4, record["retry"]
    assert_equal ["greetings"], record.tags
    assert_equal "ann", record.display_args.first
  end

  def test_enqueue_at
    GreetJob.set(wait: 120).perform_later("later")
    entry = Robin::ScheduledSet.new.first

    assert_in_delta Time.now + 120, entry.at, 2
    assert_equal "AJTest::GreetJob", entry.display_class
  end

  def test_enqueue_all
    jobs = [GreetJob.new("a"), GreetJob.new("b"), GreetJob.new("c")]
    ActiveJob.perform_all_later(jobs)

    assert(jobs.all?(&:successfully_enqueued?))
    assert_equal 3, Robin::Queue.new("mail").size
    assert_equal jobs.map(&:provider_job_id).sort, Robin::Queue.new("mail").map(&:jid).sort
  end

  def test_jobs_execute_in_server
    Robin.server!
    config.queues = ["mail"]
    config.heartbeat_interval = 0.2
    GreetJob.perform_later("bob", {"x" => 1})
    launcher = Robin::Launcher.new(config).run
    name, opts = RAN.pop(timeout: 5)
    launcher.stop

    assert_equal "bob", name
    assert_equal({"x" => 1}, opts)
  end
end

class ActiveJobAutoloadTest < Minitest::Test
  def test_the_wrapper_loads_on_demand
    lib = File.expand_path("../../lib", __dir__)
    script = 'require "robin/rails"; p [Robin.autoload?(:ActiveJob), Object.const_get("Robin::ActiveJob::Wrapper").name]'
    out = IO.popen([RbConfig.ruby, "-I#{lib}", "-e", script], err: File::NULL, &:read)

    assert_equal %(["robin/active_job", "Robin::ActiveJob::Wrapper"]\n), out
  end
end
