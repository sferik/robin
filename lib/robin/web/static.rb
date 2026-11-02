# frozen_string_literal: true

module Robin
  class Web
    # Serves the compiled single-page app from lib/robin/web/dist.
    #
    # Hashed files under /assets are cached forever; every other GET gets
    # index.html (with the mount path filled in) so client-side routes
    # work on reload.
    class Static
      TYPES = {
        ".js" => "text/javascript; charset=utf-8", ".mjs" => "text/javascript; charset=utf-8", ".css" => "text/css; charset=utf-8",
        ".svg" => "image/svg+xml", ".woff2" => "font/woff2", ".png" => "image/png",
        ".ico" => "image/x-icon", ".json" => "application/json", ".map" => "application/json"
      }.freeze

      CSP = [
        "default-src 'self'", "script-src 'self'", "style-src 'self'", "img-src 'self' data:",
        "font-src 'self'", "connect-src 'self'", "frame-ancestors 'self'", "base-uri 'self'", "form-action 'self'"
      ].join("; ").freeze

      SECURITY_HEADERS = {
        "content-security-policy" => CSP, "x-content-type-options" => "nosniff",
        "referrer-policy" => "same-origin", "x-frame-options" => "SAMEORIGIN"
      }.freeze

      ASSET_CACHE = "public, max-age=31536000, immutable"

      UNBUILT = "Robin's dashboard assets aren't built. Run `bun install && bun run build` in the web/ directory."

      def initialize(root)
        @root = root
      end

      def call(env)
        respond(env) do
          path = env.fetch("PATH_INFO")
          next index(env) unless path.start_with?("/assets/")

          file = File.join(@root, path)
          (path.include?("..") || !File.file?(file)) ? not_found : file(env, file, ASSET_CACHE)
        end
      end

      # Serves +file+ (a full path, or nil for a 404), e.g. from an
      # extension's assets. They aren't fingerprinted, so browsers check
      # back each time.
      def call_file(env, file)
        respond(env) { file ? file(env, file, "no-cache") : not_found }
      end

      private

      def not_found = [404, {"content-type" => "text/plain"}, ["Not found"]]

      def respond(env)
        method = env.fetch("REQUEST_METHOD")
        return [405, {"content-type" => "text/plain"}, ["Method not allowed"]] unless method == "GET" || method == "HEAD"

        status, headers, body = yield
        [status, headers, (method == "HEAD") ? [] : body]
      end

      def file(env, file, cache)
        headers = {
          "content-type" => TYPES.fetch(File.extname(file), "application/octet-stream"),
          "cache-control" => cache, "vary" => "accept-encoding", "x-content-type-options" => "nosniff"
        }
        if env["HTTP_ACCEPT_ENCODING"].to_s.include?("gzip") && File.file?("#{file}.gz")
          headers["content-encoding"] = "gzip"
          file = "#{file}.gz"
        end
        data = File.binread(file)
        headers["content-length"] = data.bytesize.to_s
        [200, headers, [data]]
      end

      def index(env)
        template = index_template
        return [503, {"content-type" => "text/plain; charset=utf-8"}, [UNBUILT]] unless template

        base = "#{env.fetch("SCRIPT_NAME")}/".squeeze("/")
        html = template
          .gsub("%ROBIN_BASE%") { Rack::Utils.escape_html(base) }
          .gsub("%ROBIN_TITLE%") { Rack::Utils.escape_html(Web.title) }
        html = html.gsub('"assets/') { %("#{Rack::Utils.escape_html(Web.assets_path)}) } if Web.assets_path
        [200, {"content-type" => "text/html; charset=utf-8", "cache-control" => "no-store"}.merge(security_headers), [html]]
      end

      # With assets on another host (Web.assets_path), the policy lets
      # scripts, styles, images and fonts come from it.
      def security_headers
        origin = Web.assets_path&.[](%r{\Ahttps?://[^/]+}i) or return SECURITY_HEADERS

        SECURITY_HEADERS.merge({"content-security-policy" => CSP.gsub(/(?:script|style|img|font)-src 'self'/) { |src| "#{src} #{origin}" }})
      end

      # index.html, re-read whenever it changes on disk (e.g. `bun run dev`).
      def index_template
        path = File.join(@root, "index.html")
        return unless File.file?(path)

        mtime = File.mtime(path)
        @index = File.read(path) unless mtime == @index_mtime
        @index_mtime = mtime
        @index
      end
    end
  end
end
