# frozen_string_literal: true

require_relative "helper"
require_relative "../support/extension_api"
require "robin/active_job"
require "robin/rails/current_attributes"
require "robin/rails/transactional_push"

# The Rails and Active Job part of Robin's extension API (EXTENDING.md);
# the rest is in test/extension_api_test.rb.
class RailsExtensionAPITest < RobinTest
  include ExtensionAPIAssertions

  def self.hook(signature) = ExtensionAPIAssertions.hook(signature)

  API = {
    "ActiveJob::QueueAdapters::RobinAdapter#payload" => hook([[:req], [:req]]),
    "Robin::ActiveJob::Options" => :module,
    "Robin::ActiveJob::Options::ClassMethods#robin_options" => [[:opt]],
    "Robin::ActiveJob::Wrapper" => :class,
    "Robin::Rails::CurrentAttributes" => :module,
    "Robin::Rails::CurrentAttributes.install" => [[:req], [:req]],
    "Robin::Rails::TransactionalPush" => :module
  }.freeze

  def test_the_extension_api_is_unchanged
    assert_extension_api API
  end

  class TaggedAdapter < ActiveJob::QueueAdapters::RobinAdapter
    private

    def payload(job, timestamp) = super.merge("tagged" => true)
  end

  class TaggedJob < ActiveJob::Base
    def perform = nil
  end

  # A subclass of the adapter builds what it pushes with #payload.
  def test_the_adapter_builds_its_jobs_with_payload
    TaggedAdapter.new.enqueue(TaggedJob.new)

    assert_true Robin.load_json(redis("LINDEX", config.key("queue", "default"), 0)).fetch("tagged")
  end
end
