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
  # How long a file may take (TEST_TIMEOUT, in seconds) before it's taken
  # to be stuck, and stopped: a hang fails the run, naming the file,
  # rather than lasting until CI's own limit.
  TIMEOUT = Float(ENV.fetch("TEST_TIMEOUT", 300))
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
      output, success = capture(env, file)
      results << Result.new(file, output, success, clock - started)
      $stdout.print(success ? "." : "F")
      $stdout.flush
    end
    results
  end

  # Runs +file+ in a process group of its own: its output and whether it
  # passed. One that outlasts TIMEOUT is killed with all it started, and
  # named at once (a CI log shows a line only once it ends).
  def capture(env, file)
    Open3.popen2e(env, RbConfig.ruby, "-Itest", "-Ilib", file, pgroup: true) do |stdin, out, wait|
      stdin.close
      reader = Thread.new { out.read }
      next [reader.value, wait.value.success?] if wait.join(TIMEOUT)

      begin
        Process.kill("KILL", -wait.pid)
      rescue Errno::ESRCH
        # (It ended just now.)
      end
      wait.join
      $stdout.puts "\n#{file} took over #{TIMEOUT.to_i}s: stopped"
      ["#{reader.value}\n#{file} took over #{TIMEOUT.to_i}s, and was stopped", false]
    end
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
