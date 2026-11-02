# frozen_string_literal: true

require_relative "duel_helper"
require "robin/web"
require "stringio"

# The dashboard's requests, on a cluster of one server that has run jobs,
# with jobs in three queues and ten retries.

setup do
  configure_robin
  job = define_job(:WebJob)
  %w[default low high].each { |queue| job.set(queue: queue).perform_bulk(Array.new(10) { |i| [i] }) }
  retry_at = Robin.epoch_seconds(Robin.now_ms) + 3600
  Robin.redis do |c|
    c.call("ZADD", Robin.config.key("retry"), *Array.new(10) do |i|
      [retry_at, JSON.generate({"class" => "WebJob", "args" => [i], "queue" => "default", "jid" => "retry#{i}",
                                "retry_count" => 1, "error_class" => "RuntimeError", "error_message" => "failed"})]
    end.flatten)
  end
  launcher = Robin::Launcher.new(Robin.config)
  launcher.instance_variable_set(:@started_at, Robin.now_ms)
  10.times { |i| launcher.collector.record("WebJob", 10.0 + i, i != 0) }
  launcher.beat # registers the server, and its metrics
  @router = Robin::Web::Router.new
end

{
  "the dashboard's stats request" => "/api/stats",
  "the overview" => "/api/dashboard",
  "the queues" => "/api/queues",
  "a queue's first page" => "/api/queues/default",
  "the busy page" => "/api/busy",
  "the retries' first page" => "/api/sets/retries",
  "the metrics" => "/api/metrics"
}.each do |name, path|
  duel "web: #{name}" do
    once do
      @env = {"REQUEST_METHOD" => "GET", "PATH_INFO" => path, "QUERY_STRING" => "", "SCRIPT_NAME" => "",
              "rack.input" => StringIO.new(+"")}
    end
    @router.call(@env.dup)
  end
end
