# frozen_string_literal: true

require_relative "duel_helper"

# What a server does besides running jobs: moving scheduled jobs and
# retries onto their queues, heartbeats, and waiting for work.

setup { configure_robin }

duel "schedule: move due jobs onto their queues" do |n|
  once do
    @scheduler = Robin::Scheduler.new(Robin.config)
    @payload = JSON.generate({"class" => "Perf", "args" => [1, "two"], "queue" => "default"})
  end
  untimed { Robin.redis { |c| c.call("ZADD", Robin.config.key("schedule"), *Array.new(n) { |i| [1, @payload.sub("1", i.to_s)] }.flatten) } }
  @scheduler.enqueue_due
end

duel "heartbeat: one beat" do
  once do
    @launcher = Robin::Launcher.new(Robin.config)
    @launcher.instance_variable_set(:@started_at, Robin.now_ms)
  end
  @launcher.beat
end

# An idle worker's wait for a job that doesn't come: its CPU is too
# little to judge, but its round trips and commands count.
duel "idle: a fetch that waits for nothing", only: :count do
  once do
    configure_robin(fetch_timeout: 0.01)
    @fetcher = Robin::Fetcher.new(Robin.config.default_capsule, "perf")
  end
  @fetcher.fetch
end

# The leader's poll: it also works out when to wake for the next
# scheduled job, if that's sooner than its next poll.
duel "schedule: the leader's poll, with a job due later" do
  once do
    @scheduler = Robin::Scheduler.new(Robin.config)
    Robin::Leader.register(Robin.config, Struct.new(:leader?).new(true))
    define_job(:LaterJob).perform_in(30 * 86_400, 1) # never due during a run
  end
  @scheduler.enqueue_due
  @scheduler.interval
end

teardown { Robin::Leader.unregister(Robin.config) }
