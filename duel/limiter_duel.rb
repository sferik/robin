# frozen_string_literal: true

require_relative "duel_helper"

# Rate limiters: what a job pays to run within a limit.

setup { configure_robin }

duel "limiter: run within a concurrent limit" do
  once { @limiter = Robin::Limiter.concurrent("perf", 10, wait_timeout: 1, lock_timeout: 30) }
  @limiter.within_limit { nil }
end

duel "limiter: run within a window limit" do
  once { @limiter = Robin::Limiter.window("perf", 1_000_000_000, :minute) }
  @limiter.within_limit { nil }
end
