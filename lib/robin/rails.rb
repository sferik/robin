# frozen_string_literal: true

require "robin"
require_relative "rails/app_loader"
require_relative "rails/error_reporter"
require_relative "rails/transactional_push"
require_relative "rails/current_attributes"
require_relative "rails/notifications"
require_relative "rails/railtie"

module Robin
  # The server finds ActiveJob jobs' wrapper class by name, possibly before
  # anything has loaded ActiveJob.
  autoload :ActiveJob, "robin/active_job"

  # Rails integration for Robin: a Railtie (see Robin::Rails::Railtie), the
  # ActiveJob adapter, generators, Rails.error reporting and
  # transaction-aware pushes. Robin itself works with any Ruby or Rack app:
  # this is loaded with it in a Rails app (one that loaded Rails first, as
  # Bundler.require does), or with `require "robin/rails"`.
  module Rails
  end
end
