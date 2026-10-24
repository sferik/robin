# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/web"

class WebTest < RobinTest
  cover "Robin::Web*"

  include WebTestHelpers

  def push(klass = "HardJob", args = [1], **opts)
    Robin::Client.push({"class" => klass, "args" => args}.merge(opts.transform_keys(&:to_s)))
  end

  def add_retry(error: "Boom", args: [1])
    jid = Robin.generate_jid
    at = Robin.epoch_seconds(Robin.now_ms + 60_000)
    payload = {"class" => "HardJob", "args" => args, "queue" => "default", "jid" => jid, "retry" => true,
               "created_at" => Robin.now_ms, "error_class" => "RuntimeError", "error_message" => error,
               "retry_count" => 1, "error_backtrace" => ["app/jobs/hard_job.rb:3"]}
    redis("ZADD", "#{key_prefix_for_test}retry", at, JSON.generate(payload))
    "#{at}-#{jid}"
  end

  # -- SPA & static ---------------------------------------------------------------

  def test_index_has_base_path_and_security_headers
    get "/robin/queues/default"

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<base href="/robin/">'
    assert_includes last_response.headers["content-security-policy"], "script-src 'self'"
    refute_includes last_response.body, "%ROBIN_"
  end

  def test_assets_are_cached_and_gzipped
    get "/robin/"
    asset = last_response.body[%r{assets/main-[\w-]+\.js}]

    assert asset, "index should reference a JS bundle"
    get "/robin/#{asset}", {}, {"HTTP_ACCEPT_ENCODING" => "gzip, br"}

    assert_equal 200, last_response.status
    assert_equal "gzip", last_response.headers["content-encoding"]
    assert_includes last_response.headers["cache-control"], "immutable"
    get "/robin/assets/../../web.rb"

    assert_equal 404, last_response.status
  end

  # -- API ------------------------------------------------------------------------

  def test_session
    get "/robin/api/session"

    assert_equal 200, last_response.status
    assert_equal Robin::VERSION, json["version"]
    assert json["permissions"]["delete"]
    assert_equal ["default"], json["clusters"]
    assert_equal "poll", json["live_updates"]
  end

  def test_dashboard_and_stats
    push
    push("Other", [], queue: "low")
    get "/robin/api/dashboard"

    assert_equal 200, last_response.status
    assert_equal 2, json["stats"]["enqueued"]
    assert_equal %w[default low], json["queues"].map { |q| q["name"] }.sort
    assert_equal 30, json["history"]["processed"].size
    get "/robin/api/stats"

    assert_equal({"default" => 1, "low" => 1}, json["queues"])
  end

  def test_queue_pagination_pause_delete_and_clear
    jids = Array.new(30) { |i| push("HardJob", [i]) }
    get "/robin/api/queues/default", per_page: 10, page: 1

    assert_equal 30, json["total"]
    assert_equal 10, json["jobs"].size
    assert_equal jids.first, json["jobs"].first["jid"], "page 1 starts with the next job to run"

    post_json "/robin/api/queues/default/pause"

    assert_predicate Robin::Queue.new("default"), :paused?
    post_json "/robin/api/queues/default/unpause"

    refute_predicate Robin::Queue.new("default"), :paused?

    post_json "/robin/api/queues/default/delete_jobs", {"jids" => jids.first(3)}

    assert_equal 3, json["deleted"]
    assert_equal 27, Robin::Queue.new("default").size

    delete "/robin/api/queues/default", {}, {"HTTP_X_ROBIN_REQUEST" => "1"}

    assert_equal 200, last_response.status
    assert_equal 0, Robin::Queue.new("default").size
  end

  def test_sets_list_search_show_and_bulk
    id = add_retry(error: "needle in haystack")
    add_retry(error: "something else")
    get "/robin/api/sets/retries"

    assert_equal 2, json["total"]
    get "/robin/api/sets/retries", q: "needle"

    assert_equal 1, json["total"]
    assert_equal "needle in haystack", json["jobs"].first["error_message"]

    get "/robin/api/sets/retries/#{id}"

    assert_equal ["app/jobs/hard_job.rb:3"], json["job"]["backtrace"]
    assert_equal 2, json["job"]["failures"]
    assert_equal "HardJob", json["job"]["payload"]["class"]

    post_json "/robin/api/sets/retries/bulk", {"action" => "retry", "ids" => [id]}

    assert_equal 1, json["affected"]
    assert_equal 1, Robin::RetrySet.new.size
    assert_equal 1, Robin::Queue.new("default").size

    post_json "/robin/api/sets/retries/all", {"action" => "kill"}

    assert_equal 1, json["affected"]
    assert_equal 1, Robin::DeadSet.new.size

    post_json "/robin/api/sets/dead/all", {"action" => "delete"}

    assert_equal 0, Robin::DeadSet.new.size

    post_json "/robin/api/sets/retries/bulk", {"action" => "explode", "ids" => []}

    assert_equal 400, last_response.status
    get "/robin/api/sets/nope"

    assert_equal 404, last_response.status
  end

  def test_edit_args_and_retry
    id = add_retry(args: [1, "old"])
    post_json "/robin/api/sets/retries/#{id}/edit", {"args" => [2, "new"]}

    assert_equal 200, last_response.status
    new_jid = json["jid"]

    assert_equal 0, Robin::RetrySet.new.size
    job = Robin::Queue.new("default").first

    assert_equal new_jid, job.jid
    assert_equal [2, "new"], job.args
    assert_nil job["error_class"]
    assert_nil job["retry_count"]
    assert job["edited_from"]

    id = add_retry
    post_json "/robin/api/sets/retries/#{id}/edit", {"args" => "nope"}

    assert_equal 422, last_response.status
  end

  def test_find_job_and_cancel
    jid = push
    get "/robin/api/jobs/#{jid}"

    assert_equal "queue", json["results"].first["where"]
    post_json "/robin/api/jobs/#{jid}/cancel"

    assert Robin::Cancellation.cancelled?(jid)
    get "/robin/api/jobs/#{jid}"

    assert json["cancelled"]
    get "/robin/api/jobs/missing"

    assert_empty json["results"]
  end

  def test_busy_and_process_signals
    identity = "host:1:abc"
    redis("SADD", "#{key_prefix_for_test}processes", identity)
    redis("HSET", "#{key_prefix_for_test}#{identity}", "info", JSON.generate({"hostname" => "host", "concurrency" => 5, "queues" => ["default"]}),
      "busy", 1, "beat", Time.now.to_f, "quiet", "false")
    job = JSON.generate({"class" => "HardJob", "args" => [], "jid" => "j1", "queue" => "default"})
    redis("HSET", "#{key_prefix_for_test}#{identity}:work", "t1", JSON.generate({"queue" => "default", "payload" => job, "run_at" => Time.now.to_f}))
    Robin::Progress.report("j1", 40, "almost")

    get "/robin/api/busy"

    assert_equal identity, json["processes"].first["identity"]
    assert_in_delta(40.0, json["work"].first["progress"]["pct"])

    post_json "/robin/api/processes/#{CGI.escape(identity)}/quiet"

    assert_equal 200, last_response.status
    assert_equal ["TSTP"], redis("LRANGE", "#{key_prefix_for_test}#{identity}-signals", 0, -1)
    post_json "/robin/api/processes/stop"

    assert_equal 1, json["signalled"]
    post_json "/robin/api/processes/#{CGI.escape(identity)}/explode"

    assert_equal 400, last_response.status
  end

  def test_metrics_endpoints
    collector = Robin::Metrics::Collector.new
    collector.record("HardJob", 12.0, true)
    collector.record("HardJob", 40.0, false)
    Robin.redis { |c| collector.flush(config, c) }
    get "/robin/api/metrics", minutes: 5

    assert_equal 1, json["classes"]["HardJob"]["s"]
    get "/robin/api/metrics/jobs/HardJob", minutes: 5

    assert_equal 1, json["histogram"].sum { |b| b["count"] } # successful runs only
    assert_equal 1, json["totals"]["f"]
    get "/robin/api/metrics/history", hours: 2

    assert_equal 200, last_response.status
    get "/robin/api/metrics/queues"

    assert_equal 60, json["points"].size
  end

  def test_optional_features_respond
    %w[batches limiters cron].each do |name|
      get "/robin/api/#{name}"

      assert_equal 200, last_response.status, name
      assert_includes json.keys, "available", name
    end
  end

  def test_info
    get "/robin/api/info"

    assert_equal 200, last_response.status
    assert json["redis"]["redis_version"]
    assert_equal key_prefix_for_test, json["robin"]["key_prefix"]
  end

  def test_unknown_endpoint
    get "/robin/api/nope"

    assert_equal 404, last_response.status
  end

  # -- CSRF, authorization, read-only ------------------------------------------

  def test_mutations_require_csrf_header
    push
    post "/robin/api/queues/default/pause", "{}", {"CONTENT_TYPE" => "application/json"}

    assert_equal 403, last_response.status
    refute_predicate Robin::Queue.new("default"), :paused?
  end

  def test_mutations_reject_cross_origin
    post_json "/robin/api/queues/default/pause", {}, {"HTTP_ORIGIN" => "https://evil.example"}

    assert_equal 403, last_response.status
    post_json "/robin/api/queues/default/pause", {}, {"HTTP_ORIGIN" => "http://example.org"}

    assert_equal 200, last_response.status
  end

  def test_mutations_check_fetch_metadata
    %w[cross-site same-site].each do |site|
      post_json "/robin/api/queues/default/pause", {}, {"HTTP_SEC_FETCH_SITE" => site}

      assert_equal 403, last_response.status, site
    end
    refute_predicate Robin::Queue.new("default"), :paused?
    ["same-origin", "none", ""].each do |site|
      post_json "/robin/api/queues/default/pause", {}, {"HTTP_SEC_FETCH_SITE" => site}

      assert_equal 200, last_response.status, site
    end
    get "/robin/api/session", {}, {"HTTP_SEC_FETCH_SITE" => "cross-site"}

    assert_equal 200, last_response.status
  end

  def test_read_only
    Robin::Web.read_only = true
    get "/robin/api/session"

    refute json["permissions"]["delete"]
    assert json["permissions"]["read"]
    post_json "/robin/api/queues/default/pause"

    assert_equal 403, last_response.status
    get "/robin/api/queues"

    assert_equal 200, last_response.status
  end

  def test_authorize_block_gets_fine_grained_actions
    seen = []
    Robin::Web.authorize do |env, action, resource|
      seen << [action, resource]
      env["HTTP_X_ROLE"] == "admin" || %i[read retry].include?(action)
    end
    id = add_retry
    post_json "/robin/api/sets/retries/bulk", {"action" => "delete", "ids" => [id]}

    assert_equal 403, last_response.status
    assert_includes seen, [:delete, "set:retries"]
    post_json "/robin/api/sets/retries/bulk", {"action" => "retry", "ids" => [id]}

    assert_equal 200, last_response.status
    post_json "/robin/api/queues/default/pause", {}, {"HTTP_X_ROLE" => "admin"}

    assert_equal 200, last_response.status

    Robin::Web.authorize { |_env, _action, _resource| false }
    get "/robin/api/stats"

    assert_equal 403, last_response.status
    get "/robin/metrics"

    assert_equal 403, last_response.status
  end

  # -- multi-cluster & Prometheus ----------------------------------------------

  def test_multiple_clusters
    other = Robin::Config.new
    other.redis = {url: REDIS_URL}
    other.key_prefix = "#{key_prefix_for_test}other:"
    other.logger = Logger.new(nil)
    Robin::Web.clusters = {"main" => config, "other" => other}
    push
    Robin::Client.new(config: other).push("class" => "X", "args" => [], "queue" => "elsewhere")

    get "/robin/api/session"

    assert_equal %w[main other], json["clusters"]
    get "/robin/api/queues"

    assert_equal ["default"], json["queues"].map { |q| q["name"] }
    get "/robin/api/queues", cluster: "other"

    assert_equal ["elsewhere"], json["queues"].map { |q| q["name"] }
    get "/robin/api/queues", cluster: "missing"

    assert_equal 404, last_response.status

    get "/robin/metrics"

    assert_includes last_response.body, %(robin_queue_size{cluster="other",queue="elsewhere"} 1)
  ensure
    other&.redis_pool&.shutdown
  end

  def test_health
    Robin::Web.authorize { false }
    clock = [10.0, 11.23456]
    Robin::Web.app.define_singleton_method(:monotonic_ms) { clock.shift }
    get "/robin/health"

    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.headers["content-type"]
    assert_equal "no-store", last_response.headers["cache-control"]
    assert_equal({"healthy" => true, "redis" => {"default" => {"ok" => true, "latency_ms" => 1.23}}}, json)
  end

  def test_health_with_an_unreachable_cluster
    down = Robin::Config.new
    down.redis = {url: "redis://127.0.0.1:1/0", connect_timeout: 0.2}
    Robin::Web.clusters = {"main" => config, "down" => down}
    get "/robin/health"

    assert_equal 503, last_response.status
    assert_equal({"ok" => true}, json["redis"]["main"].slice("ok"))
    # A real round trip, in milliseconds.
    assert_operator json["redis"]["main"]["latency_ms"], :>, 0
    assert_operator json["redis"]["main"]["latency_ms"], :<, 1000
    refute json["healthy"]
    refute json["redis"]["down"]["ok"]
    assert_match(/\ARobin::Redis::ConnectionError: Errno::ECONNREFUSED: .+ \(127\.0\.0\.1:1\/0\)\z/, json["redis"]["down"]["error"])
  ensure
    down&.redis_pool&.shutdown
  end

  def test_prometheus
    push
    push("HardJob", [], queue: "low")
    get "/robin/metrics", {}, {"HTTP_ACCEPT" => "text/plain"}

    assert_equal 200, last_response.status
    assert_match %r{text/plain; version=0.0.4}, last_response.headers["content-type"]
    body = last_response.body

    assert_includes body, "# TYPE robin_jobs_processed_total counter"
    assert_includes body, %(robin_jobs_enqueued{cluster="default"} 2)
    assert_includes body, %(robin_queue_size{cluster="default",queue="low"} 1)
    assert_match(/robin_queue_latency_seconds\{cluster="default",queue="default"\} [\d.]+/, body)

    get "/robin/metrics", {}, {"HTTP_ACCEPT" => "text/html,application/xhtml+xml"}

    assert_includes last_response.body, "<!doctype html>"
  end

  def test_stream_emits_stats_events
    Robin::Web.stream_interval = 0.01
    Robin::Web.stream_lifetime = 0.02
    get "/robin/api/stream"

    assert_equal "text/event-stream", last_response.headers["content-type"]
    assert_includes last_response.body, "event: stats\ndata: {"
  end
end
