# frozen_string_literal: true

module Robin
  # Runs a Robin server inside another process. With Puma, use the plugin
  # (lib/puma/plugin/robin.rb), which starts a server in every worker once
  # the application has loaded and stops it when the worker stops:
  #
  #   # config/puma.rb
  #   plugin :robin
  #
  # Elsewhere:
  #
  #   robin = Robin.configure_embed do |config|
  #     config.queues = %w[critical default]
  #     config.concurrency = 2
  #   end
  #   robin.run
  #   at_exit { robin.stop }
  class Embedded
    attr_reader :config, :launcher

    def initialize(config)
      @config = config
      @stop_lock = Mutex.new
    end

    def configure
      yield @config if block_given?
      self
    end

    def run
      Robin.server!
      @config.redis = @config.redis_options # resize the pool for server use
      @launcher = Launcher.new(@config, embedded: true)
      # Stops asked for from the dashboard go through #stop too, so a later
      # #stop (e.g. the host process exiting) waits for them to finish.
      @launcher.on_stop_request = -> { Thread.new { stop } }
      @launcher.run
      self
    end

    def quiet = @launcher&.quiet

    # Stops the server gracefully and returns once it has stopped. Calling
    # it again (from any thread) waits for the first stop and does nothing.
    def stop
      @stop_lock.synchronize do
        @launcher.stop unless @launcher.nil? || @launcher.stopping?
      end
    end
  end
end
