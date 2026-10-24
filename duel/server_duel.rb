# frozen_string_literal: true

require_relative "duel_helper"

# The whole server: 10 workers fetching in batches, the heartbeat and the
# scheduler, so its CPU is the process's, and its threads make its counts
# vary.

setup do
  configure_robin(concurrency: 10, timeout: 1, heartbeat_interval: 3600, poll_interval: 3600)
  done = @done = Thread::Queue.new
  @job = define_job(:ServerJob) { |*| done << true }
  Robin.server!
  Robin.config.redis = Robin.config.redis_options # sized for the workers
  @launcher = Robin::Launcher.new(Robin.config)
  @launcher.run
end

teardown { @launcher.stop }

duel "run: a server with 10 workers", only: :timing do |n|
  # Pushed out of the workers' sight, then handed to them all at once.
  untimed { @job.set(queue: "staging").perform_bulk(Array.new(n) { |i| [i] }) }
  Robin.redis { |c| c.call("RENAME", Robin.config.key("queue", "staging"), Robin.config.key("queue", "default")) }
  n.times { @done.pop }
end
