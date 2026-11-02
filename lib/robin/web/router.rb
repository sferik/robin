# frozen_string_literal: true

require "uri"

module Robin
  class Web
    # Dispatches /api requests to Robin::Web::API, enforcing CSRF and
    # authorization rules.
    class Router
      Route = Struct.new(:verb, :pattern, :keys, :handler, :action)

      class HttpError < StandardError
        attr_reader :status

        def initialize(status, message)
          @status = status
          super(message)
        end

        def body = {"error" => message}
      end

      # verb, path, API method, permission needed (:read for viewing;
      # :write handlers check their own fine-grained permission).
      ROUTES = [
        ["GET", "/api/session", :session, :read],
        ["GET", "/api/dashboard", :dashboard, :read],
        ["GET", "/api/stats", :stats, :read],
        ["GET", "/api/stream", :stream, :read],
        ["GET", "/api/info", :info, :read],
        ["GET", "/api/queues", :queues, :read],
        ["GET", "/api/queues/:name", :queue, :read],
        ["POST", "/api/queues/:name/pause", :pause_queue, :pause],
        ["POST", "/api/queues/:name/unpause", :unpause_queue, :pause],
        ["POST", "/api/queues/:name/delete_jobs", :delete_queue_jobs, :delete],
        ["POST", "/api/queues/:name/delete_class", :delete_queue_class, :delete],
        ["DELETE", "/api/queues/:name", :clear_queue, :delete],
        ["GET", "/api/busy", :busy, :read],
        ["POST", "/api/processes/:identity/resize", :resize_process, :process_control],
        ["POST", "/api/processes/:identity/:signal", :signal_process, :process_control],
        ["POST", "/api/processes/:signal", :signal_all_processes, :process_control],
        ["GET", "/api/sets/:set", :set, :read],
        ["GET", "/api/sets/:set/:id", :set_entry, :read],
        ["POST", "/api/sets/:set/bulk", :set_bulk, :write],
        ["POST", "/api/sets/:set/all", :set_all, :write],
        ["POST", "/api/sets/:set/:id/edit", :edit_entry, :edit],
        ["GET", "/api/jobs/:jid", :find_job, :read],
        ["POST", "/api/jobs/:jid/cancel", :cancel_job, :cancel],
        ["GET", "/api/metrics", :metrics, :read],
        ["GET", "/api/metrics/history", :metrics_history, :read],
        ["GET", "/api/metrics/queues", :metrics_queues, :read],
        ["GET", "/api/metrics/jobs/:klass", :metrics_job, :read],
        ["GET", "/api/batches", :batches, :read],
        ["GET", "/api/batches/:bid", :batch, :read],
        ["POST", "/api/batches/:bid/cancel", :cancel_batch, :cancel],
        ["DELETE", "/api/batches/:bid", :delete_batch, :batches],
        ["GET", "/api/limiters", :limiters, :read],
        ["POST", "/api/limiters/:name/reset", :reset_limiter, :limiters],
        ["DELETE", "/api/limiters/:name", :delete_limiter, :limiters],
        ["GET", "/api/cron", :cron, :read],
        ["GET", "/api/cron/:id", :cron_entry, :read],
        ["POST", "/api/cron/:id/enqueue", :cron_enqueue, :enqueue],
        ["POST", "/api/cron/:id/pause", :cron_pause, :pause],
        ["POST", "/api/cron/:id/unpause", :cron_unpause, :pause],
        ["GET", "/api/profiles", :profiles, :read],
        ["GET", "/api/profiles/:jid", :profile_data, :read],
        ["DELETE", "/api/profiles/:jid", :delete_profile, :profiles],
        ["GET", "/api/extensions/:slug", :extension_page, :read],
        ["GET", "/api/extensions/:slug/data/:name", :extension_data, :read],
        ["POST", "/api/extensions/:slug/actions/:action", :extension_action, :write]
      ].freeze #: Array[[String, String, Symbol, Symbol]]

      # Actions checked by the handler itself, or not at all.
      SELF_CHECKED = %i[read write].freeze

      attr_reader :routes

      def initialize
        @routes = ROUTES.map { |verb, path, handler, action| compile(verb, path, handler, action) }
      end

      def call(env)
        request = Rack::Request.new(env)
        verb = request.head? ? "GET" : request.request_method
        path = request.path_info
        matched = match(verb, path)
        return API.json(404, {"error" => "No API endpoint for #{verb} #{path}"}) unless matched

        route, captures = matched
        return API.json(403, {"error" => "Cross-site request rejected"}) unless verb == "GET" || same_origin?(request)

        params = request.GET.merge(captures)
        cluster = cluster_name(params["cluster"])
        return API.json(404, {"error" => "Unknown cluster #{cluster.inspect}"}) unless Web.clusters.key?(cluster)
        return API.json(403, {"error" => "You don't have access to this dashboard"}) unless Permissions.allowed?(env, :read, path)

        api = API.new(env, request, cluster, params)
        api.authorize!(route.action, path) unless SELF_CHECKED.include?(route.action)
        api.public_send(route.handler)
      rescue HttpError => e
        API.json(e.status, e.body)
      rescue JSON::ParserError
        API.json(400, {"error" => "Request body must be valid JSON"})
      end

      private

      def compile(verb, path, handler, action)
        keys = path.scan(/:(\w+)/).flatten
        Route.new(verb, /\A#{path.gsub(/:\w+/, "([^/]+)")}\z/, keys, handler, action)
      end

      # Returns the route and its decoded path parameters.
      def match(verb, path)
        @routes.each do |route|
          next unless route.verb == verb

          m = route.pattern.match(path) or next
          # (Every group in a route's pattern matches something, so no capture is nil.)
          return [route, route.keys.zip(m.captures.map { |c| URI.decode_www_form_component(c) }).to_h] # steep:ignore ArgumentTypeMismatch
        end
        nil
      end

      # The requested cluster, or the first one when none is given.
      def cluster_name(name)
        name.to_s.empty? ? Web.clusters.keys.first : name
      end

      # Fetch metadata values a browser sends for requests from the page
      # itself (or typed in by the user).
      SAME_SITE_FETCHES = ["same-origin", "none", ""].freeze

      # Non-GET requests must carry our custom header (which browsers
      # won't send cross-site without CORS approval), a Sec-Fetch-Site
      # saying the browser didn't send it on another site's behalf, and an
      # Origin matching the host. The last two are checked when present
      # (older browsers and non-browser clients leave them out).
      def same_origin?(request)
        return false unless request.get_header("HTTP_X_ROBIN_REQUEST") == "1"
        return false unless SAME_SITE_FETCHES.include?(request.get_header("HTTP_SEC_FETCH_SITE").to_s)

        origin = request.get_header("HTTP_ORIGIN").to_s
        origin.empty? || origin == request.base_url
      end
    end
  end
end
