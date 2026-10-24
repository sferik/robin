# frozen_string_literal: true

require "rails"
require "active_support/ordered_options"

module Robin
  module Rails
    # Wires Robin into a Rails app:
    #
    # * jobs run inside the Rails reloader and executor, so code reloading,
    #   query caches and connection checkin work as in a request
    # * ActiveJob gets the :robin adapter and +robin_options+
    # * Robin.config.environment follows Rails.env
    # * outside the robin process (web, console), Robin logs to Rails.logger
    # * errors are reported to Rails.error (see Robin::Rails::ErrorReporter)
    # * failed jobs' backtraces go through Rails.backtrace_cleaner
    # * what jobs log through Rails.logger is tagged with the job's class
    #   and jid (when the logger supports tags)
    # * Robin's events are published through ActiveSupport::Notifications
    #   (see Robin::Rails::Notifications)
    #
    # Settings, e.g. in config/application.rb:
    #
    #   config.robin.report_errors = false     # default true
    #   config.robin.transactional_push = true # default false; see TransactionalPush
    #   config.robin.current_attributes = ["Current"] # see CurrentAttributes
    #   config.robin.notifications = false     # default true
    class Railtie < ::Rails::Railtie
      config.robin = ActiveSupport::OrderedOptions.new
      config.robin.report_errors = true
      config.robin.transactional_push = false
      config.robin.current_attributes = []
      config.robin.notifications = true

      # Before the app's initializers, so they can still override it.
      initializer "robin.environment", before: :load_config_initializers do
        Robin.config.environment = ::Rails.env.to_s
      end

      # Before ActiveJob's own hook selects the configured queue adapter.
      initializer "robin.active_job", before: "active_job.set_configs" do
        ActiveSupport.on_load(:active_job) { require "robin/active_job" }
      end

      config.after_initialize { |app| Railtie.integrate(app) }

      def self.integrate(app, config: Robin.config)
        options = app.config.robin
        config.job_wrapper ||= job_wrapper(app)
        # (lambda, not ->: Steep splats a -> lambda's one Array parameter.)
        config.backtrace_cleaner ||= lambda { |lines| ::Rails.backtrace_cleaner.clean(lines) }
        config.logger = ::Rails.logger if !Robin.server? && ::Rails.logger
        if options.report_errors && config.error_handlers.none?(ErrorReporter)
          config.error_handlers << ErrorReporter.new(::Rails.error)
        end
        config.push_deferrer ||= TransactionalPush if options.transactional_push
        if options.notifications && !config.event_handlers.include?(Notifications)
          config.event_handlers << Notifications
        end
        CurrentAttributes.install(config, options.current_attributes)
      end

      # Runs each job inside the app's reloader (and so its executor). A
      # job's exception is carried out of the reloader and raised after it,
      # so the executor doesn't report it: Robin does, once, with the job's
      # context, and never for Robin::Discard.
      def self.job_wrapper(app)
        lambda do |payload, &job|
          failure = nil #: Exception?
          result = app.reloader.wrap do
            tagged(payload, &job)
          rescue Exception => e # rubocop:disable Lint/RescueException
            failure = e
          end
          failure ? raise(failure) : result
        end
      end

      def self.tagged(payload, &)
        logger = ::Rails.logger
        return yield unless logger.respond_to?(:tagged)

        logger.tagged("#{Robin.display_class(payload)} jid=#{payload.fetch("jid")}", &)
      end
    end
  end
end
