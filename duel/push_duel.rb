# frozen_string_literal: true

require_relative "duel_helper"

# Pushing jobs: what every app pays for every job it enqueues.

setup do
  configure_robin
  @job = define_job(:PushJob)
end

duel "push: one job" do
  @job.perform_async(1, "two")
end

duel "push: one job scheduled for later" do
  @job.perform_in(3600, 1, "two")
end

duel "push: 100 jobs in bulk" do
  once { @args = Array.new(100) { |i| [i, "two"] } }
  @job.perform_bulk(@args)
end

duel "push: one job with a 10 KB argument", peak_memory: true do
  once { @large = "x" * 10_240 }
  @job.perform_async(@large)
end

duel "push: one unique job" do
  once do
    @unique = define_job(:UniqueJob, {"unique_for" => 3600})
    @n = 0
  end
  @unique.perform_async(@n += 1)
end

duel "push: a batch of 10 jobs" do
  Robin::Batch.new.jobs { 10.times { |i| @job.perform_async(i) } }
end

duel "push: one encrypted job" do
  once do
    configure_robin(encryption_keys: {1 => "k" * 32})
    @job = define_job(:EncryptedJob, {"encrypt" => true})
  end
  @job.perform_async(1, "secret")
end
