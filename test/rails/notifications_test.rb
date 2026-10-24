# frozen_string_literal: true

require_relative "helper"

class NotificationsTest < Minitest::Test
  cover "Robin::Rails::Notifications*"

  def test_events_are_published_as_robin_notifications
    config = Robin::Config.new
    config.event_handlers << Robin::Rails::Notifications
    received = []
    subscriber = ActiveSupport::Notifications.subscribe(/\.robin\z/) do |event|
      received << [event.name, event.payload]
    end
    job = {"class" => "Job", "jid" => "j1"}
    Robin::Events.emit(config, "job.expired", job: job)
    Robin::Events.emit(config, "heartbeat.lapsed")

    assert_equal [["job.expired.robin", {job: job}], ["heartbeat.lapsed.robin", {}]], received
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
