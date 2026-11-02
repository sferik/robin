# frozen_string_literal: true

require "active_support/notifications"

module Robin
  module Rails
    # Publishes Robin's events (see Robin::Events) through
    # ActiveSupport::Notifications as "<event>.robin":
    #
    #   ActiveSupport::Notifications.subscribe("job.expired.robin") do |event|
    #     Rails.logger.info("expired: #{event.payload[:job]["jid"]}")
    #   end
    #
    # The Railtie adds it to Robin.config.event_handlers unless
    # config.robin.notifications is false.
    module Notifications
      def self.call(name, payload)
        ActiveSupport::Notifications.instrument("#{name}.robin", payload)
      end
    end
  end
end
