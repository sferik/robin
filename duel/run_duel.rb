# frozen_string_literal: true

require_relative "duel_helper"

# Running jobs: what a server pays for every job it fetches, runs and
# acknowledges (on the benchmark thread, as one worker's loop does). Each
# sample's jobs are pushed first, untimed.

setup do
  configure_robin
  build_processor
end

duel "run: fetch, run and acknowledge a job" do |n|
  once { @job = define_job(:RunJob) }
  untimed { @job.perform_bulk(Array.new(n) { |i| [i, "two"] }) }
  run_jobs(n)
end

duel "run: a job with a 10 KB argument", peak_memory: true do |n|
  once do
    @job = define_job(:RunLargeJob)
    @arg = "x" * 10_240
  end
  untimed { @job.perform_bulk(Array.new(n) { [@arg] }) }
  run_jobs(n)
end

duel "run: a failing job, scheduled for retry" do |n|
  once { @job = define_job(:FailingJob) { |*| raise ArgumentError, "failed" } }
  untimed { @job.perform_bulk(Array.new(n) { |i| [i] }) }
  run_jobs(n)
end

duel "run: a unique job" do |n|
  once do
    @job = define_job(:RunUniqueJob, {"unique_for" => 3600})
    @n = 0
  end
  untimed { n.times { @job.perform_async(@n += 1) } }
  run_jobs(n)
end

duel "run: a job in a batch" do |n|
  once { @job = define_job(:RunBatchJob) }
  untimed { Robin::Batch.new.jobs { @job.perform_bulk(Array.new(n) { |i| [i] }) } }
  run_jobs(n)
end

duel "run: an encrypted job" do |n|
  once do
    configure_robin(encryption_keys: {1 => "k" * 32})
    build_processor
    @job = define_job(:RunEncryptedJob, {"encrypt" => true})
  end
  untimed { @job.perform_bulk(Array.new(n) { |i| [i, "secret"] }) }
  run_jobs(n)
end
