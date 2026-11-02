# frozen_string_literal: true

require_relative "duel_helper"

# Periodic (cron) jobs: the leader checks every entry each time one may be
# due, and enqueues those whose tick it claims.

setup do
  configure_robin
  registry = Robin::Periodic::Registry.new
  10.times { |i| registry.register("* * * * *", "PerfCronJob", args: [i]) }
  @entries = registry.entries
  @crons = @entries.transform_values { |e| Robin::Cron.new(e.fetch("cron"), tz: e.fetch("tz")) }
  Robin::Periodic.write_registry(Robin.config, @entries)
  # Ticks from an hour on, a minute apart, each new to Redis.
  @now = Time.at((Time.now.to_i / 60 * 60) + 3600)
end

# Most checks: every entry's latest tick tried already, so nothing to
# claim and no round trip.
duel "periodic: a tick with nothing due" do
  once { Robin::Periodic.tick(Robin.config, @entries, @crons, @now, @claimed = {}) }
  Robin::Periodic.tick(Robin.config, @entries, @crons, @now, @claimed)
end

duel "periodic: a tick that enqueues 10 jobs" do
  Robin::Periodic.tick(Robin.config, @entries, @crons, @now += 60)
end
