# frozen_string_literal: true

module Robin
  class Web
    # A small JSON endpoint that an app's own pages can poll for a batch's
    # progress (to draw a progress bar for an import, say). Mount it apart
    # from the dashboard: it doesn't ask the dashboard's authorization.
    #
    #   # config/routes.rb
    #   mount Robin::Web::BatchStatus.new => "/batch_status"
    #
    #   GET /batch_status/<bid>.json
    #   {"bid": "...", "total": 120, "pending": 30, "failures": 2,
    #    "complete": false, "success": false, "dead": false, "cancelled": false}
    #
    # A bid is 80 random bits, so knowing one is what lets you read it. It
    # shows counts and states only, never jobs, arguments, errors or the
    # description. Unknown and expired batches are 404s.
    class BatchStatus
      PATH = %r{\A/([\w-]{1,64})(?:\.json)?\z}
      HEADERS = {"content-type" => "application/json; charset=utf-8", "cache-control" => "no-store"}.freeze

      # +config+: the Robin config whose batches it shows (Robin.config
      # when nil).
      def initialize(config: nil) = @config = config

      def call(env)
        unless %w[GET HEAD].include?(env.fetch("REQUEST_METHOD"))
          return reply(405, {"error" => "Only GET is allowed"}, {"allow" => "GET, HEAD"})
        end

        bid = env.fetch("PATH_INFO")[PATH, 1] or return not_found
        status = Batch::Status.new(bid, config: @config || Robin.config)
        status.exists? ? reply(200, status.progress) : not_found
      end

      private

      def not_found = reply(404, {"error" => "No such batch"})

      def reply(code, body, headers = {}) = [code, HEADERS.merge(headers), [Robin.dump_json(body)]]
    end
  end
end
