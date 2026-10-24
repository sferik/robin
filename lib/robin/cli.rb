# frozen_string_literal: true

require "optparse"
require "yaml"
require "erb"
require "net/http"
require_relative "rails/app_loader"

module Robin
  # The `robin` command.
  #
  #   robin -r ./app.rb -c 10 -q critical,3 -q default
  #   robin -C config/robin.yml
  #   robin swarm -n 4            # see Robin::Swarm
  #   robin stats                 # print cluster stats as JSON
  #   robin deploy "v42"          # mark a deploy (see Robin::Deploy)
  #
  # It boots Rails apps itself (see Robin::Rails::AppLoader). Gems extend
  # the command with plugin files at robin/plugins/*.rb (found with
  # Gem.find_files and loaded before options are parsed). A plugin can add
  # an app loader, which boots an application directory given with -r, or
  # an environment variable that names the application environment.
  class CLI
    # INFO (Ctrl-T in a terminal) exists on macOS and the BSDs only.
    SIGNALS = %w[INT TERM TSTP TTIN INFO USR2].freeze
    PLUGIN_GLOB = "robin/plugins/*.rb"
    HEALTH_TIMEOUT = 2

    @app_loaders = [Rails::AppLoader]
    @environment_variables = %w[RAILS_ENV APP_ENV RACK_ENV]
    @config_paths = %w[config/robin.yml config/robin.yml.erb]
    @config_file_hooks = []

    class << self
      # Callables tried in order with an application directory; the first
      # that returns truthy has loaded the app. Otherwise the directory's
      # app.rb, if any, is required.
      attr_reader :app_loaders

      # Variables naming the application environment, by precedence. They
      # pick the config file section, and -e sets all of them.
      attr_reader :environment_variables

      # Config files used (the first that exists) without -C.
      attr_reader :config_paths

      # Callables run with the config file's settings (a Hash with Symbol
      # keys, the environment's section merged in) and the config, once
      # the command's own options are applied: a plugin can apply settings
      # of its own.
      attr_reader :config_file_hooks

      # The app directory's name, or, in a Capistrano-style release
      # directory (/srv/app/releases/20260101120000), the app's.
      def default_tag(dir)
        parent = File.dirname(dir)
        (File.basename(parent) == "releases") ? File.basename(File.dirname(parent)) : File.basename(dir)
      end

      def plugin_files = Gem.find_files(PLUGIN_GLOB)

      def load_plugins
        plugin_files.each { |file| require file }
      end
    end

    attr_reader :config, :launcher

    def initialize(argv = ARGV, config: Robin.config)
      @argv = argv.dup
      @config = config
      @options = {}
      @file_options = {}
    end

    def run
      CLI.load_plugins
      command = @argv.first unless @argv.first.to_s.start_with?("-")
      case command
      when "swarm"
        parse
        Swarm.new(self).run
      when "stats"
        parse
        boot(server: false)
        stats = Stats.new(config: config)
        puts JSON.pretty_generate(stats.to_h.merge({"queues" => stats.queues}))
      when "top"
        parse
        abort "robin top needs a terminal" unless $stdin.tty? && $stdout.tty?
        boot(server: false)
        Top.new(config: config).run
      when "deploy"
        parse
        boot(server: false)
        Deploy.mark!(@argv.drop(1).join(" ").then { |l| l unless l.empty? }, config: config)
      when "health"
        parse
        exit(health_check)
      when "version"
        puts "Robin #{VERSION}"
      when nil
        parse
        boot
        prepare
        serve
      else
        abort "robin: unknown command #{command.inspect} (try `robin --help`)"
      end
    end

    def parse
      parser = OptionParser.new do |o|
        o.require_exact = true
        o.banner = "Usage: robin [swarm|stats|top|deploy [LABEL]|health|version] [options]"
        o.on("-c", "--concurrency N", Integer, "Worker threads (default 5)") { |v| @options[:concurrency] = v }
        o.on("-q", "--queue NAME[,WEIGHT]", "Queue to process; repeatable") { |v| (@options[:queues] ||= []) << v }
        o.on("-r", "--require PATH", "File or app directory to load") { |v| @options[:require] = v }
        o.on("-e", "--environment ENV", "Application environment") { |v| @options[:environment] = v }
        o.on("-t", "--timeout SECONDS", Integer, "Shutdown timeout (default 25)") { |v| @options[:timeout] = v }
        o.on("-g", "--tag TAG", "Process tag shown in the web UI") { |v| @options[:tag] = v }
        o.on("-C", "--config PATH", "YAML config file") { |v| @options[:config_file] = v }
        o.on("-n", "--processes N", "swarm: child processes (a decimal: per CPU core)") { |v| @options[:processes] = v }
        o.on("--health-port PORT", Integer, "Serve a health check on PORT") { |v| @options[:health_port] = v }
        o.on("-v", "--verbose", "Debug logging") { @options[:verbose] = true }
        o.on("--json-logs", "Log one JSON object per line") { @options[:json_logs] = true }
        o.on("-V", "--version", "Print version") do
          puts "Robin #{VERSION}"
          exit
        end
        o.on("-h", "--help", "Show help") do
          puts o
          exit
        end
      end
      parser.parse!(@argv)
      load_config_file
      @options
    end

    attr_reader :options

    # Loads the application and applies options. Commands that only read
    # or write Redis (stats, top, deploy) boot as clients: the app's
    # configure_client blocks run, not its configure_server blocks.
    def boot(server: true)
      Robin.server! if server
      if (env = @options[:environment])
        CLI.environment_variables.each { |name| ENV[name] = env }
        config.environment = env
      end
      load_application
      apply_options
    end

    # Loads all of Robin and tidies the heap (a full GC, compaction) before
    # a standalone server starts, rather than while it runs jobs. (A swarm
    # does both before forking its children.)
    def prepare
      Robin.eager_load!
      Process.warmup
    end

    # Runs a server until INT or TERM.
    def serve
      @launcher = build_launcher
      reader, @signals = IO.pipe
      @launcher.on_stop_request = -> { signal("TERM") }
      previous = trap_signals(SIGNALS)
      begin
        print_banner
        @launcher.run
        wait_for_signals(reader)
        config.fire_event(:exit)
      ensure
        previous.each { |sig, handler| trap(sig, handler) }
      end
    end

    # Hands a signal to the serving thread. Signal handlers can't do much
    # more than write to a pipe safely.
    def signal(name)
      @signals.write_nonblock("#{name}\n", exception: false)
    end

    private

    def build_launcher = Launcher.new(config)

    # Installs handlers and returns the previous ones. A handler the app (or
    # a gem) had already installed still runs, after Robin's. Signals the
    # platform doesn't support are skipped.
    def trap_signals(names)
      names.each_with_object({}) do |sig, previous|
        previous[sig] = trap(sig) do |signo|
          signal(sig)
          chain(previous.fetch(sig), signo)
        end
      rescue ArgumentError
        # not available on this platform
      end
    end

    # Runs a previous signal handler, if it was a block (not "DEFAULT",
    # "IGNORE" and such).
    def chain(handler, signo)
      handler.call(signo) if handler.respond_to?(:call)
    rescue => e
      config.handle_exception(e, {context: "previous #{Signal.signame(signo)} handler"})
    end

    def wait_for_signals(reader)
      loop do
        case reader.gets(chomp: true)
        when "INT", "TERM" then return @launcher.stop
        when "TSTP" then @launcher.quiet
        when "TTIN", "INFO" then @launcher.dump_threads
        when "USR2" then reopen_logs
        end
      end
    end

    def reopen_logs
      config.logger.reopen if config.logger.respond_to?(:reopen)
    end

    # `robin health`: asks the health endpoint of the server on this host
    # (see Robin::HealthServer) and prints its report. True when healthy.
    def health_check
      port = @options[:health_port] || ENV["ROBIN_HEALTH_PORT"]
      abort "robin: no health port (use --health-port, health_port in robin.yml or ROBIN_HEALTH_PORT)" unless port

      response = health_http(port).start { |http| http.get("/") }
      puts response.body
      response.code == "200"
    rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout => e
      warn "robin: health check failed: #{e.class}: #{e.message}"
      false
    end

    # A client for the local health endpoint: quick to give up, and never
    # retrying (Net::HTTP retries idempotent requests once by default).
    def health_http(port)
      Net::HTTP.new("127.0.0.1", Integer(port)).tap do |http|
        http.open_timeout = HEALTH_TIMEOUT
        http.read_timeout = HEALTH_TIMEOUT
        http.max_retries = 0
      end
    end

    def load_config_file
      path = @options[:config_file]
      # In the current directory, else in the app directory given with -r
      # (when -r names a file, nothing can be found under it).
      app = @options[:require]
      roots = [".", *app]
      path ||= roots.product(CLI.config_paths).map { |root, p| File.join(root, p) }.find { |p| File.exist?(p) }
      return unless path

      raw = YAML.safe_load(ERB.new(File.read(path), trim_mode: "-").result, permitted_classes: [Symbol], aliases: true) || {}
      raw = raw.transform_keys(&:to_sym)
      env = (@options[:environment] || ENV.values_at(*CLI.environment_variables).compact.first).to_s
      section = raw[env.to_sym]
      raw = raw.merge(section.transform_keys(&:to_sym)) if section.instance_of?(Hash)
      @file_options = raw
      @options = raw.slice(:concurrency, :queues, :require, :timeout, :tag, :environment, :processes, :health_port).merge(@options)
    end

    def apply_options
      # Values from YAML may be explicitly null; those leave defaults alone.
      if (concurrency = @options[:concurrency]) then config.concurrency = concurrency end
      if (queues = @options[:queues]) then config.queues = queues end
      if (timeout = @options[:timeout]) then config.timeout = timeout end
      if (tag = @options[:tag]) then config.tag = tag end
      if (port = @options[:health_port]) then config.health_port = port end
      config.tag ||= CLI.default_tag(Dir.pwd)
      config.logger.level = Logger::DEBUG if @options.key?(:verbose)
      config.logger.formatter = JobLogger::JSONFormatter.new if @options.key?(:json_logs)
      @file_options.fetch(:capsules, {}).each do |name, opts|
        opts = opts.transform_keys(&:to_sym)
        config.capsule(name) do |cap|
          if (concurrency = opts[:concurrency]) then cap.concurrency = concurrency end
          if (queues = opts[:queues]) then cap.queues = queues end
        end
      end
      if config.capsules.values.any? { |c| c.queues.empty? }
        abort "robin: every capsule needs at least one queue"
      end
      CLI.config_file_hooks.each { |hook| hook.call(@file_options, config) }
    end

    def load_application
      path = @options[:require] || "."
      if File.directory?(path)
        load_directory(path)
      elsif File.exist?(path)
        require File.expand_path(path)
      else
        abort "robin: can't load #{path.inspect}"
      end
    end

    def load_directory(path)
      return if CLI.app_loaders.any? { |loader| loader.call(path) }

      app = File.join(path, "app.rb")
      if File.exist?(app)
        require File.expand_path(app)
      else
        config.logger.warn { "robin: nothing to load in #{path} (use -r FILE)" }
      end
    end

    def print_banner
      return unless $stdout.tty?

      puts <<~BANNER
        \e[31m       __
           <(o )___    \e[1mRobin #{VERSION}\e[0;31m
            ( ._> /    #{config.total_concurrency} threads · queues: #{config.capsules.values.flat_map(&:queues).uniq.join(", ")}
             `---'     LGPL-3.0 · fully open source\e[0m
      BANNER
    end
  end
end
