# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/web"

class WebBatchStatusTest < RobinTest
  include WebTestHelpers

  cover "Robin::Web::BatchStatus*"

  class EchoJob
    include Robin::Job

    def perform = nil
  end

  def app
    configured = Robin.config
    Rack::Builder.new do
      map("/status") { run Robin::Web::BatchStatus.new(config: configured) }
      map("/global") { run Robin::Web::BatchStatus.new }
    end
  end

  def make_batch
    batch = Robin::Batch.new(config: config)
    batch.description = "private"
    batch.jobs { 2.times { EchoJob.perform_async } }
  end

  def test_shows_a_batch_s_progress
    bid = make_batch
    progress = {"bid" => bid, "total" => 2, "pending" => 2, "failures" => 0,
                "complete" => false, "success" => false, "dead" => false, "cancelled" => false}
    get "/status/#{bid}.json"

    assert_equal 200, last_response.status
    assert_equal({"content-type" => "application/json; charset=utf-8", "cache-control" => "no-store"},
      last_response.headers.to_h.except("content-length"))
    assert_equal progress, json
    get "/status/#{bid}"

    assert_equal progress, json
    head "/status/#{bid}"

    assert_equal 200, last_response.status
  end

  def test_unknown_batches_and_paths_are_not_found
    bid = make_batch
    ["/status/#{"a" * 20}", "/status/#{bid}.xml", "/status/#{bid}/x", "/status/", "/status/a.b", "/status/#{"a" * 65}"].each do |path|
      get path

      assert_equal 404, last_response.status, path
      assert_equal({"error" => "No such batch"}, json)
    end
    get "/status/#{"a" * 64}"

    assert_equal 404, last_response.status
    app = Robin::Web::BatchStatus.new(config: Robin.config)
    reads = 0
    counted = ->(*args, **opts) { (reads += 1) && Robin::Batch::Status.new(*args, **opts) }

    with_stub(Robin::Batch::Status, :new, counted) do
      assert_equal 404, app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/a/b").first
    end
    assert_equal 0, reads
    assert_equal [Robin.dump_json(Robin::Batch::Status.new(bid).progress)], app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/#{bid}").last
    ["/#{bid}\n", "/x\n/#{bid}"].each do |path|
      assert_equal 404, app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => path).first, path.inspect
    end
  end

  def test_only_reads
    bid = make_batch
    post "/status/#{bid}"

    assert_equal 405, last_response.status
    assert_equal "GET, HEAD", last_response.headers["allow"]
    assert_equal "application/json; charset=utf-8", last_response.headers["content-type"]
    assert_equal({"error" => "Only GET is allowed"}, json)
    delete "/status/#{bid}"

    assert_equal 405, last_response.status
    assert_predicate Robin::Batch::Status.new(bid, config: config), :exists?
  end

  def test_defaults_to_the_global_config
    bid = make_batch
    get "/global/#{bid}"

    assert_equal 200, last_response.status
    real = Robin.config
    Robin.config = @decoy
    get "/global/#{bid}"

    assert_equal 404, last_response.status
    get "/status/#{bid}"

    assert_equal 200, last_response.status
  ensure
    Robin.config = real if real
  end
end
