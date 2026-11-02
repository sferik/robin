# frozen_string_literal: true

# Pushes COUNT jobs of one kind through a system's bulk push, in batches
# of 1,000, and prints {"secs": ...}. A helper for the scenario benchmarks.
#
#   BUNDLE_GEMFILE=bench/compare/Gemfile ruby bench/compare/push.rb robin noop 100000
#
# Kinds:
#   noop   NoopJob with load.rb's arguments (a string, an integer, a hash)
#   sleep  SleepJob(idx, SLEEP), idx counting from 0; SLEEP defaults to 0.05

require_relative "support"

sys = Bench.system(ARGV.fetch(0))
kind = ARGV.fetch(1)
count = Integer(ARGV.fetch(2))
sys.boot
Bench::Jobs.define(sys)

klass, args = case kind
when "noop" then [NoopJob, ->(idx) { ["string", idx, {"mike" => "bob"}] }]
when "sleep"
  secs = Float(ENV.fetch("SLEEP", 0.05))
  [SleepJob, ->(idx) { [idx, secs] }]
else abort "unknown kind #{kind}"
end

start = Bench.now
count.times.each_slice(1_000) { |slice| sys.push_bulk(klass, slice.map(&args)) }
puts JSON.generate(secs: (Bench.now - start).round(3))
