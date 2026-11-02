# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

# How many objects the paths every job takes may allocate, once warm (each
# runs first to fill caches): a change that allocates more fails here.
#
# The budgets are the most CRuby 3.4 and 4.0 took, with the C
# extension and without (ROBIN_NO_EXT=1). Re-measure with
# ROBIN_MEASURE_ALLOCATIONS=1, which prints each count instead.
class AllocationsTest < RobinTest
  include RuntimeTestHelpers

  # (What it costs to skip work a pipeline usually doesn't need.)
  cover "Robin::Redis::Connection#pipelined"

  NATIVE = !Robin::Redis::PARSER.equal?(Robin::Redis::RESP)

  class NoopJob
    include Robin::Job

    def perform(*) = nil
  end

  # A manager that keeps nothing.
  class QuietManager
    def work_started(*) = nil

    def work_finished(*) = nil
  end

  def setup
    super
    @fetcher = Robin::Fetcher.new(config.default_capsule, "me")
    @processor = Robin::Processor.new(QuietManager.new, config.default_capsule, @fetcher, 0)
  end

  def raw_job = JSON.generate({"class" => NoopJob.name, "args" => [1], "jid" => Robin.generate_jid, "queue" => "q"})

  # Runs the block warm, then asserts it allocates at most +native+
  # objects with the C (or Java) extension, +ruby+ without.
  def assert_budget(native:, ruby:, &block)
    3.times(&block)
    limit = NATIVE ? native : ruby
    return assert_allocations(count: 0..limit, &block) unless ENV["ROBIN_MEASURE_ALLOCATIONS"]

    counted = Minitest::Memory::AllocationCounter.count(&block).total.count
    puts "#{name} (#{NATIVE ? "native" : "ruby"}): #{counted} of #{limit}"
  end

  def test_a_job_id
    assert_budget(native: 1, ruby: 1) do
      Thread.current[:robin_jids]&.offset = 0 # never refilling
      Robin.generate_jid
    end
  end

  def test_encoding_a_push
    command = ["LPUSH", "robin:queue:default", raw_job]
    assert_budget(native: 1, ruby: 8) { Robin::Redis::ENCODER.encode(command, +"") }
  end

  def test_parsing_a_job
    reply = "$#{raw_job.bytesize}\r\n#{raw_job}\r\n"
    assert_budget(native: 2, ruby: 3) { Robin::Redis::PARSER.parse(reply, 0) }
  end

  def test_pushing_a_job
    assert_budget(native: 30, ruby: 50) { Robin::Client.push("class" => NoopJob, "args" => [1]) }
  end

  def test_taking_a_job_fetched_for_this_worker
    unit = unit_in_flight(@fetcher, raw_job)
    buffer = @fetcher.instance_variable_get(:@buffer)
    assert_budget(native: 1, ruby: 1) do
      buffer << [unit, 0]
      @fetcher.fetch
    end
  end

  def test_running_a_job
    units = Array.new(4) { unit_in_flight(@fetcher, raw_job, "q") }
    assert_budget(native: 18, ruby: 18) { @processor.send(:process, units.shift) }
  end

  def test_the_server_middleware_of_a_plain_job
    job = NoopJob.new
    payload = JSON.parse(raw_job)
    chain = config.server_middleware
    assert_budget(native: 2, ruby: 2) { chain.invoke(job, payload, "q") { nil } }
  end

  def test_recording_a_jobs_metrics
    collector = Robin::Metrics::Collector.new
    assert_budget(native: 0, ruby: 0) { collector.record(NoopJob.name, 1.5, true) }
  end

  def test_the_job_logger_when_job_lines_are_dropped
    config.logger = Logger.new(nil, level: Logger::WARN)
    logger = Robin::JobLogger.new(config)
    payload = JSON.parse(raw_job)
    assert_budget(native: 2, ruby: 2) { logger.call(payload) { nil } }
  end
end
