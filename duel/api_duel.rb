# frozen_string_literal: true

require_relative "duel_helper"

# The data API: what watching a cluster costs.

setup do
  configure_robin
  job = define_job(:StatsJob)
  %w[default low high].each { |queue| job.set(queue: queue).perform_bulk(Array.new(10) { |i| [i] }) }
end

duel "api: the overview's stats" do
  Robin::Stats.new
end
