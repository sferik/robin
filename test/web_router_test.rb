# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/web"

class WebRouterTest < RobinTest
  include WebTestHelpers

  cover "Robin::Web*"

  def test_routes_are_compiled_with_anchored_patterns
    routes = Robin::Web::Router.new.routes

    assert_equal Robin::Web::Router::ROUTES.size, routes.size
    route = routes.find { |r| r.handler == :signal_process }

    assert_equal ["POST", %w[identity signal], :signal_process, :process_control],
      [route.verb, route.keys, route.handler, route.action]
    assert_equal %w[h:1 quiet], route.pattern.match("/api/processes/h:1/quiet").captures
    assert_nil route.pattern.match("/api/processes/a/b/c")
    assert_nil route.pattern.match("/x/api/processes/a/b")
    assert_nil route.pattern.match("x\n/api/processes/a/b")
    assert_equal [[], []], routes.first(2).map(&:keys)
  end

  def test_unknown_endpoints
    get "/robin/api/nope"

    assert_error 404, "No API endpoint for GET /api/nope"
    delete_api "/robin/api/stats"

    assert_error 404, "No API endpoint for DELETE /api/stats"
    get "/robin/api/queues/a/b"

    assert_error 404, "No API endpoint for GET /api/queues/a/b"
  end

  def test_head_is_routed_like_get
    head "/robin/api/stats"

    assert_equal 200, last_response.status
  end

  def test_path_parameters_are_decoded
    at_fixed_time { enqueue_raw("a/b c", "j1") }
    get "/robin/api/queues/a%2Fb%20c"

    assert_equal "a/b c", json["queue"]["name"]
    assert_equal 1, json["total"]
  end

  def test_query_string_and_path_parameters_merge
    get "/robin/api/queues/default", per_page: 3, name: "ignored"

    assert_equal ["default", 3], [json["queue"]["name"], json["per_page"]]
  end

  def test_csrf_and_origin_checks
    post "/robin/api/queues/default/pause", "{}"

    assert_error 403, "Cross-site request rejected"
    post_json "/robin/api/queues/default/pause", {}, {"HTTP_X_ROBIN_REQUEST" => "yes"}

    assert_error 403, "Cross-site request rejected"
    post_json "/robin/api/queues/default/pause", {}, {"HTTP_ORIGIN" => "https://evil.example"}

    assert_error 403, "Cross-site request rejected"
    refute_predicate Robin::Queue.new("default"), :paused?
    post_json "/robin/api/queues/default/pause", {}, {"HTTP_ORIGIN" => "http://example.org"}

    assert_json_response 200, {"paused" => true}
    post_json "/robin/api/queues/default/unpause", {}, {"HTTP_ORIGIN" => ""}

    assert_json_response 200, {"paused" => false}
  end

  def test_clusters
    other = other_cluster
    Robin::Web.clusters = {"main" => config, "other" => other}
    get "/robin/api/session", cluster: "other"

    assert_equal "other", json["cluster"]
    get "/robin/api/session", cluster: ""

    assert_equal "main", json["cluster"]
    get "/robin/api/session"

    assert_equal "main", json["cluster"]
    get "/robin/api/session", cluster: "missing"

    assert_error 404, %(Unknown cluster "missing")
  ensure
    other&.redis_pool&.shutdown
  end

  def test_read_permission
    seen = []
    Robin::Web.authorize do |_env, action, resource|
      seen << [action, resource]
      false
    end
    get "/robin/api/stats"

    assert_error 403, "You don't have access to this dashboard"
    assert_equal [[:read, "/api/stats"]], seen
  end

  def test_route_actions_are_authorized
    seen = []
    Robin::Web.authorize do |_env, action, resource|
      seen << [action, resource]
      action == :read
    end
    post_json "/robin/api/queues/default/pause"

    assert_error 403, "You don't have permission to pause and resume queues and cron jobs"
    assert_equal [[:read, "/api/queues/default/pause"], [:pause, "/api/queues/default/pause"]], seen
    seen.clear
    post_json "/robin/api/sets/retries/bulk", {"action" => "retry", "ids" => []}

    assert_error 403, "You don't have permission to retry or enqueue jobs now"
    assert_equal [[:read, "/api/sets/retries/bulk"], [:retry, "set:retries"]], seen
  end

  def test_route_permission_table
    expected = {
      pause_queue: :pause, unpause_queue: :pause, delete_queue_jobs: :delete, delete_queue_class: :delete,
      clear_queue: :delete,
      resize_process: :process_control, signal_process: :process_control, signal_all_processes: :process_control,
      set_bulk: :write,
      set_all: :write, edit_entry: :edit, cancel_job: :cancel, cancel_batch: :cancel, delete_batch: :batches,
      reset_limiter: :limiters, delete_limiter: :limiters, cron_enqueue: :enqueue, cron_pause: :pause,
      cron_unpause: :pause, delete_profile: :profiles, extension_action: :write
    }
    writes = Robin::Web::Router::ROUTES.reject { |route| route[3] == :read }.to_h { |route| [route[2], route[3]] }

    assert_equal expected, writes
    assert Robin::Web::Router::ROUTES.select { |route| route[3] == :read }.all? { |route| route[0] == "GET" }
  end

  def test_invalid_json_bodies
    post "/robin/api/sets/retries/bulk", "{nope", {"HTTP_X_ROBIN_REQUEST" => "1"}

    assert_error 400, "Request body must be valid JSON"
    post "/robin/api/sets/retries/bulk", "[1]", {"HTTP_X_ROBIN_REQUEST" => "1"}

    assert_error 400, "Request body must be a JSON object"
    post "/robin/api/sets/retries/bulk", "", {"HTTP_X_ROBIN_REQUEST" => "1"}

    assert_error 400, "Unknown action nil"
  end

  def test_requests_without_a_body
    env = Rack::MockRequest.env_for("/api/sets/retries/bulk", {:method => "POST", "HTTP_X_ROBIN_REQUEST" => "1"})
    env.delete("rack.input")
    status, _headers, body = Robin::Web::Router.new.call(env)

    assert_equal [400, {"error" => "Unknown action nil"}], [status, JSON.parse(body.first)]
  end

  def test_http_error
    error = Robin::Web::Router::HttpError.new(418, "teapot")

    assert_equal [418, "teapot", {"error" => "teapot"}], [error.status, error.message, error.body]
  end

  # -- permissions -------------------------------------------------------------

  def test_permissions_default_to_allowed
    assert Robin::Web::Permissions.allowed?({}, :delete, "x")
    assert_equal Robin::Web::Permissions::ACTIONS.keys.to_h { |a| [a.to_s, true] }, Robin::Web::Permissions.for({})
  end

  def test_read_only_blocks_everything_but_reading
    Robin::Web.read_only = true
    Robin::Web.authorize { true }

    assert Robin::Web::Permissions.allowed?({}, :read)
    refute Robin::Web::Permissions.allowed?({}, :retry)
    assert_equal({"read" => true, "retry" => false}, Robin::Web::Permissions.for({}).slice("read", "retry"))
  end

  def test_authorizer_results_are_booleans
    env = {"role" => "x"}
    calls = []
    Robin::Web.authorize do |e, action, resource|
      calls << [e, action, resource]
      (action == :read) ? "yes" : nil
    end

    assert_true Robin::Web::Permissions.allowed?(env, :read, "r")
    assert_false Robin::Web::Permissions.allowed?(env, :kill)
    assert_equal [[env, :read, "r"], [env, :kill, nil]], calls
  end

  def test_action_descriptions
    assert_equal %i[read retry edit delete kill pause cancel process_control enqueue limiters batches profiles extensions],
      Robin::Web::Permissions::ACTIONS.keys
  end
end
