# frozen_string_literal: true

require "rails/generators/base"

module Robin
  module Generators
    # rails generate robin:install
    #
    # Creates config/robin.yml and config/initializers/robin.rb, and mounts
    # the dashboard in config/routes.rb. Running it again changes nothing.
    class InstallGenerator < ::Rails::Generators::Base
      ROUTE = <<~RUBY
        # Robin's dashboard can see and change every job: protect it, e.g. with
        # Robin::Web.authorize (config/initializers/robin.rb) or by mounting it
        # inside an authenticated route constraint.
        mount Robin::Web => "/robin"
      RUBY

      source_root File.expand_path("templates", __dir__)
      desc "Creates Robin's config file and initializer, and mounts its dashboard."

      def create_config_file
        template "robin.yml", "config/robin.yml"
      end

      def create_initializer
        template "initializer.rb", "config/initializers/robin.rb"
      end

      def mount_dashboard
        routes = File.join(destination_root, "config", "routes.rb")
        return unless File.exist?(routes)
        return if File.read(routes).include?("Robin::Web")

        route ROUTE
      end
    end
  end
end
