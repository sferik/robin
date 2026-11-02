# frozen_string_literal: true

require "puma/plugin"
require "puma/dsl"

module Puma
  # Runs an embedded Robin server in every Puma process that serves
  # requests: each worker in cluster mode, the server itself in single mode.
  #
  #   # config/puma.rb
  #   plugin :robin
  #   robin_config do |config| # optional, like Robin.configure_embed's block
  #     config.concurrency = 2
  #   end
  #
  # Robin is only required once the application has loaded in the process
  # that runs it, never in Puma's master: requiring it there would activate
  # gems in the master that every worker inherits, so after a deploy that
  # changes their versions, phased restarts would boot workers that can't
  # load the new bundle. Starting after the application has loaded also
  # means the application's own Robin configuration (Redis, middleware)
  # is in place.
  #
  # The server starts when Puma's server starts accepting requests, and
  # stops (finishing running jobs or putting them back on their queues)
  # while Puma stops: on shutdown, on hot and phased restarts and when
  # a worker is replaced.
  class RobinPlugin < Plugin
    # Server states Puma::Server reports when it stops accepting requests.
    STOPPING = %i[stop restart halt].freeze

    # Puma::DSL methods: the blocks, run with Robin's config before the
    # first server starts, are kept in Puma's options.
    module DSL
      def robin_config(&block)
        raise ArgumentError, "robin_config needs a block" unless block

        (@options[:robin_config] ||= []) << block
      end
    end

    def start(launcher)
      @launcher = launcher
      warn_about_master if ENV.key?("PUMA_BUNDLER_PRUNED")
      launcher.events.register(:state) { |state| changed(state) }
    end

    # Puma's server is :booting, :running, stopping (STOPPING) or :done.
    def changed(state)
      # A worker forked from another (fork_worker) inherits this object.
      forget_parent unless @pid == Process.pid
      case state
      when :running then run
      when *STOPPING then stop
      when :done then stop&.join
      end
    end

    private

    def forget_parent
      @pid = Process.pid
      @robin = nil
    end

    def run
      return if @robin

      require "robin"
      blocks = @configured ? [] : Array(@launcher.options[:robin_config]) #: Array[^(Robin::Config) -> void]
      embed = Robin.configure_embed { |config| blocks.each { |block| block.call(config) } }
      @configured = true
      warn_about_timeout
      @robin = embed.run
      log "* Robin #{Robin::VERSION} running #{Robin.config.total_concurrency} worker thread(s)"
    rescue => e
      log_error("start", e)
    end

    # Stops the server in the background, so Puma can finish its requests
    # meanwhile, and returns the thread doing it (or that did, if any).
    def stop
      robin = @robin
      @robin = nil
      @stopper = Thread.new { stop_now(robin) } if robin
      @stopper
    end

    def stop_now(robin)
      robin.stop
      log "* Robin stopped"
    rescue => e
      log_error("stop", e)
    end

    # In cluster mode Puma kills a worker that's still stopping after
    # worker_shutdown_timeout.
    def warn_about_timeout
      options = @launcher.options
      return unless options.fetch(:workers).positive?

      needed = Robin.config.timeout + Robin::Launcher::HARD_SHUTDOWN_GRACE
      limit = options.fetch(:worker_shutdown_timeout)
      return if needed < limit

      log "! Robin may need #{needed}s to stop (config.timeout plus #{Robin::Launcher::HARD_SHUTDOWN_GRACE}s), " \
        "but Puma kills workers after worker_shutdown_timeout (#{limit}s)"
    end

    # The master of a pruned bundle must not have Robin's gems activated.
    def warn_about_master
      return unless defined?(Robin.configure_embed) || Gem.loaded_specs.key?("robin")

      log "! Robin is loaded in Puma's master process, so workers inherit the gems it activated and phased " \
        "restarts can fail after a deploy changes their versions. Don't require robin in config/puma.rb, " \
        "and with prune_bundler add extra_runtime_dependencies [\"robin\"]"
    end

    def log(message) = @launcher.log_writer.log(message)

    def log_error(what, error)
      log "! Robin failed to #{what}: #{error} (#{error.class})"
      # (A rescued error has a backtrace.)
      backtrace = error.backtrace #: Array[String]
      backtrace.each { |line| log "    #{line}" }
    end
  end

  DSL.include(RobinPlugin::DSL)
  Plugins.register("robin", RobinPlugin)
end
