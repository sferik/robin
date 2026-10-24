# frozen_string_literal: true

# End-to-end throughput: push N no-op jobs, then process them with an
# in-process server and report jobs/second.
#
#   ruby -Ilib bench/throughput.rb                 # native parser if compiled
#   ROBIN_NO_EXT=1 ruby -Ilib bench/throughput.rb  # force the pure-Ruby parser
#
# Environment: JOBS (default 50000), CONCURRENCY (default 10),
# REDIS_URL (default redis://127.0.0.1:6379/15).

require "robin"

# A benchmark of the pure-Ruby parser is asked for, never fallen into.
if Robin::Redis::PARSER == Robin::Redis::RESP && ENV.fetch("ROBIN_NO_EXT", "").empty?
  abort "Robin's native extension isn't loaded; run `rake compile`, or set ROBIN_NO_EXT=1 to measure pure Ruby"
end

JOBS = Integer(ENV.fetch("JOBS", 50_000))
CONCURRENCY = Integer(ENV.fetch("CONCURRENCY", 10))
PREFIX = "robinbench:"

class NoopJob
  include Robin::Job

  COUNTER = Thread::Queue.new

  def perform(_n)
    COUNTER << 1
  end
end

def cleanup
  Robin.redis do |c|
    cursor = "0"
    loop do
      cursor, keys = c.call("SCAN", cursor, "MATCH", "#{PREFIX}*", "COUNT", 1000)
      c.call("UNLINK", *keys) unless keys.empty?
      break if cursor == "0"
    end
  end
end

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

Robin.configure do |config|
  config.redis = {url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/15")}
  config.key_prefix = PREFIX
  config.logger = Logger.new(nil)
  config.concurrency = CONCURRENCY
end
cleanup

puts "Robin #{Robin::VERSION} · #{RUBY_DESCRIPTION}"
puts "parser: #{Robin::Redis::PARSER} · jobs: #{JOBS} · concurrency: #{CONCURRENCY}"

# Push one at a time (the common perform_async path).
single = [JOBS / 5, 10_000].min
t = now
single.times { |i| NoopJob.perform_async(i) }
push_elapsed = now - t
puts format("perform_async:  %8.0f jobs/s (%d jobs)", single / push_elapsed, single)

# Bulk push the rest.
t = now
NoopJob.perform_bulk(Array.new(JOBS - single) { |i| [i] })
bulk_elapsed = now - t
puts format("perform_bulk:   %8.0f jobs/s (%d jobs)", (JOBS - single) / bulk_elapsed, JOBS - single)

Robin.server!
Robin.config.redis = Robin.config.redis_options # resize the pool for server use
launcher = Robin::Launcher.new(Robin.config)
t = now
launcher.run
JOBS.times { NoopJob::COUNTER.pop }
elapsed = now - t
puts format("processing:     %8.0f jobs/s (%.2fs for %d jobs)", JOBS / elapsed, elapsed, JOBS)
launcher.stop
cleanup
