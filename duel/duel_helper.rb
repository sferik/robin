# frozen_string_literal: true

# What Robin's benchmarks share: each file requires it, as tests do
# test_helper.rb.

require "logger"

module RobinPerf
  # Job classes the benchmarks define.
  module Jobs; end

  # A manager that keeps nothing.
  class QuietManager
    def work_started(*) = nil

    def work_finished(*) = nil
  end
end

# What every benchmark can call (methods defined here, at the top level,
# are every object's, so every duel's).

# A fresh Robin configuration on the worker's own Redis (emptied),
# logging job lines (to nowhere) as a server does by default.
def configure_robin(**settings)
  Robin.config.redis_pool.shutdown if Robin.instance_variable_get(:@config)
  Robin.config = Robin::Config.new
  Robin.configure do |config|
    config.redis = {url: Duel::Redis.url}
    config.logger = Logger.new(File::NULL, level: Logger::INFO)
    settings.each { |key, value| config.public_send(:"#{key}=", value) }
  end
  Duel::Redis.flush
  Robin.config
end

# A job class named +name+ (under RobinPerf::Jobs) running +perform+.
def define_job(name, options = {}, &perform)
  perform ||= proc { |*| }
  jobs = RobinPerf::Jobs
  jobs.send(:remove_const, name) if jobs.const_defined?(name, false)
  jobs.const_set(name, Class.new do
    include Robin::Job

    robin_options(options) unless options.empty?
    define_method(:perform, &perform)
  end)
end

# A worker's loop on the benchmark thread (Robin::Processor#work_once):
# fetch, run, and acknowledge with the next fetch.
def build_processor
  @fetcher = Robin::Fetcher.new(Robin.config.default_capsule, "perf")
  @processor = Robin::Processor.new(RobinPerf::QuietManager.new, Robin.config.default_capsule, @fetcher, 0)
end

def run_jobs(n) = n.times { @processor.work_once }
