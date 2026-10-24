# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/web"

class WebStaticTest < RobinTest
  include WebTestHelpers

  cover "Robin::Web*"

  def setup
    super
    @root = Dir.mktmpdir("robin-dist")
    FileUtils.mkdir_p(File.join(@root, "assets"))
    File.write(File.join(@root, "index.html"), %(<base href="%ROBIN_BASE%"><title>%ROBIN_TITLE%</title>%ROBIN_BASE%%ROBIN_TITLE%))
    File.write(File.join(@root, "assets", "app-1.js"), "console.log(1)")
    File.binwrite(File.join(@root, "assets", "app-1.js.gz"), "GZ")
    File.write(File.join(@root, "assets", "plain.css"), "a{}")
    File.write(File.join(@root, "assets", "blob.bin"), "xyz")
    @static = Robin::Web::Static.new(@root)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def serve(path, method: "GET", script_name: "", **headers)
    env = {"REQUEST_METHOD" => method, "PATH_INFO" => path, "SCRIPT_NAME" => script_name}.merge(headers)
    @static.call(env)
  end

  def html_headers
    {"content-type" => "text/html; charset=utf-8", "cache-control" => "no-store"}.merge(Robin::Web::Static::SECURITY_HEADERS)
  end

  def test_index_fills_in_base_and_title
    Robin::Web.title = %(Jobs & "more")

    assert_equal [200, html_headers, [%(<base href="/robin/"><title>Jobs &amp; &quot;more&quot;</title>/robin/Jobs &amp; &quot;more&quot;)]],
      serve("/queues/x", script_name: "/robin")
  end

  def test_index_base_path_variants
    assert_includes serve("/")[2].first, %(<base href="/">)
    assert_includes serve("/", script_name: "/robin/")[2].first, %(<base href="/robin/">)
    assert_includes serve("/", script_name: "/a&b")[2].first, %(<base href="/a&amp;b/">)
    assert_includes serve("/", script_name: "/oops//jobs")[2].first, %(<base href="/oops/jobs/">)
  end

  def test_security_headers
    assert_equal({
      "content-security-policy" => "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; " \
        "font-src 'self'; connect-src 'self'; frame-ancestors 'self'; base-uri 'self'; form-action 'self'",
      "x-content-type-options" => "nosniff", "referrer-policy" => "same-origin", "x-frame-options" => "SAMEORIGIN"
    }, Robin::Web::Static::SECURITY_HEADERS)
  end

  def test_assets_path_points_asset_urls_elsewhere
    File.write(File.join(@root, "index.html"), %(<link href="assets/a.css"><script src="assets/a.js"></script><meta content="assets/l.svg">"other/assets/x"))
    Robin::Web.assets_path = "https://CDN.example.com:8443/robin/1.0?a&b"
    status, headers, body = serve("/")

    assert_equal 200, status
    assert_equal %(<link href="https://CDN.example.com:8443/robin/1.0?a&amp;b/a.css"><script src="https://CDN.example.com:8443/robin/1.0?a&amp;b/a.js"></script>) +
      %(<meta content="https://CDN.example.com:8443/robin/1.0?a&amp;b/l.svg">"other/assets/x"), body.first
    origin = "https://CDN.example.com:8443"

    assert_equal "default-src 'self'; script-src 'self' #{origin}; style-src 'self' #{origin}; img-src 'self' #{origin} data:; " \
      "font-src 'self' #{origin}; connect-src 'self'; frame-ancestors 'self'; base-uri 'self'; form-action 'self'",
      headers["content-security-policy"]
    assert_equal html_headers.except("content-security-policy"), headers.except("content-security-policy")
    Robin::Web.assets_path = "HTTP://plain.example"

    assert_includes serve("/")[1]["content-security-policy"], "script-src 'self' HTTP://plain.example;"
  end

  def test_assets_path_on_this_host_keeps_the_policy
    File.write(File.join(@root, "index.html"), %(<script src="assets/a.js"></script>))
    Robin::Web.assets_path = "/static/robin/"

    assert_equal [200, html_headers, [%(<script src="/static/robin/a.js"></script>)]], serve("/")
  end

  def test_assets_path_values
    Robin::Web.assets_path = "http://x.example"

    assert_equal "http://x.example/", Robin::Web.assets_path
    Robin::Web.assets_path = :"/a//"

    assert_equal "/a/", Robin::Web.assets_path
    ["cdn.example.com/x", "//cdn.example.com/x", "javascript:alert(1)//", "ftp://x/", ""].each do |bad|
      error = assert_raises(ArgumentError) { Robin::Web.assets_path = bad }
      assert_equal "assets_path must be an http(s) URL or a path starting with /: #{bad.inspect}", error.message
    end
    assert_equal "/a/", Robin::Web.assets_path
    Robin::Web.assets_path = nil

    assert_nil Robin::Web.assets_path
    Robin::Web.assets_path = "/b"
    Robin::Web.reset!

    assert_nil Robin::Web.assets_path
  end

  def test_index_is_reloaded_only_when_it_changes
    index = File.join(@root, "index.html")
    first = serve("/")[2].first
    mtime = File.mtime(index)
    File.write(index, "changed")
    File.utime(mtime, mtime, index)

    assert_equal first, serve("/")[2].first, "same mtime: cached copy"
    File.utime(mtime + 10, mtime + 10, index)

    assert_equal ["changed"], serve("/")[2]
  end

  def test_unbuilt_dashboard
    File.delete(File.join(@root, "index.html"))

    assert_equal [503, {"content-type" => "text/plain; charset=utf-8"}, [Robin::Web::Static::UNBUILT]], serve("/")
  end

  def test_head_requests_have_no_body
    status, headers, body = serve("/", method: "HEAD")

    assert_equal [200, html_headers, []], [status, headers, body]
    status, headers, body = serve("/assets/plain.css", method: "HEAD")

    assert_equal 200, status
    assert_equal "3", headers["content-length"]
    assert_empty body
  end

  def test_other_methods_are_rejected
    assert_equal [405, {"content-type" => "text/plain"}, ["Method not allowed"]], serve("/", method: "POST")
  end

  def test_assets
    asset_headers = {"cache-control" => "public, max-age=31536000, immutable", "vary" => "accept-encoding",
                     "x-content-type-options" => "nosniff"}

    assert_equal [200, asset_headers.merge("content-type" => "text/css; charset=utf-8", "content-length" => "3"), ["a{}"]],
      serve("/assets/plain.css")
    assert_equal [200, asset_headers.merge("content-type" => "application/octet-stream", "content-length" => "3"), ["xyz"]],
      serve("/assets/blob.bin")
  end

  def test_gzip_negotiation
    js = "text/javascript; charset=utf-8"

    assert_equal [{"content-type" => js, "content-encoding" => "gzip", "content-length" => "2"}, ["GZ"]],
      gz_parts(serve("/assets/app-1.js", "HTTP_ACCEPT_ENCODING" => "br, gzip"))
    assert_equal [{"content-type" => js, "content-length" => "14"}, ["console.log(1)"]],
      gz_parts(serve("/assets/app-1.js", "HTTP_ACCEPT_ENCODING" => "br"))
    assert_equal [{"content-type" => js, "content-length" => "14"}, ["console.log(1)"]], gz_parts(serve("/assets/app-1.js"))
    assert_equal [{"content-type" => js, "content-length" => "14"}, ["console.log(1)"]],
      gz_parts(serve("/assets/app-1.js", "HTTP_X_HINT" => "gzip"))
    assert_equal [{"content-type" => "text/css; charset=utf-8", "content-length" => "3"}, ["a{}"]],
      gz_parts(serve("/assets/plain.css", "HTTP_ACCEPT_ENCODING" => "gzip"))
  end

  def test_missing_and_traversal_paths_are_not_found
    not_found = [404, {"content-type" => "text/plain"}, ["Not found"]]

    assert_equal not_found, serve("/assets/nope.js")
    assert_equal not_found, serve("/assets/../index.html")
    assert_equal not_found, serve("/assets/")
    assert_equal 200, serve("/assets")[0], "not under /assets/: the app shell"
  end

  def test_real_dist_is_served
    get "/robin/"

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<base href="/robin/">'
    refute_includes last_response.body, "%ROBIN_"
  end

  # -- Robin::Web ------------------------------------------------------------------

  def test_dispatch
    get "/robin/metrics", {}, {"HTTP_ACCEPT" => "text/plain"}

    assert_equal "text/plain; version=0.0.4; charset=utf-8", last_response.headers["content-type"]
    get "/robin/metrics"

    assert_equal "text/plain; version=0.0.4; charset=utf-8", last_response.headers["content-type"]
    get "/robin/metrics", {}, {"HTTP_ACCEPT" => "text/plain", "HTTP_X_HINT" => "text/html"}

    assert_equal "text/plain; version=0.0.4; charset=utf-8", last_response.headers["content-type"]
    get "/robin/metrics", {}, {"HTTP_ACCEPT" => "text/html"}

    assert_equal "text/html; charset=utf-8", last_response.headers["content-type"]
    get "/robin/metricsx"

    assert_equal "text/html; charset=utf-8", last_response.headers["content-type"]
    get "/robin/api/stats"

    assert_equal "application/json; charset=utf-8", last_response.headers["content-type"]
    get "/robin/apix"

    assert_equal "text/html; charset=utf-8", last_response.headers["content-type"]
    get "/robin"

    assert_equal "text/html; charset=utf-8", last_response.headers["content-type"]
  end

  def test_dist_location
    assert_equal File.expand_path("../lib/robin/web/dist", __dir__), Robin::Web::DIST
  end

  def test_clusters
    assert_equal({"default" => Robin.config}, Robin::Web.clusters)
    other = Robin::Config.new
    Robin::Web.clusters = {a: config, b: other}

    assert_equal({"a" => config, "b" => other}, Robin::Web.clusters)
    indifferent = Class.new(Hash)
    Robin::Web.clusters = indifferent[x: config]

    assert_equal({"x" => config}, Robin::Web.clusters)
    assert_raises(ArgumentError) { Robin::Web.clusters = {} }
    error = assert_raises(ArgumentError) { Robin::Web.clusters = [[:a, config]] }
    assert_equal "clusters must be a non-empty Hash of name => Robin::Config", error.message
  end

  def test_authorize_and_app
    block = proc { true }
    Robin::Web.authorize(&block)

    assert_same block, Robin::Web.authorizer
    assert_same Robin::Web.app, Robin::Web.app
    assert_kind_of Robin::Web, Robin::Web.app
  end

  def test_reset
    app = Robin::Web.app
    Robin::Web.clusters = {"x" => config}
    Robin::Web.authorize { true }
    Robin::Web.title = "T"
    Robin::Web.brand_color = "#fff"
    Robin::Web.read_only = true
    Robin::Web.stream_interval = 9
    Robin::Web.stream_lifetime = 9
    Robin::Web.live_updates = :stream
    Robin::Web.reset!

    assert_equal({"default" => Robin.config}, Robin::Web.clusters)
    assert_nil Robin::Web.authorizer
    refute_same app, Robin::Web.app
    assert_equal ["Robin", nil, false, 2, 60, :poll],
      [Robin::Web.title, Robin::Web.brand_color, Robin::Web.read_only, Robin::Web.stream_interval,
        Robin::Web.stream_lifetime, Robin::Web.live_updates]
  end

  private

  def gz_parts(response)
    headers = response[1].slice("content-type", "content-encoding", "content-length")
    [headers, response[2]]
  end
end
