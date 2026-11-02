# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/web"

class WebPrometheusTest < RobinTest
  include WebTestHelpers

  cover "Robin::Web*"

  def run(...)
    at_fixed_time { super }
  end

  def metrics_text = get("/robin/metrics", {}, {"HTTP_ACCEPT" => "text/plain"}).body

  def stats_block(cluster, values)
    Robin::Web::Prometheus::STATS.zip(values).map do |(name, type, help, _), value|
      "# HELP #{name} #{help}\n# TYPE #{name} #{type}\n#{name}{cluster=\"#{cluster}\"} #{value}\n"
    end.join
  end

  def test_exposition
    enqueue_raw("low", "l1", enqueued_at: NOW - 2500)
    enqueue_raw("low", "l2")
    enqueue_raw("high", "h1", enqueued_at: NOW - 1000)
    redis("SET", "#{key_prefix_for_test}stat:processed", 7)
    redis("SET", "#{key_prefix_for_test}stat:failed", 2)
    add_entry("schedule", "s1")
    add_entry("retry", "r1")
    add_entry("retry", "r2")
    add_entry("dead", "d1")
    add_process("p1", busy: 3)
    body = metrics_text

    assert_equal 200, last_response.status
    assert_equal({"content-type" => "text/plain; version=0.0.4; charset=utf-8", "cache-control" => "no-store"},
      last_response.headers.to_h.slice("content-type", "cache-control"))
    assert_equal stats_block("default", [7, 2, 3, 1, 2, 1, 1, 3]) +
      "# HELP robin_queue_size Jobs waiting in a queue\n# TYPE robin_queue_size gauge\n" \
      "robin_queue_size{cluster=\"default\",queue=\"low\"} 2\n" \
      "robin_queue_size{cluster=\"default\",queue=\"high\"} 1\n" \
      "# HELP robin_queue_latency_seconds Age of the oldest job in a queue\n# TYPE robin_queue_latency_seconds gauge\n" \
      "robin_queue_latency_seconds{cluster=\"default\",queue=\"low\"} 2.5\n" \
      "robin_queue_latency_seconds{cluster=\"default\",queue=\"high\"} 1.0\n" \
      "# HELP robin_process_gvl_contention_percent Share of the time a process's threads could wait for the GVL " \
      "that they did\n# TYPE robin_process_gvl_contention_percent gauge\n", body
  end

  # Processes that measure it (with the C extension) report it.
  def test_gvl_contention_per_process
    add_process("p1")
    add_process("p2")
    add_process("p3")
    redis("HSET", "#{key_prefix_for_test}p1", "gvl", "12.5")
    redis("HSET", "#{key_prefix_for_test}p3", "gvl", "0.0")

    assert_includes metrics_text, "# TYPE robin_process_gvl_contention_percent gauge\n" \
      "robin_process_gvl_contention_percent{cluster=\"default\",process=\"p1\"} 12.5\n" \
      "robin_process_gvl_contention_percent{cluster=\"default\",process=\"p3\"} 0.0\n"
  end

  def test_every_cluster_is_labelled
    other = other_cluster
    Robin::Web.clusters = {"main" => config, "other" => other}
    Robin::Client.new(config: other).push("class" => "X", "args" => [], "queue" => "elsewhere")
    body = metrics_text

    assert_includes body, %(robin_jobs_enqueued{cluster="main"} 0\nrobin_jobs_enqueued{cluster="other"} 1\n)
    assert_includes body, %(robin_queue_size{cluster="other",queue="elsewhere"} 1\n)
    assert_equal 1, body.scan("# TYPE robin_queue_size gauge").size
  ensure
    other&.redis_pool&.shutdown
  end

  def test_empty_cluster
    body = metrics_text

    assert body.end_with?("# HELP robin_queue_size Jobs waiting in a queue\n# TYPE robin_queue_size gauge\n" \
      "# HELP robin_queue_latency_seconds Age of the oldest job in a queue\n# TYPE robin_queue_latency_seconds gauge\n" \
      "# HELP robin_process_gvl_contention_percent Share of the time a process's threads could wait for the GVL " \
      "that they did\n# TYPE robin_process_gvl_contention_percent gauge\n")
  end

  def test_label_values_are_escaped
    enqueue_raw(%(a"b\\c\nd"\n\\), "j1")

    assert_includes metrics_text, %(robin_queue_size{cluster="default",queue="a\\"b\\\\c\\nd\\"\\n\\\\"} 1\n)
  end

  def test_forbidden
    seen = []
    Robin::Web.authorize do |env, action, resource|
      seen << [action, resource]
      env["HTTP_X_ROLE"] == "ops"
    end
    get "/robin/metrics"

    assert_equal [403, "text/plain", "Forbidden"], [last_response.status, last_response.headers["content-type"], last_response.body]
    assert_equal [[:read, "/metrics"]], seen
    get "/robin/metrics", {}, {"HTTP_X_ROLE" => "ops"}

    assert_equal 200, last_response.status
  end
end
