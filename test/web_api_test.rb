# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/web"
require "cgi"
require "zlib"

class WebApiTest < RobinTest
  include WebTestHelpers

  cover "Robin::Web*"

  class EchoJob
    include Robin::Job

    def perform(*) = nil
  end

  def run(...)
    at_fixed_time { super }
  end

  def job_hash(payload, **extra)
    {"jid" => payload["jid"], "class" => payload["class"], "wrapper" => nil, "queue" => payload["queue"],
     "args" => payload["args"], "created_at" => payload["created_at"], "enqueued_at" => payload["enqueued_at"],
     "tags" => [], "bid" => nil, "error_class" => nil, "error_message" => nil, "failures" => nil,
     "failed_at" => nil, "retried_at" => nil, "encrypted" => false}.merge(extra)
  end

  # -- session & overview ----------------------------------------------------------

  def test_session_defaults
    get "/robin/api/session"

    assert_json_response 200, {
      "title" => "Robin", "brand_color" => nil, "version" => Robin::VERSION, "read_only" => false,
      "permissions" => Robin::Web::Permissions::ACTIONS.keys.to_h { |a| [a.to_s, true] },
      "clusters" => ["default"], "cluster" => "default",
      "features" => {"batches" => true, "limiters" => true, "cron" => true},
      "stream_interval" => 2, "live_updates" => "poll", "extensions" => []
    }
  end

  def test_session_permissions_use_the_request
    Robin::Web.authorize { |env, action, _resource| action == :read || env["HTTP_X_ROLE"] == "admin" }
    get "/robin/api/session"

    assert_equal [true, false], json["permissions"].values_at("read", "kill")
    get "/robin/api/session", {}, {"HTTP_X_ROLE" => "admin"}

    assert_equal [true, true], json["permissions"].values_at("read", "kill")
  end

  def test_session_reflects_settings
    other = other_cluster
    Robin::Web.clusters = {"a" => config, "b" => other}
    Robin::Web.title = "Billing"
    Robin::Web.brand_color = "#c00"
    Robin::Web.read_only = 1
    Robin::Web.stream_interval = 5
    Robin::Web.live_updates = :stream
    get "/robin/api/session", cluster: "b"

    assert_equal ["Billing", "#c00", true, ["a", "b"], "b", 5, "stream"],
      json.values_at("title", "brand_color", "read_only", "clusters", "cluster", "stream_interval", "live_updates")
    assert_equal({"read" => true, "retry" => false}, json["permissions"].slice("read", "retry"))
  ensure
    other&.redis_pool&.shutdown
  end

  def test_dashboard
    collector = Robin::Metrics::Collector.new
    collector.record("HardJob", 12.0, true)
    Robin.redis { |c| collector.flush(config, c) }
    enqueue_raw("low", "l1", enqueued_at: NOW - 5000)
    enqueue_raw("low", "l2", enqueued_at: NOW - 1000)
    enqueue_raw("high", "h1", enqueued_at: NOW - 2000)
    Robin::Queue.new("high").pause!
    redis("SET", "#{key_prefix_for_test}leader", "boss")
    get "/robin/api/dashboard"

    assert_equal Robin::Stats.new.to_h, json["stats"]
    assert_equal [{"name" => "low", "size" => 2, "latency" => 5.0, "paused" => false},
      {"name" => "high", "size" => 1, "latency" => 2.0, "paused" => true}], json["queues"]
    assert_equal 30, json["history"]["processed"].size
    assert_equal 60, json["realtime"].size
    assert_equal({"t" => Robin::Metrics.minute_stamp(Time.now), "s" => 1, "f" => 0, "ms" => 12.0}, json["realtime"].last)
    assert_equal "boss", json["leader"]
    assert_equal %w[stats queues history realtime leader], json.keys
  end

  def test_dashboard_parameter_bounds
    {{days: 7, minutes: 10} => [7, 10], {days: 0, minutes: 1} => [1, 5], {days: 999, minutes: 9999} => [180, 480],
     {days: "x", minutes: "5.5"} => [30, 60]}.each do |params, (days, minutes)|
      get "/robin/api/dashboard", params

      assert_equal [days, minutes], [json["history"]["failed"].size, json["realtime"].size], params.inspect
    end
  end

  def test_stats
    enqueue_raw("default", "a")
    get "/robin/api/stats"

    assert_json_response 200, {"stats" => Robin::Stats.new.to_h, "queues" => {"default" => 1}, "at" => NOW}
  end

  def test_stream
    Robin::Web.stream_interval = 0.01
    Robin::Web.stream_lifetime = 0.025
    event = "event: stats\ndata: #{JSON.generate({"stats" => Robin::Stats.new.to_h, "queues" => {}, "at" => NOW})}\n\n"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    get "/robin/api/stream"
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 200, last_response.status
    assert_equal({"content-type" => "text/event-stream", "cache-control" => "no-cache", "x-accel-buffering" => "no"},
      last_response.headers.to_h.slice("content-type", "cache-control", "x-accel-buffering"))
    assert_equal "retry: 3000\n\n#{event * 3}", last_response.body
    assert_operator elapsed, :>=, 0.02
  end

  def test_stream_shorter_than_one_interval
    Robin::Web.stream_interval = 5
    Robin::Web.stream_lifetime = 2
    get "/robin/api/stream"

    assert_equal 1, last_response.body.scan("event: stats").size
  end

  def test_info
    config.dead_timeout = 3 * 86_400
    add_process("p1")
    redis("SET", "#{key_prefix_for_test}leader", "p1")
    with_stub(Robin::Web::API, :parse_info, ->(raw) { {"redis_version" => raw[/redis_version:([\d.]+)/, 1], "secret" => "x"} }) do
      get "/robin/api/info"
    end

    assert_json_response 200, {
      "redis" => {"redis_version" => redis("INFO", "server")[/redis_version:([\d.]+)/, 1]},
      "redis_url" => Robin::Redis::Connection.new(url: REDIS_URL).id,
      "robin" => {"version" => Robin::VERSION, "ruby" => RUBY_DESCRIPTION, "key_prefix" => key_prefix_for_test,
                  "max_retries" => 20, "dead_max_jobs" => 10_000, "dead_timeout_days" => 3,
                  "native_resp" => Robin::Redis::PARSER != Robin::Redis::RESP},
      "processes" => 1, "leader" => "p1"
    }
  end

  def test_info_rounds_the_dead_set_timeout_down_to_days
    config.dead_timeout = (4 * 86_400) - 1
    get "/robin/api/info"

    assert_equal 3, json["robin"]["dead_timeout_days"]
  end

  def test_info_reports_the_pure_ruby_parser
    with_constant(Robin::Redis, :PARSER, Robin::Redis::RESP) { get "/robin/api/info" }

    refute json["robin"]["native_resp"]
  end

  def test_parse_info
    raw = "# Server\r\nredis_version:8.1\r\nos:Darwin 27:x\r\n run_id:1\r\n\r\nempty:\r\n"

    assert_equal({"redis_version" => "8.1", "os" => "Darwin 27:x", " run_id" => "1", "empty" => ""},
      Robin::Web::API.parse_info(raw))
  end

  # -- queues ----------------------------------------------------------------------

  def test_queues
    enqueue_raw("default", "a", enqueued_at: NOW - 1500)
    get "/robin/api/queues"

    assert_json_response 200, {"queues" => [{"name" => "default", "size" => 1, "latency" => 1.5, "paused" => false}]}
  end

  def test_queue_pages
    payloads = Array.new(30) { |i| enqueue_raw("default", "j#{i}") }
    get "/robin/api/queues/default"

    assert_equal({"name" => "default", "size" => 30, "latency" => 0.0, "paused" => false}, json["queue"])
    assert_equal [1, 25, 30], json.values_at("page", "per_page", "total")
    assert_equal job_hash(payloads.first), json["jobs"].first
    get "/robin/api/queues/default", page: 2, per_page: 10

    assert_equal [2, 10], json.values_at("page", "per_page")
    assert_equal (10..19).map { |i| "j#{i}" }, json["jobs"].map { |j| j["jid"] }
    get "/robin/api/queues/default", page: 0, per_page: 0

    assert_equal [1, 1, ["j0"]], [json["page"], json["per_page"], json["jobs"].map { |j| j["jid"] }]
    get "/robin/api/queues/default", per_page: 900

    assert_equal [200, 30], [json["per_page"], json["jobs"].size]
  end

  def test_pause_unpause_and_clear
    enqueue_raw("default", "a")
    post_json "/robin/api/queues/default/pause"

    assert_json_response 200, {"paused" => true}
    assert_predicate Robin::Queue.new("default"), :paused?
    post_json "/robin/api/queues/default/unpause"

    assert_json_response 200, {"paused" => false}
    refute_predicate Robin::Queue.new("default"), :paused?
    delete_api "/robin/api/queues/default"

    assert_json_response 200, {"cleared" => true}
    assert_equal 0, Robin::Queue.new("default").size
  end

  def test_delete_queue_jobs
    %w[a b c d].each { |jid| enqueue_raw("default", jid) }
    # The queue's one page, then the deletes.
    assert_roundtrips(3) { post_json "/robin/api/queues/default/delete_jobs", {"jids" => %w[b d missing]} }

    assert_json_response 200, {"deleted" => 2}
    assert_equal %w[a c], Robin::Queue.new("default").map(&:jid)
    post_json "/robin/api/queues/default/delete_jobs", {"jids" => "a"}

    assert_json_response 200, {"deleted" => 1}
    post_json "/robin/api/queues/default/delete_jobs"

    assert_json_response 200, {"deleted" => 0}
  end

  def test_delete_queue_class
    enqueue_raw("default", "a")
    enqueue_raw("default", "b", class: "Other")
    enqueue_raw("default", "c", class: "Robin::ActiveJob::Wrapper", display_class: "Mailer")
    post_json "/robin/api/queues/default/delete_class", {"class" => "HardJob"}

    assert_json_response 200, {"deleted" => 1}
    post_json "/robin/api/queues/default/delete_class", {"class" => "Mailer"}

    assert_json_response 200, {"deleted" => 1}
    assert_equal %w[b], Robin::Queue.new("default").map(&:jid)
    [{}, {"class" => ""}, {"class" => ["Other"]}].each do |body|
      post_json "/robin/api/queues/default/delete_class", body

      assert_error 400, "A class name is required"
    end
    assert_equal 1, Robin::Queue.new("default").size
  end

  FakeJob = Struct.new(:jid)

  def test_delete_queue_jobs_stops_once_everything_is_found
    jobs = [FakeJob.new("a"), FakeJob.new("b"), FakeJob.new("c")]
    queue = Object.new
    queue.define_singleton_method(:each) do |&block|
      jobs.each(&block)
      raise "walked past the last wanted job"
    end
    queue.define_singleton_method(:delete_jobs) { |found| found.map(&:jid).join.length }
    with_stub(Robin::Queue, :new, ->(name, config:) { (name == "q") ? queue : flunk }) do
      post_json "/robin/api/queues/q/delete_jobs", {"jids" => %w[a c]}
    end

    assert_json_response 200, {"deleted" => 2}
  end

  # The round trips behind each page of the dashboard, with a few of
  # everything in Redis: none grows with how much there is.
  def test_each_endpoint_makes_a_fixed_number_of_round_trips
    3.times { |i| add_process("p#{i}", busy: 1) }
    %w[a b c].each { |q| 5.times { |i| enqueue_raw(q, "#{q}#{i}") } }
    3.times do |i|
      %w[retry dead schedule].each { |set| add_entry(set, "#{set}#{i}") }
      Robin::Batch.new.jobs { Robin::Client.push("class" => "X", "args" => [i]) }
      Robin::Limiter.concurrent("l#{i}", 2).within_limit {}
    end
    trips = {"stats" => 1, "dashboard" => 5, "info" => 3, "queues" => 2, "queues/a" => 2, "busy" => 3, "sets/retries" => 1,
             "sets/dead" => 1, "sets/scheduled" => 1, "batches" => 2, "limiters" => 2, "metrics" => 2, "metrics/history" => 2,
             "metrics/queues" => 1, "cron" => 2, "profiles" => 1}
    trips.each do |path, count|
      assert_roundtrips(count) { get "/robin/api/#{path}" }
      assert_equal 200, last_response.status, path
    end
  end

  # -- processes -------------------------------------------------------------------

  def test_busy
    add_process("p1", busy: 2)
    working = {"class" => "HardJob", "args" => [1], "jid" => "w1", "queue" => "default"}
    idle = {"class" => "Robin::ActiveJob::Wrapper", "display_class" => "Mailer", "args" => [], "jid" => "w2", "queue" => "q"}
    wrapped = {"class" => "Robin::ActiveJob::Wrapper", "wrapped" => "ReportJob", "args" => [], "jid" => "w3", "queue" => "q"}
    legacy = {"class" => "Robin::ActiveJob::Wrapper", "wrapped" => true, "args" => [], "jid" => "w4", "queue" => "q"}
    add_work("p1", "t1", "fetched-from", working, NOW - 10)
    add_work("p1", "t2", "q", idle, NOW - 20)
    add_work("p1", "t3", "q", wrapped, NOW - 30)
    redis("HSET", "#{key_prefix_for_test}p1:work", "t4", JSON.generate({"queue" => "q", "payload" => legacy, "run_at" => 1.5}))
    Robin::Progress.report("w1", 40, "almost")
    redis("SET", "#{key_prefix_for_test}leader", "p1")
    get "/robin/api/busy"

    assert_equal [{"hostname" => "h", "concurrency" => 5, "started_at" => NOW - 60_000,
                   "capsules" => {"default" => {"concurrency" => 5, "queues" => {"default" => 2, "low" => 1}}},
                   "identity" => "p1", "busy" => 2, "beat" => NOW, "quiet" => false, "leader" => false,
                   "rss_kb" => 0, "rtt_us" => 0}], json["processes"]
    assert_equal "p1", json["leader"]
    work = json["work"].sort_by { |w| w["thread"] }

    assert_equal({"identity" => "p1", "thread" => "t1", "queue" => "fetched-from", "run_at" => NOW - 10,
                  "job" => job_hash(working, "queue" => "fetched-from", "created_at" => nil, "enqueued_at" => nil),
                  "progress" => {"pct" => 40.0, "msg" => "almost", "at" => NOW}}, work[0])
    assert_equal [["Mailer", "Robin::ActiveJob::Wrapper", nil, NOW - 20], ["ReportJob", "Robin::ActiveJob::Wrapper", nil, NOW - 30],
      ["Robin::ActiveJob::Wrapper", nil, nil, 1500]],
      work.drop(1).map { |w| [w["job"]["class"], w["job"]["wrapper"], w["progress"], w["run_at"]] }
  end

  def test_signal_one_process
    add_process("h:1")
    add_process("h:2")
    {"quiet" => "TSTP", "stop" => "TERM", "dump" => "TTIN"}.each do |signal, recorded|
      post_json "/robin/api/processes/h%3A1/#{signal}"

      assert_json_response 200, {"signalled" => 1}
      assert_equal recorded, signals_for("h:1").first
    end
    assert_equal %w[TTIN TERM TSTP], signals_for("h:1")
    assert_empty signals_for("h:2")
    post_json "/robin/api/processes/h%3A9/quiet"

    assert_error 404, "No live process h:9"
    post_json "/robin/api/processes/h%3A9/explode"

    assert_error 400, %(Unknown signal "explode")
  end

  def test_resize_a_process
    add_process("h:1")
    add_process("h:2")
    post_json "/robin/api/processes/h%3A1/resize", {"concurrency" => 8}

    assert_json_response 200, {"resized" => 1}
    post_json "/robin/api/processes/h%3A1/resize", {"concurrency" => 1, "capsule" => "default"}

    assert_json_response 200, {"resized" => 1}
    post_json "/robin/api/processes/h%3A1/resize", {"concurrency" => 1000}

    assert_json_response 200, {"resized" => 1}
    assert_equal ["RESIZE 1000 default", "RESIZE 1 default", "RESIZE 8 default"], signals_for("h:1")
    assert_empty signals_for("h:2")
  end

  def test_resize_a_capsule
    add_process("h:1")
    info = JSON.parse(redis("HGET", "#{key_prefix_for_test}h:1", "info"))
    info["capsules"]["bulk"] = {"concurrency" => 2, "mode" => "strict", "weights" => {"bulk" => 0}}
    redis("HSET", "#{key_prefix_for_test}h:1", "info", JSON.generate(info))
    post_json "/robin/api/processes/h%3A1/resize", {"concurrency" => 4, "capsule" => "bulk"}

    assert_json_response 200, {"resized" => 1}
    assert_equal ["RESIZE 4 bulk"], signals_for("h:1")
  end

  def test_resize_rejects_bad_requests
    add_process("h:1")
    [{}, {"concurrency" => 0}, {"concurrency" => 1001}, {"concurrency" => "4"}, {"concurrency" => 2.5}, {"concurrency" => nil}].each do |body|
      post_json "/robin/api/processes/h%3A1/resize", body

      assert_error 400, "concurrency must be a whole number from 1 to 1000"
    end
    post_json "/robin/api/processes/h%3A1/resize", {"concurrency" => 2, "capsule" => "bulk"}

    assert_error 400, %(Process h:1 has no capsule "bulk")
    post_json "/robin/api/processes/h%3A1/resize", {"concurrency" => 2, "capsule" => nil}

    assert_error 400, "Process h:1 has no capsule nil"
    post_json "/robin/api/processes/h%3A9/resize", {"concurrency" => 0}

    assert_error 404, "No live process h:9"
    assert_empty signals_for("h:1")
  end

  def test_resize_needs_the_process_to_report_its_capsules
    redis("SADD", "#{key_prefix_for_test}processes", "old:1")
    redis("HSET", "#{key_prefix_for_test}old:1", "info", JSON.generate({"concurrency" => 5}), "beat", Robin.epoch_seconds(NOW))
    post_json "/robin/api/processes/old%3A1/resize", {"concurrency" => 2}

    assert_error 400, %(Process old:1 has no capsule "default")
    assert_empty signals_for("old:1")
  end

  def test_resize_needs_process_control
    add_process("h:1")
    Robin::Web.authorize { |_env, action, _resource| action != :process_control }
    post_json "/robin/api/processes/h%3A1/resize", {"concurrency" => 2}

    assert_equal 403, last_response.status
    assert_empty signals_for("h:1")
  end

  def test_signal_all_processes
    add_process("h:1")
    add_process("h:2")
    post_json "/robin/api/processes/quiet"

    assert_json_response 200, {"signalled" => 2}
    assert_equal [["TSTP"], ["TSTP"]], [signals_for("h:1"), signals_for("h:2")]
    post_json "/robin/api/processes/explode"

    assert_error 400, %(Unknown signal "explode")
    assert_equal ["TSTP"], signals_for("h:1")
  end

  # -- sets ------------------------------------------------------------------------

  def test_set_listing_order
    ids = [3, 1, 2].map { |n| add_entry("retry", "r#{n}", at: NOW + n) }
    get "/robin/api/sets/retries", per_page: 2

    assert_equal ["retries", 1, 2, 3, ""], json.values_at("set", "page", "per_page", "total", "query")
    assert_equal ["1800000000.001-r1", "1800000000.002-r2"], [ids[1], ids[2]]
    assert_equal [ids[1], ids[2]], json["jobs"].map { |j| j["id"] }
    [3, 1, 2].each { |n| add_entry("dead", "d#{n}", at: NOW - n) }
    get "/robin/api/sets/dead"

    assert_equal %w[d1 d2 d3], json["jobs"].map { |j| j["jid"] }
  end

  def test_set_entry_json
    id = add_entry("retry", "r1", {"bid" => "b1", "tags" => ["t"], "failed_at" => 1, "retried_at" => 2, "enqueued_at" => 3},
      at: NOW + 5)
    get "/robin/api/sets/retries/#{id}"
    item = Robin::RetrySet.new.first.item

    assert_json_response 200, {"job" => {
      "jid" => "r1", "class" => "HardJob", "wrapper" => nil, "queue" => "default", "args" => [1],
      "created_at" => NOW - 1000, "enqueued_at" => 3, "tags" => ["t"], "bid" => "b1", "error_class" => "RuntimeError",
      "error_message" => "Boom r1", "failures" => 2, "failed_at" => 1, "retried_at" => 2, "encrypted" => false,
      "id" => id, "at" => NOW + 5, "payload" => item, "backtrace" => ["app/jobs/hard_job.rb:3"], "info" => []
    }}
    assert_kind_of Integer, json["job"]["at"]
  end

  def test_job_info_rows
    handled = []
    config.error_handlers.replace([->(ex, ctx, _) { handled << [ex.message, ctx] }])
    Robin::Web.job_info(:Customer) { |job| {text: "##{job["args"].first}", href: "/admin/customers/#{job["args"].first}"} }
    Robin::Web.job_info("Docs") { |_| {"href" => "HTTPS://example.com/d"} }
    Robin::Web.job_info("Count") { |job| job["args"].size }
    Robin::Web.job_info("Unsafe") { |_| {text: "x", href: "javascript:alert(1)"} }
    Robin::Web.job_info("Elsewhere") { |_| {text: "y", href: "//evil.example"} }
    Robin::Web.job_info("Other") { |_| {"text" => "z", "href" => "https://ok.example"} }
    Robin::Web.job_info("Hidden") { |_| nil }
    Robin::Web.job_info("Plain") { |_| Class.new(Hash).new.merge!(text: 5) }
    Robin::Web.job_info("Path") { |_| {text: "u", href: Class.new { def to_s = "/path" }.new} }
    Robin::Web.job_info("Broken") { |_| raise "bug" }
    id = add_entry("retry", "r1", at: NOW + 5)
    get "/robin/api/sets/retries/#{id}"

    assert_equal [
      {"label" => "Customer", "text" => "#1", "href" => "/admin/customers/1"},
      {"label" => "Docs", "text" => "HTTPS://example.com/d", "href" => "HTTPS://example.com/d"},
      {"label" => "Count", "text" => "1"},
      {"label" => "Unsafe", "text" => "x"},
      {"label" => "Elsewhere", "text" => "y"},
      {"label" => "Other", "text" => "z", "href" => "https://ok.example"},
      {"label" => "Plain", "text" => "5"},
      {"label" => "Path", "text" => "u", "href" => "/path"}
    ], json["job"]["info"]
    assert_equal [["bug", {context: "Robin::Web.job_info \"Broken\"", job: Robin::RetrySet.new.first.item}]], handled
    get "/robin/api/sets/retries"

    refute json["jobs"].first.key?("info")
  end

  def test_job_info_needs_a_block_and_replaces_by_label
    error = assert_raises(ArgumentError) { Robin::Web.job_info("x") }
    assert_equal "job_info needs a block", error.message
    first = proc { 1 }
    second = proc { 2 }
    Robin::Web.job_info("x", &first)
    Robin::Web.job_info(:x, &second)

    assert_equal({"x" => second}, Robin::Web.job_info_rows)
    Robin::Web.reset!

    assert_empty Robin::Web.job_info_rows
  end

  def test_encrypted_entries_hide_arguments
    id = add_entry("dead", "e1", {"encrypted" => 1, "args" => ["ciphertext"]})
    get "/robin/api/sets/dead/#{id}"

    assert_equal [["[encrypted]"], true, ["[encrypted]"]],
      [json["job"]["args"], json["job"]["encrypted"], json["job"]["payload"]["args"]]
  end

  def test_missing_set_entries
    get "/robin/api/sets/retries/1-nope"

    assert_error 404, "That job is no longer in the retries set"
    get "/robin/api/sets/nope"

    assert_error 404, %(Unknown set "nope")
  end

  def test_set_search
    add_entry("dead", "d1", {"error_message" => "needle 1"}, at: NOW - 3)
    add_entry("dead", "d2", {"error_message" => "needle 2"}, at: NOW - 1)
    add_entry("dead", "d3", {"error_message" => "needle 3"}, at: NOW - 2)
    add_entry("dead", "x", {"error_message" => "hay"}, at: NOW)
    get "/robin/api/sets/dead", q: "  needle ", per_page: 2

    assert_equal [3, "needle", %w[d2 d3]], [json["total"], json["query"], json["jobs"].map { |j| j["jid"] }]
    get "/robin/api/sets/dead", q: "needle", per_page: 2, page: 2

    assert_equal %w[d1], json["jobs"].map { |j| j["jid"] }
    get "/robin/api/sets/dead", q: "needle", per_page: 2, page: 3

    assert_empty json["jobs"]
    add_entry("retry", "r2", {"error_message" => "needle"}, at: NOW + 2)
    add_entry("retry", "r1", {"error_message" => "needle"}, at: NOW + 1)
    get "/robin/api/sets/retries", q: "needle"

    assert_equal %w[r1 r2], json["jobs"].map { |j| j["jid"] }
  end

  def test_set_search_limit
    entries = Array.new(Robin::Web::API::SEARCH_LIMIT + 1) { |i| [Robin.epoch_seconds(NOW + i), JSON.generate({"jid" => "n#{i}", "class" => "X"})] }
    redis("ZADD", "#{key_prefix_for_test}schedule", *entries.flatten)
    get "/robin/api/sets/scheduled", q: "X"

    assert_equal Robin::Web::API::SEARCH_LIMIT, json["total"]
    assert_operator Robin::Web::API::SEARCH_LIMIT, :>, 500
  end

  def test_bulk_actions
    r1 = add_entry("retry", "r1")
    r2 = add_entry("retry", "r2")
    r3 = add_entry("retry", "r3")
    # Finding them, taking them out of the set, pushing them.
    assert_roundtrips(3) { post_json "/robin/api/sets/retries/bulk", {"action" => "retry", "ids" => [r1, "1-missing"]} }

    assert_json_response 200, {"affected" => 1}
    assert_equal ["r1"], Robin::Queue.new("default").map(&:jid)
    post_json "/robin/api/sets/retries/bulk", {"action" => "delete", "ids" => [r2]}

    assert_json_response 200, {"affected" => 1}
    post_json "/robin/api/sets/retries/bulk", {"action" => "kill", "ids" => [r3]}

    assert_json_response 200, {"affected" => 1}
    assert_equal ["r3"], Robin::DeadSet.new.map(&:jid)
    assert_equal 0, Robin::RetrySet.new.size
    dead = Robin::DeadSet.new.first.id
    post_json "/robin/api/sets/dead/bulk", {"action" => "kill", "ids" => [dead]}

    assert_json_response 200, {"affected" => 0}
    post_json "/robin/api/sets/dead/bulk", {"action" => "retry"}

    assert_json_response 200, {"affected" => 0}
    post_json "/robin/api/sets/dead/bulk", {"action" => "explode"}

    assert_error 400, %(Unknown action "explode")
    post_json "/robin/api/sets/nope/bulk", {"action" => "retry"}

    assert_error 404, %(Unknown set "nope")
  end

  def test_delete_all_drops_the_set_at_once
    add_entry("retry", "r1")
    add_entry("retry", "r2")
    Robin::JobSet.alias_method(:__robin_drain_pages, :drain_pages)
    Robin::JobSet.define_method(:drain_pages) { |*| raise "deleting everything shouldn't go page by page" }
    begin
      assert_roundtrips(2) { post_json "/robin/api/sets/retries/all", {"action" => "delete"} } # its size, then it goes
    ensure
      Robin::JobSet.alias_method(:drain_pages, :__robin_drain_pages)
      Robin::JobSet.remove_method(:__robin_drain_pages)
    end

    assert_json_response 200, {"affected" => 2}
    assert_equal 0, Robin::RetrySet.new.size
  end

  def test_act_on_whole_set
    entries = Array.new(150) { |i| [Robin.epoch_seconds(NOW + i), JSON.generate({"jid" => "r#{i}", "class" => "X", "args" => [], "queue" => "q"})] }
    redis("ZADD", "#{key_prefix_for_test}retry", *entries.flatten)
    # The set's size, then three round trips for each page of 100.
    assert_roundtrips(7) { post_json "/robin/api/sets/retries/all", {"action" => "kill"} }

    assert_json_response 200, {"affected" => 150}
    assert_equal [0, 150], [Robin::RetrySet.new.size, Robin::DeadSet.new.size]
    post_json "/robin/api/sets/dead/all", {"action" => "kill"}

    assert_json_response 200, {"affected" => 0}
    post_json "/robin/api/sets/dead/all", {"action" => "retry"}

    assert_json_response 200, {"affected" => 150}
    assert_equal 150, Robin::Queue.new("q").size
    add_entry("schedule", "s1")
    add_entry("schedule", "s2")
    post_json "/robin/api/sets/scheduled/all", {"action" => "delete"}

    assert_json_response 200, {"affected" => 2}
    assert_equal 0, Robin::ScheduledSet.new.size
    post_json "/robin/api/sets/scheduled/all", {"action" => "nope"}

    assert_error 400, %(Unknown action "nope")
  end

  def test_deleting_a_whole_set_does_not_walk_it
    add_entry("dead", "d1")
    set = Robin::DeadSet.new
    set.define_singleton_method(:each) { |*| raise "walked the set" }
    with_stub(Robin::DeadSet, :new, ->(config:) { set }) do
      post_json "/robin/api/sets/dead/all", {"action" => "delete"}
    end

    assert_json_response 200, {"affected" => 1}
    assert_equal 0, Robin::DeadSet.new.size
  end

  def test_whole_set_actions_need_permission
    add_entry("retry", "r1")
    Robin::Web.authorize { |_env, action, _resource| action == :read }
    post_json "/robin/api/sets/retries/all", {"action" => "delete"}

    assert_error 403, "You don't have permission to delete jobs and clear queues"
    assert_equal 1, Robin::RetrySet.new.size
  end

  def test_edit_entry
    id = add_entry("retry", "r1", {"args" => [1, "old"], "tags" => ["t"], "at" => 5, "enqueued_at" => 6, "failed_at" => 7, "retried_at" => 8})
    post_json "/robin/api/sets/retries/#{id}/edit", {"args" => [2, "new"]}

    assert_equal 200, last_response.status
    job = Robin::Queue.new("default").first

    assert_equal({"jid" => job.jid}, json)
    refute_equal "r1", job.jid
    assert_equal({"class" => "HardJob", "args" => [2, "new"], "queue" => "default", "jid" => job.jid, "retry" => true,
                  "created_at" => NOW - 1000, "tags" => ["t"], "edited_from" => "r1", "enqueued_at" => NOW}, job.item)
    assert_equal 0, Robin::RetrySet.new.size
  end

  def test_edit_entry_rejections
    id = add_entry("dead", "e1", {"encrypted" => 1})
    post_json "/robin/api/sets/dead/#{id}/edit", {"args" => []}

    assert_error 422, "Encrypted jobs can't be edited"
    id = add_entry("dead", "d1")
    post_json "/robin/api/sets/dead/#{id}/edit", {"args" => "nope"}

    assert_error 422, "args must be a JSON array"
    post_json "/robin/api/sets/dead/#{id}/edit"

    assert_error 422, "args must be a JSON array"
    assert_equal 2, Robin::DeadSet.new.size
  end

  def test_edit_entry_lost_race
    id = add_entry("dead", "d1")
    entry = Robin::DeadSet.new.first
    entry.define_singleton_method(:delete) { false }
    set = Robin::DeadSet.new
    set.define_singleton_method(:find_by_id) { |wanted| (wanted == id) ? entry : nil }
    with_stub(Robin::DeadSet, :new, ->(config:) { set }) do
      post_json "/robin/api/sets/dead/#{id}/edit", {"args" => []}
    end

    assert_error 409, "That job is no longer in the set"
    assert_equal 0, Robin::Queue.new("default").size
  end

  # -- job lookup ------------------------------------------------------------------

  def test_find_job_everywhere
    add_process("p1")
    running = {"class" => "HardJob", "args" => [], "jid" => "j1", "queue" => "q"}
    add_work("p1", "t1", "work-q", running, NOW)
    add_work("p1", "t2", "q", running.merge("jid" => "other"), NOW)
    add_entry("retry", "j1", at: NOW + 1)
    queued = enqueue_raw("default", "j1")
    Robin::Progress.report("j1", 10)
    get "/robin/api/jobs/j1"
    retry_entry = Robin::RetrySet.new.first

    assert_equal ["j1", {"pct" => 10.0, "msg" => nil, "at" => NOW}, false], json.values_at("jid", "progress", "cancelled")
    assert_equal [
      {"where" => "busy", "identity" => "p1", "thread" => "t1",
       "job" => job_hash(running, "queue" => "work-q", "created_at" => nil, "enqueued_at" => nil, "payload" => running,
         "backtrace" => nil, "info" => [])},
      {"where" => "retries", "job" => JSON.parse(JSON.generate(retry_entry.to_h["item"])).then do |item|
        job_hash(item, "error_class" => "RuntimeError", "error_message" => "Boom j1", "failures" => 2, "id" => retry_entry.id,
          "at" => NOW + 1, "payload" => item, "backtrace" => ["app/jobs/hard_job.rb:3"], "info" => [])
      end}
    ], json["results"]
    refute_includes json["results"].map { |r| r["where"] }, "queue", "queues are only searched as a last resort: #{queued}"
  end

  def test_find_job_in_queues
    queued = enqueue_raw("default", "j1")
    enqueue_raw("default", "j2")
    Robin.cancel!("j1")
    get "/robin/api/jobs/j1"

    assert_equal [{"where" => "queue", "queue" => "default", "job" => job_hash(queued, "payload" => queued, "backtrace" => nil, "info" => [])}],
      json["results"]
    assert_equal [nil, true], json.values_at("progress", "cancelled")
    get "/robin/api/jobs/missing"

    assert_equal [], json["results"]
  end

  def test_find_job_skips_huge_queues
    enqueue_raw("small", "s1")
    enqueue_raw("big", "b1")
    enqueue_raw("big", "b2")
    with_constant(Robin::JobLocator, :QUEUE_LIMIT, 1) do
      get "/robin/api/jobs/b1"

      assert_empty json["results"]
      get "/robin/api/jobs/s1"

      assert_equal ["small"], json["results"].map { |r| r["queue"] }
    end
  end

  # -- profiles ---------------------------------------------------------------------

  def store_profile(jid, at: NOW)
    entry = {"jid" => jid, "class" => "SlowJob", "queue" => "q", "label" => nil, "started_at" => at,
             "duration_ms" => 12, "ok" => true, "bytes" => 30}
    redis("SET", "#{key_prefix_for_test}profile:#{jid}", Zlib.gzip(%({"meta":{"jid":"#{jid}"}})))
    redis("ZADD", "#{key_prefix_for_test}profiles", at, JSON.generate(entry))
    entry
  end

  def test_profiles
    older = store_profile("p1", at: NOW - 10)
    newer = store_profile("p2")
    get "/robin/api/profiles"

    assert_json_response 200, {"profiles" => [newer, older]}
  end

  def test_profile_download
    store_profile("p1")
    get "/robin/api/profiles/p1"

    assert_equal 200, last_response.status
    assert_equal %({"meta":{"jid":"p1"}}), last_response.body
    assert_equal "application/json", last_response.headers["content-type"]
    assert_equal %(attachment; filename="robin-p1.json"), last_response.headers["content-disposition"]
    assert_equal "no-store", last_response.headers["cache-control"]
    get "/robin/api/profiles/gone"

    assert_error 404, "That profile has expired"
  end

  def test_profile_download_names_are_safe
    store_profile(%(a"b/c\d))
    get "/robin/api/profiles/#{CGI.escape(%(a"b/c\d))}"

    assert_equal %(attachment; filename="robin-abcd.json"), last_response.headers["content-disposition"]
  end

  def test_delete_profile
    store_profile("p1")
    delete_api "/robin/api/profiles/p1"

    assert_json_response 200, {"deleted" => true}
    assert_empty Robin::Profiler.list
    delete_api "/robin/api/profiles/p1"

    assert_json_response 200, {"deleted" => false}
    Robin::Web.authorize { |_env, action, _resource| action != :profiles }
    store_profile("p2")
    delete_api "/robin/api/profiles/p2"

    assert_equal 403, last_response.status
    assert_equal 1, Robin::Profiler.list.size
  end

  def test_cancel_job
    post_json "/robin/api/jobs/j9/cancel"

    assert_json_response 200, {"cancelled" => true}
    assert Robin::Cancellation.cancelled?("j9")
  end

  # -- metrics ---------------------------------------------------------------------

  def record_metrics
    collector = Robin::Metrics::Collector.new
    collector.record("HardJob", 12.0, true)
    collector.record("HardJob", 40.0, false)
    collector.record("Other", 1.0, true)
    Robin.redis { |c| collector.flush(config, c) }
  end

  def test_metrics
    record_metrics
    get "/robin/api/metrics", minutes: 7
    expected = Robin::Metrics::Query.new(config).recent(minutes: 7)

    assert_json_response 200, JSON.parse(JSON.generate(expected.merge("minutes" => 7, "deploys" => [])))
    get "/robin/api/metrics"

    assert_equal [60, 60], [json["minutes"], json["series"].size]
    get "/robin/api/metrics", minutes: 1

    assert_equal 5, json["minutes"]
    get "/robin/api/metrics", minutes: 10_000

    assert_equal 480, json["minutes"]
  end

  def test_metrics_history
    record_metrics
    get "/robin/api/metrics/history", hours: 3
    expected = Robin::Metrics::Query.new(config).history(hours: 3)

    assert_json_response 200, JSON.parse(JSON.generate(expected.merge("hours" => 3, "deploys" => [])))
    get "/robin/api/metrics/history"

    assert_equal [168, 168], [json["hours"], json["series"].size]
    get "/robin/api/metrics/history", hours: 0

    assert_equal 1, json["hours"]
    get "/robin/api/metrics/history", hours: 100_000

    assert_equal 2160, json["hours"]
  end

  def test_metrics_include_deploys_in_their_window
    now = Time.now
    {"in" => 300, "out" => 301, "in-h" => 7200, "out-h" => 7201}.each do |label, ago|
      Robin::Deploy.mark!(label, at: now - ago, config: config)
    end
    with_stub(Time, :now, ->(*) { now }) do
      get "/robin/api/metrics", minutes: 5

      assert_equal ["in"], json["deploys"].map { |d| d["label"] }
      get "/robin/api/metrics/jobs/Job", minutes: 5

      assert_equal ["in"], json["deploys"].map { |d| d["label"] }
      get "/robin/api/metrics/history", hours: 2

      assert_equal %w[in-h out in], json["deploys"].map { |d| d["label"] }
    end
  end

  def test_metrics_queues
    enqueue_raw("default", "j1", enqueued_at: NOW - 3000)
    Robin.redis { |c| Robin::Metrics.sample_queues(config, c) }
    get "/robin/api/metrics/queues"

    assert_equal({"default" => {"size" => 1, "latency" => 3}}, json["points"].last["queues"])

    assert_equal ["minute", 60, Robin::Metrics.minute_stamp(Time.now)], [json["granularity"], json["points"].size, json["points"].last["t"]]
    get "/robin/api/metrics/queues", granularity: "hour", points: 6

    assert_equal ["hour", 6, Robin::Metrics.hour_stamp(Time.now)], [json["granularity"], json["points"].size, json["points"].last["t"]]
    get "/robin/api/metrics/queues", granularity: "day", points: 1

    assert_equal ["minute", 5], [json["granularity"], json["points"].size]
    get "/robin/api/metrics/queues", points: 99_999

    assert_equal 2160, json["points"].size
  end

  def test_metrics_job
    now = Time.now
    with_stub(Time, :now, ->(*) { now }) do
      current = Robin::Metrics.minute_stamp(now)
      previous = Robin::Metrics.minute_stamp(now - 60)
      redis("HSET", "#{key_prefix_for_test}m:#{current}", "Job|s", 3, "Job|f", 1, "Job|ms", "40.5", "Other|s", 9)
      redis("HSET", "#{key_prefix_for_test}m:#{previous}", "Job|s", 1, "Job|ms", "0.5")
      redis("HSET", "#{key_prefix_for_test}h:Job:#{current}", 2, 4)
      redis("HSET", "#{key_prefix_for_test}h:Job:#{Robin::Metrics.minute_stamp(now - 600)}", 3, 7)
      get "/robin/api/metrics/jobs/Job", minutes: 5

      assert_equal 200, last_response.status
      assert_equal ["Job", 5], json.values_at("class", "minutes")
      assert_equal (0...5).map { |i| Robin::Metrics.minute_stamp(now - (i * 60)) }.reverse, json["series"].map { |p| p["t"] }
      assert_equal [{"t" => previous, "s" => 1, "f" => 0, "ms" => 0.5}, {"t" => current, "s" => 3, "f" => 1, "ms" => 40.5}],
        json["series"].last(2)
      assert_equal({"s" => 4, "f" => 1, "ms" => 41.0, "avg_ms" => 10.3}, json["totals"])
      assert_equal Robin::Metrics::Query.new(config).histogram("Job", minutes: 5), json["histogram"]
      assert_equal [4, 0], json["histogram"].values_at(2, 3).map { |b| b["count"] }
      get "/robin/api/metrics/jobs/Nothing"

      assert_equal [60, {"s" => 0, "f" => 0, "ms" => 0.0, "avg_ms" => 0}], [json["series"].size, json["totals"]]
    end
  end

  def test_metrics_job_series_steps_one_minute
    [Time.utc(2027, 1, 1, 10, 30, 59.5), Time.utc(2027, 1, 1, 10, 30, 0.5)].each do |now|
      with_stub(Time, :now, ->(*) { now }) do
        get "/robin/api/metrics/jobs/Job", minutes: 5

        assert_equal %w[202701011026 202701011027 202701011028 202701011029 202701011030], json["series"].map { |p| p["t"] }
      end
    end
  end

  def test_metrics_job_average_rounding
    now = Time.now
    with_stub(Time, :now, ->(*) { now }) do
      redis("HSET", "#{key_prefix_for_test}m:#{Robin::Metrics.minute_stamp(now)}", "J|s", 3, "J|ms", "10")
      get "/robin/api/metrics/jobs/J", minutes: 5

      assert_in_delta 3.3, json["totals"]["avg_ms"]
    end
  end

  # -- batches, limiters, cron -----------------------------------------------------

  def make_batch(description, created_at = NOW, tags: [])
    with_stub(Robin, :now_ms, ->(*) { created_at }) do
      batch = Robin::Batch.new
      batch.description = description
      batch.tags = tags
      batch.jobs { EchoJob.perform_async }
    end
  end

  def test_batches
    first = make_batch("first", NOW - 2)
    second = make_batch("second", NOW - 1)
    get "/robin/api/batches"

    assert_json_response 200, {"available" => true, "batches" => JSON.parse(JSON.generate(Robin::Batch.list(config: config)))}
    assert_equal [second, first], json["batches"].map { |b| b["bid"] }
    get "/robin/api/batches", limit: 0

    assert_equal [second], json["batches"].map { |b| b["bid"] }
  end

  def test_batches_by_tag
    tagged = make_batch("tagged", NOW - 2, tags: ["nightly"])
    make_batch("other", NOW - 1, tags: ["hourly"])
    get "/robin/api/batches", tag: "nightly"

    assert_equal [[tagged, ["nightly"]]], json["batches"].map { |b| [b["bid"], b["tags"]] }
    get "/robin/api/batches", tag: ""

    assert_equal 2, json["batches"].size
  end

  def test_batch_detail_and_delete
    bid = make_batch("one")
    get "/robin/api/batches/#{bid}"

    assert_json_response 200, {"batch" => JSON.parse(JSON.generate(Robin::Batch::Status.new(bid).to_h))}
    delete_api "/robin/api/batches/#{bid}"

    assert_json_response 200, {"deleted" => true}
    refute_predicate Robin::Batch::Status.new(bid), :exists?
    get "/robin/api/batches/#{bid}"

    assert_error 404, "No batch #{bid}"
  end

  def test_cancel_batch
    bid = make_batch("one")
    post_json "/robin/api/batches/#{bid}/cancel"

    assert_json_response 200, {"cancelled" => [bid]}
    assert_predicate Robin::Batch::Status.new(bid), :cancelled?
    post_json "/robin/api/batches/nope/cancel"

    assert_error 404, "No batch nope"
  end

  def test_limiters
    limiter = Robin::Limiter.bucket("stripe", 5, :hour)
    2.times { limiter.within_limit { nil } }
    get "/robin/api/limiters"

    assert_json_response 200, {"available" => true, "limiters" => JSON.parse(JSON.generate(Robin::Limiter.list(config: config)))}
    assert_equal ["stripe"], json["limiters"].map { |l| l["name"] }
    assert_equal 2, json["limiters"].first["used"]
    post_json "/robin/api/limiters/stripe/reset"

    assert_json_response 200, {"reset" => true}
    assert_equal 0, Robin::Limiter.list(config: config).first["used"]
    delete_api "/robin/api/limiters/stripe"

    assert_json_response 200, {"deleted" => true}
    assert_empty Robin::Limiter.list(config: config)
  end

  # Registers a cron entry the way a server would; returns its id.
  def define_cron(minute)
    registry = Robin::Periodic::Registry.new
    id = registry.register("#{minute} * * * *", "WebApiTest::EchoJob", queue: "low", args: [1], tz: "UTC", description: "hourly")
    redis("HSET", "#{key_prefix_for_test}periodic", id, JSON.generate(registry.entries.fetch(id)))
    id
  end

  def test_cron
    c1 = define_cron(5)
    redis("SET", "#{key_prefix_for_test}leader", "boss")
    get "/robin/api/cron"

    assert_json_response 200, {"available" => true, "jobs" => JSON.parse(JSON.generate(Robin::Periodic.list(config: config))),
                               "leader" => "boss"}
    assert_equal [c1], json["jobs"].map { |j| j["id"] }
  end

  def test_cron_entry_enqueue_and_pause
    c1, c2 = [define_cron(5), define_cron(7)].sort
    post_json "/robin/api/cron/#{c1}/enqueue"

    assert_equal 200, last_response.status
    jid = json["jid"]

    assert_equal [jid], Robin::Queue.new("low").map(&:jid)
    get "/robin/api/cron/#{c1}"
    job = JSON.parse(JSON.generate(Robin::Periodic.list(config: config).find { |j| j["id"] == c1 }))

    assert_json_response 200, {"job" => job, "history" => [{"at" => NOW, "jid" => jid, "manual" => true}]}
    post_json "/robin/api/cron/#{c1}/pause"

    assert_json_response 200, {"paused" => true}
    assert_equal({c1 => true, c2 => false}, Robin::Periodic.list(config: config).to_h { |j| [j["id"], j["paused"]] })
    post_json "/robin/api/cron/#{c1}/unpause"

    assert_json_response 200, {"paused" => false}
    refute Robin::Periodic.list(config: config).first["paused"]
  end

  def test_cron_history_is_limited
    c1 = define_cron(5)
    redis("RPUSH", "#{key_prefix_for_test}periodic:#{c1}:h", *Array.new(60) { |i| JSON.generate({"at" => i, "jid" => "j#{i}"}) })
    get "/robin/api/cron/#{c1}"

    assert_equal 50, json["history"].size
  end

  def test_unknown_cron_jobs
    define_cron(5)
    get "/robin/api/cron/nope"

    assert_error 404, "No cron job nope"
    post_json "/robin/api/cron/nope/enqueue"

    assert_error 404, "No cron job nope"
  end
end
