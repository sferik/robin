# frozen_string_literal: true

require "robin"
require "rack"

module Robin
  # The Robin dashboard: a Rack app serving a single-page UI and the JSON
  # API behind it.
  #
  #   # config/routes.rb
  #   mount Robin::Web => "/robin"
  #
  #   # config.ru
  #   run Robin::Web
  #
  # Settings:
  #
  #   Robin::Web.title = "Billing jobs"
  #   Robin::Web.read_only = true
  #   Robin::Web.live_updates = :stream   # server-sent events instead of polling
  #   Robin::Web.clusters = {"us-east" => east_config, "eu-west" => eu_config}
  #   Robin::Web.authorize do |env, action, resource|
  #     user = env["warden"].user
  #     action == :read || user.admin?
  #   end
  class Web
    DIST = File.expand_path("web/dist", __dir__)
    ASSETS_PATH = %r{\A(?:https?://[^/]+(?:/|\z)|/(?!/))}i

    class << self
      attr_accessor :title, :brand_color, :read_only, :stream_interval, :stream_lifetime

      # :poll (default) or :stream. Streaming pushes stats over server-sent
      # events, but each open dashboard tab then holds a web server thread,
      # so only enable it where threads are plentiful (e.g. a dedicated
      # dashboard process).
      attr_accessor :live_updates

      # Where browsers load the dashboard's scripts, stylesheets, fonts and
      # images from, e.g. a CDN serving a copy of lib/robin/web/dist/assets
      # (Robin::Web::DIST + "/assets") for each Robin version:
      #
      #   Robin::Web.assets_path = "https://cdn.example.com/robin/#{Robin::VERSION}/"
      #
      # An http(s) URL or a path on this host; nil (the default) serves
      # them from the dashboard itself. A CDN must send CORS headers
      # (Access-Control-Allow-Origin), since the scripts are modules.
      attr_reader :assets_path

      def assets_path=(value)
        path = value&.to_s
        raise ArgumentError, "assets_path must be an http(s) URL or a path starting with /: #{path.inspect}" if path && !ASSETS_PATH.match?(path)

        @assets_path = path&.sub(%r{/*\z}, "/")
      end

      # Named Robin configs, one per Redis cluster. Defaults to the global
      # Robin.config.
      def clusters
        @clusters || {"default" => Robin.config}
      end

      def clusters=(hash)
        raise ArgumentError, "clusters must be a non-empty Hash of name => Robin::Config" unless hash.is_a?(Hash) && !hash.empty?

        @clusters = hash.transform_keys(&:to_s)
      end

      # Register an authorization callback. It receives the Rack env, the
      # action (see Robin::Web::Permissions::ACTIONS) and a resource string
      # (e.g. "queue:default"); return truthy to allow.
      def authorize(&block)
        @authorizer = block
      end

      attr_reader :authorizer

      # Adds a page of your own (a Robin::Web::Extension subclass) to the
      # dashboard. Registering another with the same slug replaces it.
      def register(extension)
        raise ArgumentError, "#{extension.inspect} isn't a Robin::Web::Extension" unless extension.instance_of?(Class) && extension < Extension

        extensions[extension.slug] = extension
      end

      # Registered extensions by slug.
      def extensions = (@extensions ||= {})

      # Adds a row to every job's detail page. The block gets the job's
      # payload (a Hash) and returns the row's text, a Hash with :text and
      # :href to make it a link (http(s) URLs and paths only), or nil to
      # leave the row out for that job:
      #
      #   Robin::Web.job_info("Customer") do |job|
      #     id = job["args"].first
      #     {text: "##{id}", href: "/admin/customers/#{id}"} if job["class"] == "InvoiceJob"
      #   end
      #
      # Adding another row with the same label replaces it.
      def job_info(label, &block)
        raise ArgumentError, "job_info needs a block" unless block

        job_info_rows[label.to_s] = block
      end

      # The job_info blocks by label.
      def job_info_rows = (@job_info_rows ||= {})

      def call(env)
        app.call(env)
      end

      def app
        @app ||= new
      end

      # Restore default settings (used by tests).
      def reset!
        @clusters = nil
        @authorizer = nil
        @extensions = nil
        @job_info_rows = nil
        @app = nil
        self.title = "Robin"
        self.assets_path = nil
        self.brand_color = nil
        self.read_only = false
        self.stream_interval = 2
        self.stream_lifetime = 60
        self.live_updates = :poll
      end
    end

    reset!

    def initialize
      @router = Router.new
      @static = Static.new(DIST)
    end

    def call(env)
      path = env.fetch("PATH_INFO")
      # /metrics is both the Prometheus endpoint and a dashboard page; a
      # browser asking for HTML gets the page.
      if path == "/metrics" && !env["HTTP_ACCEPT"].to_s.include?("text/html")
        Prometheus.new(env).call
      elsif path == "/health"
        health
      elsif path.start_with?("/api/")
        @router.call(env)
      elsif path.start_with?("/extensions/")
        extension_asset(env, path)
      else
        @static.call(env)
      end
    end

    # GET /health: pings every cluster's Redis, for load balancer and uptime
    # checks. 200 when all of them answer, else 503. Needs no permission:
    # it reveals nothing but reachability and round-trip times.
    def health
      clusters = Web.clusters.to_h do |name, config|
        started = monotonic_ms
        begin
          config.redis { |c| c.call("PING") }
          [name, {"ok" => true, "latency_ms" => (monotonic_ms - started).round(2)}]
        rescue => e
          [name, {"ok" => false, "error" => "#{e.class}: #{e}"}]
        end
      end
      healthy = clusters.each_value.all? { |c| c.fetch("ok") }
      body = Robin.dump_json({"healthy" => healthy, "redis" => clusters})
      [healthy ? 200 : 503, {"content-type" => "application/json", "cache-control" => "no-store"}, [body]]
    end

    # GET /extensions/<slug>/<file>: a file from an extension's assets.
    def extension_asset(env, path)
      return API.json(403, {"error" => "You don't have access to this dashboard"}) unless Permissions.allowed?(env, :read, path)

      _, _, slug, file = path.split("/", 4)
      @static.call_file(env, Web.extensions[slug]&.asset_file(file.to_s))
    end

    private

    def monotonic_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
  end
end

require_relative "web/permissions"
require_relative "web/extension"
require_relative "web/api"
require_relative "web/router"
require_relative "web/static"
require_relative "web/prometheus"
require_relative "web/batch_status"
