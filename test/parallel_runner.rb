# frozen_string_literal: true

require "etc"
require "json"
require "open3"
require "rbconfig"

# Runs each test file in its own process, several at a time, slowest
# first (by the times recorded on the last run). Each process uses its own
# key prefix, so they share the test Redis safely. Used by `rake test`.
module ParallelRunner
  TIMES = "tmp/test-times.json"
  SUMMARY = /(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/

  Result = Struct.new(:file, :output, :success, :seconds)

  module_function

  def run(files, jobs: Integer(ENV.fetch("TEST_JOBS", Etc.nprocessors)))
    known = File.exist?(TIMES) ? JSON.parse(File.read(TIMES)) : {}
    # Unknown files first (they might be slow), then the slowest known.
    queue = Thread::Queue.new(files.sort_by { |f| [known.key?(f) ? 1 : 0, -known.fetch(f, File.size(f))] })
    queue.close
    started = clock
    results = Array.new([jobs, files.size].min) { Thread.new { work(queue) } }.flat_map(&:value)
    record(known, results)
    report(results, clock - started)
  end

  def work(queue)
    results = []
    while (file = queue.pop)
      started = clock
      env = {"ROBIN_TEST_PART" => File.basename(file, ".rb")}
      output, status = Open3.capture2e(env, RbConfig.ruby, "-Itest", "-Ilib", file)
      results << Result.new(file, output, status.success?, clock - started)
      $stdout.print(status.success? ? "." : "F")
      $stdout.flush
    end
    results
  end

  def record(known, results)
    Dir.mkdir("tmp") unless Dir.exist?("tmp")
    File.write(TIMES, JSON.pretty_generate(known.merge(results.to_h { |r| [r.file, r.seconds.round(2)] }).sort.to_h))
  end

  # Prints failures and totals; true if every file passed.
  def report(results, seconds)
    puts
    failed = results.reject(&:success)
    failed.each { |r| puts "\n#{"=" * 20} #{r.file}\n#{r.output}" }
    totals = results.filter_map { |r| r.output[SUMMARY]&.then { Regexp.last_match.captures.map(&:to_i) } }.transpose.map(&:sum)
    runs, assertions, failures, errors, skips = totals.empty? ? [0] * 5 : totals
    puts format("\n%d files in %.1fs: %d runs, %d assertions, %d failures, %d errors, %d skips",
      results.size, seconds, runs, assertions, failures, errors, skips)
    puts "Slowest: #{results.max_by(3, &:seconds).map { |r| format("%s %.1fs", r.file, r.seconds) }.join(", ")}"
    failed.empty?
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
