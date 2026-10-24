# frozen_string_literal: true

require "rack/test"
require "robin/web"
require "tmpdir"

# Helpers shared by the web dashboard tests.
module WebTestHelpers
  include Rack::Test::Methods

  NOW = 1_800_000_000_000

  # Swaps Robin.config for an empty decoy while the dashboard handles a
  # request (and streams its body), so code that forgets to use the
  # cluster's config and falls back to the global one reads nothing.
  class DecoyApp
    def initialize(decoy) = @decoy = decoy

    def call(env)
      status, headers, body = swapped { Robin::Web.call(env) }
      [status, headers, Enumerator.new { |out| swapped { body.each { |chunk| out << chunk } } }]
    end

    def swapped
      real = Robin.config
      Robin.config = @decoy
      yield
    ensure
      Robin.config = real
    end
  end

  def app
    decoy = @decoy
    Rack::Builder.new do
      map("/robin") { run DecoyApp.new(decoy) }
    end
  end

  def setup
    super
    Robin::Web.reset!
    Robin::Web.clusters = {"default" => config}
    @decoy = Robin::Config.new
    @decoy.redis = {url: REDIS_URL}
    @decoy.key_prefix = "#{key_prefix_for_test}decoy:"
    @decoy.logger = Logger.new(nil)
  end

  def teardown
    Robin::Web.reset!
    @decoy&.redis_pool&.shutdown
    super
  end

  def json = JSON.parse(last_response.body)

  def post_json(path, body = {}, headers = {})
    post path, JSON.generate(body), {"CONTENT_TYPE" => "application/json", "HTTP_X_ROBIN_REQUEST" => "1"}.merge(headers)
  end

  def delete_api(path, headers = {})
    delete path, {}, {"HTTP_X_ROBIN_REQUEST" => "1"}.merge(headers)
  end

  def assert_json_response(status, body)
    assert_equal status, last_response.status, last_response.body
    assert_equal "application/json; charset=utf-8", last_response.headers["content-type"]
    assert_equal "no-store", last_response.headers["cache-control"]
    assert_equal body, json
  end

  def assert_error(status, message)
    assert_json_response(status, {"error" => message})
  end

  # Temporarily replaces a singleton method (e.g. Robin.now_ms).
  def with_stub(object, name, impl)
    meta = object.singleton_class
    original = meta.instance_method(name) if meta.method_defined?(name, false) || meta.private_method_defined?(name, false)
    meta.send(:define_method, name) { |*args, **kwargs, &block| impl.call(*args, **kwargs, &block) }
    yield
  ensure
    original ? meta.send(:define_method, name, original) : meta.send(:remove_method, name)
  end

  # Freezes Robin's clock so latencies and timestamps are exact.
  def at_fixed_time(&) = with_stub(Robin, :now_ms, ->(*) { NOW }, &)

  # Pushes a raw job straight onto a queue.
  def enqueue_raw(queue, jid, enqueued_at: NOW, **extra)
    payload = {"class" => "HardJob", "args" => [jid], "queue" => queue, "jid" => jid,
               "created_at" => enqueued_at, "enqueued_at" => enqueued_at}.merge(extra.transform_keys(&:to_s))
    redis("SADD", "#{key_prefix_for_test}queues", queue)
    redis("LPUSH", "#{key_prefix_for_test}queue:#{queue}", JSON.generate(payload))
    payload
  end

  # Adds a job to a sorted set (schedule, retry or dead); returns its id.
  # Adds a job to a sorted set, due (or dead) at +at+ (epoch ms); returns
  # its id.
  def add_entry(set, jid, extra = {}, at: NOW + 60_000)
    payload = {"class" => "HardJob", "args" => [1], "queue" => "default", "jid" => jid, "retry" => true,
               "created_at" => NOW - 1000, "error_class" => "RuntimeError", "error_message" => "Boom #{jid}",
               "retry_count" => 1, "error_backtrace" => ["app/jobs/hard_job.rb:3"]}.merge(extra)
    score = Robin.epoch_seconds(at)
    redis("ZADD", "#{key_prefix_for_test}#{set}", score, JSON.generate(payload))
    "#{score}-#{jid}"
  end

  # Writes a process's record as a running server does.
  def add_process(identity, busy: 0, quiet: false)
    info = {"hostname" => "h", "concurrency" => 5, "started_at" => Robin.epoch_seconds(NOW - 60_000),
            "capsules" => {"default" => {"concurrency" => 5, "mode" => "weighted", "weights" => {"default" => 2, "low" => 1}}}}
    redis("SADD", "#{key_prefix_for_test}processes", identity)
    redis("HSET", "#{key_prefix_for_test}#{identity}", "info", JSON.generate(info), "concurrency", 5,
      "busy", busy, "beat", Robin.epoch_seconds(NOW), "quiet", quiet.to_s)
  end

  # A process's pending remote signals, newest first.
  def signals_for(identity) = redis("LRANGE", "#{key_prefix_for_test}#{identity}-signals", 0, -1)

  def add_work(identity, thread, queue, payload, run_at)
    work = {"queue" => queue, "payload" => JSON.generate(payload), "run_at" => Robin.epoch_seconds(run_at)}
    redis("HSET", "#{key_prefix_for_test}#{identity}:work", thread, JSON.generate(work))
  end

  def other_cluster
    other = Robin::Config.new
    other.redis = {url: REDIS_URL}
    other.key_prefix = "#{key_prefix_for_test}other:"
    other.logger = Logger.new(nil)
    other
  end
end
