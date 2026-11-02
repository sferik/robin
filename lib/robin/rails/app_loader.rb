# frozen_string_literal: true

require "robin"

module Robin
  module Rails
    # Boots a Rails application directory for `bundle exec robin`: the
    # CLI's first app loader (see Robin::CLI.app_loaders). Other
    # directories are left to the next loader.
    module AppLoader
      # The Railtie is loaded first so it joins the app's initialization
      # even when Bundler.require hasn't loaded robin (or loaded it before
      # Rails).
      def self.call(dir)
        return false unless File.exist?(File.join(dir, "config", "application.rb"))

        require "robin/rails"
        require File.expand_path(File.join(dir, "config", "environment.rb"))
        true
      end
    end
  end
end
