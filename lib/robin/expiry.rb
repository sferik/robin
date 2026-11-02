# frozen_string_literal: true

module Robin
  # Expiring jobs: work that's worthless after a deadline.
  #
  #   class RefreshDashboard
  #     include Robin::Job
  #     robin_options expires_in: 600 # seconds after enqueue
  #   end
  #
  #   RefreshDashboard.set(expires_in: 30).perform_async(user_id)
  #
  # The client turns +expires_in+ into an absolute "expires_at" (epoch ms).
  # Jobs fetched after that moment are skipped and count as done.
  module Expiry
    def self.expired?(payload, now = Robin.now_ms)
      at = payload["expires_at"]
      !at.nil? && at < now
    end

    class ServerMiddleware
      include Middleware::ConfigAware
      include Middleware::Stateless

      def self.applies?(_job, payload, _queue) = payload.key?("expires_at")

      def call(_job, payload, _queue)
        return yield unless Expiry.expired?(payload)

        logger.info { "skipping expired job #{payload.fetch("class")} jid=#{payload.fetch("jid")}" }
        config.statsd&.increment("jobs.expired", tags: {class: Robin.display_class(payload)})
        Events.emit(config, "job.expired", job: payload)
        # It won't run, but it's finished as far as its batch (if any) is
        # concerned.
        bid = payload["bid"]
        Batch.job_succeeded(config, bid, payload.fetch("jid")) if bid
        nil
      end
    end
  end
end
