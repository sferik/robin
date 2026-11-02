# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/api"
require "tmpdir"
require "stringio"
require "open3"

# Files loaded by the CLI under test record themselves here.
module CLILoadProbe
  class << self
    attr_accessor :value
  end
end

class CLITest < RobinTest
  include ApiTestSupport

  cover "Robin::CLI*"

  class FakeLauncher
    attr_accessor :on_stop_request
    attr_reader :calls

    def initialize = @calls = []

    def run = @calls << :run

    def stop = @calls << :stop

    def quiet = @calls << :quiet

    def dump_threads = @calls << :dump
  end

  class TestCLI < Robin::CLI
    attr_reader :fake, :prepared

    def build_launcher = @fake = FakeLauncher.new

    def prepare = @prepared = !@fake
  end

  class ReopenLogger < Logger
    attr_reader :reopened

    def reopen(*) = @reopened = true
  end

  class TTY < StringIO
    def tty? = true
  end

  ENV_KEYS = %w[APP_ENV RAILS_ENV RACK_ENV].freeze

  def setup
    super
    Thread.current[:robin_cli_test] = true
    @env = ENV.to_h.slice(*ENV_KEYS)
    ENV_KEYS.each { |k| ENV.delete(k) }
    @server = Robin.server?
    Robin.instance_variable_set(:@server, false)
    # Installed gems' plugins stay out.
    @app_loaders = Robin::CLI.app_loaders.dup
    @environment_variables = Robin::CLI.environment_variables.dup
    @plugin_files = Robin::CLI.method(:plugin_files)
    Robin::CLI.define_singleton_method(:plugin_files) { [] }
  end

  def teardown
    Thread.current[:robin_cli_test] = nil
    ENV_KEYS.each { |k| ENV.delete(k) }
    @env.each { |k, v| ENV[k] = v }
    Robin.instance_variable_set(:@server, @server)
    Robin::CLI.app_loaders.replace(@app_loaders)
    Robin::CLI.environment_variables.replace(@environment_variables)
    Robin::CLI.define_singleton_method(:plugin_files, @plugin_files)
    super
  end

  # Raised instead of exiting while a CLI test runs. Mutant runs tests in a
  # fork, and a real SystemExit (from our code or OptionParser's) would end
  # that fork early with a success status.
  class Exited < StandardError; end

  module NoExit
    def exit(status = true)
      Thread.current[:robin_cli_test] ? raise(Exited, "exit #{status}") : super
    end

    def abort(message = nil)
      return super unless Thread.current[:robin_cli_test]

      warn message if message
      raise Exited
    end
  end
  # On Object, not Kernel: TruffleRuby doesn't carry a module prepended to
  # Kernel into the classes that already include it.
  Object.prepend(NoExit)

  def cli(*argv, klass: Robin::CLI) = klass.new(argv, config: alt_config)

  # Records what the CLI requires (and still requires it).
  def spy_requires(command)
    log = []
    command.define_singleton_method(:require) do |path|
      log << path
      super(path)
    end
    log
  end

  def tmpdir
    dir = Dir.mktmpdir("robin-cli")
    yield dir
  ensure
    FileUtils.remove_entry(dir)
  end

  def write(dir, path, body)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
    full
  end

  def with_stdout(io)
    previous = $stdout
    $stdout = io
    yield
  ensure
    $stdout = previous
  end

  # Runs #serve on a thread, waits for the launcher to start, yields, and
  # waits for #serve to return.
  def serving(cli, method = :serve)
    thread = Thread.new do
      Thread.current[:robin_cli_test] = true
      cli.public_send(method)
    end
    eventually { cli.fake&.calls&.include?(:run) }
    yield

    assert thread.join(5), "serve didn't return"
  end

  # -- run --------------------------------------------------------------

  def test_version_command
    out, = capture_io { cli("version").run }

    assert_equal "Robin #{Robin::VERSION}\n", out
  end

  def test_unknown_command
    _, err = capture_io { assert_raises(Exited) { cli("bogus").run } }

    assert_equal "robin: unknown command \"bogus\" (try `robin --help`)\n", err
  end

  def test_stats_command
    alt("SET", alt_key("stat", "processed"), "12")
    push("q", job("1"))
    out, = capture_io { cli("stats", "-g", "statstag").run }
    stats = JSON.parse(out)

    assert_equal 12, stats["processed"]
    assert_equal({"q" => 1}, stats["queues"])
    refute_predicate Robin, :server?
    assert_equal "statstag", alt_config.tag
  end

  def test_top_needs_a_terminal
    [[false, false], [true, false], [false, true]].each do |stdin_tty, stdout_tty|
      stdin = stdin_tty ? TTY.new : StringIO.new
      stdout = stdout_tty ? TTY.new : StringIO.new
      stdin_was, stdout_was, stderr_was = $stdin, $stdout, $stderr
      $stdin, $stdout, $stderr = stdin, stdout, StringIO.new
      begin
        assert_raises(Exited) { cli("top").run }
        assert_equal "robin top needs a terminal\n", $stderr.string
      ensure
        $stdin, $stdout, $stderr = stdin_was, stdout_was, stderr_was
      end
    end

    refute_predicate Robin, :server?
  end

  def test_top_command
    ran = []
    original = Robin::Top.instance_method(:run)
    Robin::Top.define_method(:run) { ran << instance_variable_get(:@config) }
    stdin_was, stdout_was = $stdin, $stdout
    $stdin, $stdout = TTY.new, TTY.new
    cli("top", "-g", "toptag").run

    assert_equal [alt_config], ran
    assert_equal "toptag", alt_config.tag
    refute_predicate Robin, :server?
  ensure
    $stdin, $stdout = stdin_was, stdout_was
    Robin::Top.define_method(:run, original)
  end

  def test_deploy_command
    cli("deploy", "-g", "t", "v42", "abc123").run
    cli("deploy").run
    marks = Robin::Deploy.list(from: Time.now - 60, config: alt_config)

    assert_equal ["v42 abc123", nil], marks.map { |d| d["label"] }
    refute_predicate Robin, :server?
  end

  def test_redis_commands_run_the_apps_client_configuration
    tmpdir do |dir|
      source = <<~RUBY
        Robin.configure_server { CLILoadProbe.value = :server }
        Robin.configure_client { CLILoadProbe.value = :client }
      RUBY
      cli("deploy", "-r", write(dir, "client.rb", source)).run

      assert_equal :client, CLILoadProbe.value
      command = cli("-r", write(dir, "server.rb", source))
      command.parse
      command.boot

      assert_equal :server, CLILoadProbe.value
    end
  end

  # A health endpoint answering with +report+.
  def with_health(report)
    launcher = Object.new
    launcher.define_singleton_method(:health) { report }
    server = Robin::HealthServer.new(launcher, port: 0, bind: "127.0.0.1")
    yield server.port
  ensure
    server&.stop
  end

  def health(*argv)
    Thread.current[:robin_cli_test] = true
    error = nil
    out, err = capture_io { error = assert_raises(Exited) { cli("health", *argv).run } }
    [error.message, out, err]
  ensure
    Thread.current[:robin_cli_test] = nil
  end

  def test_health_command
    with_health({"healthy" => true, "status" => "ok"}) do |port|
      assert_equal ["exit true", %({"healthy":true,"status":"ok"}\n), ""], health("--health-port", port.to_s)
    end
    with_health({"healthy" => false}) do |port|
      ENV["ROBIN_HEALTH_PORT"] = port.to_s

      assert_equal ["exit false", %({"healthy":false}\n), ""], health
    end
  ensure
    ENV.delete("ROBIN_HEALTH_PORT")
  end

  def test_health_command_without_a_server
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    status, out, err = health("--health-port", port.to_s)

    assert_equal ["exit false", ""], [status, out]
    assert_match(/\Arobin: health check failed: Errno::ECONNREFUSED: .+\n\z/, err)
  end

  def test_health_command_times_out
    silent = TCPServer.new("127.0.0.1", 0)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, _, err = health("--health-port", silent.addr[1].to_s)

    assert_equal "exit false", status
    assert_equal "robin: health check failed: Net::ReadTimeout: Net::ReadTimeout with #<TCPSocket:(closed)>\n", err
    assert_in_delta 2, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, 0.5
  ensure
    silent&.close
  end

  def test_health_http_client
    http = cli.send(:health_http, "7433")

    assert_equal ["127.0.0.1", 7433, 2, 2, 0], [http.address, http.port, http.open_timeout, http.read_timeout, http.max_retries]
    assert_equal 2, Robin::CLI::HEALTH_TIMEOUT
  end

  def test_health_command_needs_a_port
    status, _, err = health

    assert_equal ["CLITest::Exited", "robin: no health port (use --health-port, health_port in robin.yml or ROBIN_HEALTH_PORT)\n"], [status, err]
  end

  def test_swarm_command
    ran = []
    fake = Struct.new(:cli) { define_method(:run) { ran << cli } }
    command = cli("swarm", "-n", "3")
    with_singleton(Robin::Swarm, :new, ->(c) { fake.new(c) }) { command.run }

    assert_equal [command], ran
    assert_equal "3", command.options[:processes]
  end

  def test_no_arguments_boots_and_serves
    command = cli(klass: TestCLI)
    serving(command, :run) { command.signal("TERM") }

    assert_equal %i[run stop], command.fake.calls
    assert_true command.prepared, "prepared before serving"
  end

  def test_prepare_loads_robin_and_tidies_the_heap
    calls = []
    with_singleton(Robin, :eager_load!, -> { calls << :eager_load }) do
      with_singleton(Process, :warmup, -> { calls << :warmup }) { cli.prepare }
    end

    assert_equal %i[eager_load warmup], calls
  end

  def test_default_command_boots_and_serves
    command = cli("-c", "3", klass: TestCLI)
    serving(command, :run) { command.signal("TERM") }

    assert_equal 3, alt_config.concurrency
    assert_equal %i[run stop], command.fake.calls
  end

  # -- parse ------------------------------------------------------------

  def test_parse_options
    tmpdir do |dir|
      file = write(dir, "robin.yml", "{}\n")
      argv = ["-c", "4", "-q", "a,2", "-q", "b", "-r", "./app.rb", "-e", "prod", "-t", "9", "-g", "tag",
        "-C", file, "-n", "3", "-v", "--json-logs", "--health-port", "7433"]
      parsed = Robin::CLI.new(argv, config: alt_config).parse

      assert_equal({concurrency: 4, queues: ["a,2", "b"], require: "./app.rb", environment: "prod", timeout: 9,
                    tag: "tag", config_file: file, processes: "3", verbose: true, json_logs: true, health_port: 7433}, parsed)
      assert_equal "-c", argv.first
    end
  end

  def test_parse_long_options
    parsed = cli("--concurrency", "2", "--queue", "x", "--require", "r", "--environment", "e", "--timeout", "1",
      "--tag", "t", "--processes", "5", "--verbose").parse

    assert_equal({concurrency: 2, queues: ["x"], require: "r", environment: "e", timeout: 1, tag: "t", processes: "5",
                  verbose: true}, parsed)
  end

  HELP = <<~HELP
    Usage: robin [swarm|stats|top|deploy [LABEL]|health|version] [options]
        -c, --concurrency N              Worker threads (default 5)
        -q, --queue NAME[,WEIGHT]        Queue to process; repeatable
        -r, --require PATH               File or app directory to load
        -e, --environment ENV            Application environment
        -t, --timeout SECONDS            Shutdown timeout (default 25)
        -g, --tag TAG                    Process tag shown in the web UI
        -C, --config PATH                YAML config file
        -n, --processes N                swarm: child processes (a decimal: per CPU core)
            --health-port PORT           Serve a health check on PORT
        -v, --verbose                    Debug logging
            --json-logs                  Log one JSON object per line
        -V, --version                    Print version
        -h, --help                       Show help
  HELP

  def test_help_text
    out, = capture_io { assert_raises(Exited) { cli("-h").parse } }

    assert_equal HELP, out
  end

  def test_options_must_match_exactly
    assert_raises(OptionParser::InvalidOption) { cli("--conc", "2").parse }
    assert_raises(OptionParser::InvalidOption) { cli("-p", "2").parse }
  end

  def test_defaults_to_argv_and_global_config
    saved = ARGV.dup
    ARGV.replace(["-c", "7"])
    command = Robin::CLI.new

    assert_same Robin.config, command.config
    assert_equal({concurrency: 7}, command.parse)
    assert_equal ["-c", "7"], ARGV
  ensure
    ARGV.replace(saved)
  end

  def test_parse_without_options
    command = cli

    assert_empty command.parse
    assert_same command.options, command.parse
  end

  def test_version_and_help_flags
    out, = capture_io { assert_raises(Exited) { cli("-V").parse } }

    assert_equal "Robin #{Robin::VERSION}\n", out
    out, = capture_io { assert_raises(Exited) { cli("--version").parse } }

    assert_equal "Robin #{Robin::VERSION}\n", out
    out, = capture_io { assert_raises(Exited) { cli("-h").parse } }

    assert_match(/\AUsage: robin \[swarm\|stats\|top\|deploy \[LABEL\]\|health\|version\] \[options\]\n/, out)
    assert_match(/--json-logs/, out)
    out, = capture_io { assert_raises(Exited) { cli("--help").parse } }

    assert_match(/\AUsage: robin/, out)
  end

  # -- config files ------------------------------------------------------

  YAML_CONFIG = <<~YAML
    concurrency: <%= 2 + 1 %>
    queues: &queues [a, b]
    timeout: 7
    tag: filetag
    require: ./from_file.rb
    processes: 2
    environment: fileenv
    health_port: 7000
    extra: :sym
    staging: 5
    production:
      queues: *queues
      concurrency: 9
  YAML

  def test_config_file_with_erb_aliases_and_environment
    tmpdir do |dir|
      file = write(dir, "robin.yml", YAML_CONFIG)

      assert_equal({concurrency: 3, queues: %w[a b], timeout: 7, tag: "filetag", require: "./from_file.rb",
                    processes: 2, environment: "fileenv", health_port: 7000, config_file: file}, cli("-C", file).parse)
      production = cli("-C", file, "-e", "production").parse

      assert_equal [9, 7, %w[a b]], production.values_at(:concurrency, :timeout, :queues)
      assert_equal 1, cli("-C", file, "-e", "production", "-c", "1").parse[:concurrency]
      assert_equal 3, cli("-C", file, "-e", "staging").parse[:concurrency]
    end
  end

  def test_config_environment_from_env_vars
    tmpdir do |dir|
      file = write(dir, "robin.yml", "concurrency: 1\napp: {concurrency: 2}\nrails: {concurrency: 3}\nrack: {concurrency: 4}\n")
      ENV["RACK_ENV"] = "rack"

      assert_equal 4, cli("-C", file).parse[:concurrency]
      ENV["APP_ENV"] = "app"

      assert_equal 2, cli("-C", file).parse[:concurrency]
      ENV["RAILS_ENV"] = "rails"

      assert_equal 3, cli("-C", file).parse[:concurrency]
      Robin::CLI.environment_variables.push(Robin::CLI.environment_variables.shift)

      assert_equal 2, cli("-C", file).parse[:concurrency]
    end
  end

  def test_empty_config_file
    tmpdir do |dir|
      file = write(dir, "robin.yml", "")

      assert_equal({config_file: file}, cli("-C", file).parse)
    end
  end

  def test_default_config_file_locations
    tmpdir do |dir|
      Dir.chdir(dir) do
        assert_empty cli.parse
        write(dir, "config/robin.yml.erb", "tag: erb\n")

        assert_equal({tag: "erb"}, cli.parse)
        write(dir, "config/robin.yml", "tag: yml\n")

        assert_equal({tag: "yml"}, cli.parse)
      end
    end
  end

  def test_config_file_in_the_app_directory
    tmpdir do |dir|
      app = File.join(dir, "app")
      write(app, "config/robin.yml", "tag: app\n")
      Dir.chdir(dir) do
        assert_equal({require: "app", tag: "app"}, cli("-r", "app").parse)
        write(dir, "app.rb", "")

        assert_equal({require: "app.rb"}, cli("-r", "app.rb").parse)
        write(dir, "config/robin.yml", "tag: here\n")

        assert_equal "here", cli("-r", "app").parse[:tag], "the current directory's comes first"
      end
    end
  end

  def test_config_paths_can_be_extended
    tmpdir do |dir|
      Dir.chdir(dir) do
        Robin::CLI.config_paths.unshift("config/other.yml")
        write(dir, "config/robin.yml", "tag: robin\n")
        write(dir, "config/other.yml", "tag: other\n")

        assert_equal({tag: "other"}, cli.parse)
      ensure
        Robin::CLI.config_paths.delete("config/other.yml")
      end
    end

    assert_equal %w[config/robin.yml config/robin.yml.erb], Robin::CLI.config_paths
  end

  def test_config_files_may_use_erb_trim_mode
    tmpdir do |dir|
      file = write(dir, "robin.yml", "<%- if true -%>\ntag: trimmed\n<%- end -%>\n")

      assert_equal "trimmed", cli("-C", file).parse[:tag]
    end
  end

  # -- boot / apply_options ----------------------------------------------

  def test_config_file_hooks_get_the_files_settings
    tmpdir do |dir|
      file = write(dir, "robin.yml", "max_retries: 7\ntag: t\nproduction: {max_retries: 9}\n")
      seen = []
      Robin::CLI.config_file_hooks << ->(options, config) { seen << [options, config] }
      command = cli("-C", file, "-e", "production")
      command.parse
      command.boot

      assert_equal [[{max_retries: 9, tag: "t", production: {"max_retries" => 9}}, alt_config]], seen
    ensure
      Robin::CLI.config_file_hooks.clear
    end

    assert_empty Robin::CLI.config_file_hooks
  end

  def test_boot_sets_environment_and_loads_a_file
    tmpdir do |dir|
      app = write(dir, "app_file.rb", "CLILoadProbe.value = :file\n")
      command = cli("-r", app, "-e", "staging")
      command.parse
      command.boot

      assert_equal :file, CLILoadProbe.value
      assert_predicate Robin, :server?
      assert_equal %w[staging staging staging], ENV.values_at(*ENV_KEYS)
      assert_equal "staging", alt_config.environment
    end
  end

  def test_boot_without_environment_leaves_it_alone
    ENV["RACK_ENV"] = "kept"
    alt_config.environment = "untouched"
    command = cli
    command.parse
    command.boot

    assert_equal "untouched", alt_config.environment
    assert_equal({"RACK_ENV" => "kept"}, ENV.to_h.slice(*ENV_KEYS))
  end

  def test_loads_files_and_app_directories
    tmpdir do |dir|
      write(dir, "plain/app.rb", "CLILoadProbe.value = :plain\n")
      write(dir, "plain/config/robin.yml", "{}\n")
      write(dir, "file.rb", "CLILoadProbe.value = :file\n")
      Dir.chdir(dir) do
        real = Dir.pwd
        {"plain" => File.join(real, "plain/app.rb"), "file.rb" => File.join(real, "file.rb")}.each do |name, path|
          command = cli("-r", name)
          required = spy_requires(command)
          command.parse
          command.boot

          assert_equal File.basename(name, ".rb").to_sym, CLILoadProbe.value
          assert_equal [path], required
        end
      end
    end
  end

  def test_warns_about_directories_with_nothing_to_load
    tmpdir do |dir|
      log = StringIO.new
      alt_config.logger = Logger.new(log)
      CLILoadProbe.value = nil
      command = cli("-r", dir)
      required = spy_requires(command)
      command.parse
      command.boot

      assert_nil CLILoadProbe.value
      assert_empty required
      assert_includes log.string, "WARN -- : robin: nothing to load in #{dir} (use -r FILE)"
    end
  end

  def test_app_loaders_boot_directories
    tmpdir do |dir|
      write(dir, "custom/marker", "")
      write(dir, "custom/app.rb", "CLILoadProbe.value = :app_rb\n")
      write(dir, "plain/app.rb", "CLILoadProbe.value = :plain\n")
      seen = []
      Robin::CLI.app_loaders << ->(path) { seen << [:first, path] && false }
      Robin::CLI.app_loaders << lambda do |path|
        seen << [:custom, path]
        File.exist?(File.join(path, "marker")) && (CLILoadProbe.value = :custom)
      end
      Robin::CLI.app_loaders << ->(path) { seen << [:last, path] && nil }
      Dir.chdir(dir) do
        %w[custom plain].each do |name|
          command = cli("-r", name)
          required = spy_requires(command)
          command.parse
          command.boot

          assert_equal name.to_sym, CLILoadProbe.value
          assert_equal((name == "plain") ? [File.join(Dir.pwd, "plain/app.rb")] : [], required)
        end
      end

      assert_equal [[:first, "custom"], [:custom, "custom"], [:first, "plain"], [:custom, "plain"], [:last, "plain"]], seen
    end
  end

  def test_app_loaders_default_to_rails_apps
    assert_equal [Robin::Rails::AppLoader], @app_loaders
    assert_same Robin::CLI.app_loaders, Robin::CLI.app_loaders
    assert_equal %w[RAILS_ENV APP_ENV RACK_ENV], @environment_variables
    assert_same Robin::CLI.environment_variables, Robin::CLI.environment_variables
  end

  def test_run_loads_plugins_before_parsing
    tmpdir do |dir|
      plugin = write(dir, "robin/plugins/probe.rb",
        "CLILoadProbe.value = :plugin\nRobin::CLI.environment_variables.unshift(\"ROBIN_PROBE_ENV\")\n")
      file = write(dir, "robin.yml", "concurrency: 1\nprobe: {concurrency: 7}\n")
      ENV["ROBIN_PROBE_ENV"] = "probe"
      Robin::CLI.define_singleton_method(:plugin_files) { [plugin] }
      fake = Struct.new(:cli) { define_method(:run) { nil } }
      command = cli("swarm", "-C", file)
      with_singleton(Robin::Swarm, :new, ->(c) { fake.new(c) }) { command.run }

      assert_equal 7, command.options[:concurrency]
      assert_equal :plugin, CLILoadProbe.value
    ensure
      ENV.delete("ROBIN_PROBE_ENV")
    end
  end

  def test_plugin_files_come_from_installed_gems
    with_singleton(Gem, :find_files, ->(glob) { ["found #{glob}"] }) do
      assert_equal ["found robin/plugins/*.rb"], @plugin_files.call
    end
  end

  def test_missing_application
    command = cli("-r", "/nonexistent/robin/app.rb")
    command.parse
    _, err = capture_io { assert_raises(Exited) { command.boot } }

    assert_equal "robin: can't load \"/nonexistent/robin/app.rb\"\n", err
  end

  def test_apply_options
    alt_config.logger.level = Logger::WARN
    command = cli("-c", "6", "-q", "high,2", "-q", "low", "-t", "11", "-g", "mytag", "-v", "--json-logs", "--health-port", "7433")
    command.parse
    command.boot

    assert_equal 7433, alt_config.health_port

    assert_equal 6, alt_config.concurrency
    assert_equal({"high" => 2, "low" => 0}, alt_config.default_capsule.weights)
    assert_equal 11, alt_config.timeout
    assert_equal "mytag", alt_config.tag
    assert_equal Logger::DEBUG, alt_config.logger.level
    assert_instance_of Robin::JobLogger::JSONFormatter, alt_config.logger.formatter
  end

  def test_default_tag
    assert_equal "shop", Robin::CLI.default_tag("/srv/shop")
    assert_equal "shop", Robin::CLI.default_tag("/srv/shop/releases/20260101120000")
    assert_equal "current", Robin::CLI.default_tag("/srv/shop/current")
  end

  def test_apply_options_defaults
    alt_config.logger.level = Logger::WARN
    command = cli
    command.parse
    command.boot

    assert_equal 5, alt_config.concurrency
    assert_equal ["default"], alt_config.queues
    assert_equal 25, alt_config.timeout
    assert_nil alt_config.health_port
    assert_equal File.basename(Dir.pwd), alt_config.tag
    assert_equal Logger::WARN, alt_config.logger.level
    assert_nil alt_config.logger.formatter
    alt_config.tag = "preset"
    command.boot

    assert_equal "preset", alt_config.tag
  end

  def test_null_values_in_config_file_keep_defaults
    tmpdir do |dir|
      file = write(dir, "robin.yml", <<~YAML)
        concurrency:
        queues:
        timeout:
        tag:
        environment:
        capsules:
          blank: {concurrency: , queues: }
      YAML
      ENV["RACK_ENV"] = "kept"
      command = cli("-C", file)
      command.parse
      command.boot

      assert_equal [5, ["default"], 25, File.basename(Dir.pwd)], [alt_config.concurrency, alt_config.queues, alt_config.timeout, alt_config.tag]
      assert_equal [5, ["default"]], [alt_config.capsules["blank"].concurrency, alt_config.capsules["blank"].queues]
      assert_equal "kept", ENV["RACK_ENV"]
    end
  end

  def test_capsules_from_config_file
    tmpdir do |dir|
      file = write(dir, "robin.yml", <<~YAML)
        capsules:
          serial: {concurrency: 1, queues: [ledger]}
          :fast: {queues: ["x,2"]}
          sized: {concurrency: 4}
      YAML
      command = cli("-C", file)
      command.parse
      command.boot

      assert_equal 1, alt_config.capsules["serial"].concurrency
      assert_equal ["ledger"], alt_config.capsules["serial"].queues
      assert_equal({"x" => 2}, alt_config.capsules["fast"].weights)
      assert_equal 5, alt_config.capsules["fast"].concurrency
      assert_equal 4, alt_config.capsules["sized"].concurrency
      assert_equal ["default"], alt_config.capsules["sized"].queues
    end
  end

  def test_capsule_without_queues_aborts
    tmpdir do |dir|
      file = write(dir, "robin.yml", "capsules:\n  broken: {queues: []}\n")
      command = cli("-C", file)
      command.parse
      _, err = capture_io { assert_raises(Exited) { command.boot } }

      assert_equal "robin: every capsule needs at least one queue\n", err
    end
  end

  # -- serve ---------------------------------------------------------------

  def test_serve_handles_signals
    alt_config.logger = ReopenLogger.new(nil)
    exited = []
    alt_config.on(:exit) { exited << true }
    command = cli(klass: TestCLI)
    serving(command) do
      %w[TSTP TTIN INFO USR2 BOGUS].each { |sig| command.signal(sig) }
      command.signal("INT")
    end

    assert_equal %i[run quiet dump dump stop], command.fake.calls
    assert alt_config.logger.reopened
    assert_equal [true], exited
  end

  def test_serve_prints_the_banner_on_a_tty
    tty = TTY.new
    command = cli(klass: TestCLI)
    with_stdout(tty) { serving(command) { command.signal("TERM") } }

    assert_includes tty.string, "Robin #{Robin::VERSION}"
  end

  def test_signal_never_blocks_or_raises_when_the_pipe_is_full
    command = cli
    reader, writer = IO.pipe
    command.instance_variable_set(:@signals, writer)
    20_000.times { command.signal("TTIN") }

    assert_equal "TTIN", reader.gets(chomp: true)
  ensure
    reader&.close
    writer&.close
  end

  def test_launcher_stop_requests_end_serving
    command = cli(klass: TestCLI)
    serving(command) { command.fake.on_stop_request.call }

    assert_equal %i[run stop], command.fake.calls
  end

  def test_usr2_with_a_logger_that_cannot_reopen
    alt_config.logger = Object.new
    command = cli(klass: TestCLI)
    serving(command) do
      command.signal("USR2")
      command.signal("TERM")
    end

    assert_equal %i[run stop], command.fake.calls
  end

  def test_real_signals_reach_the_launcher_and_handlers_are_restored
    original = proc {}
    previous = trap("USR2", original)
    alt_config.logger = ReopenLogger.new(nil)
    command = cli(klass: TestCLI)
    serving(command) do
      Process.kill("USR2", Process.pid)
      eventually { alt_config.logger.reopened }
      command.signal("TERM")
    end

    assert_same original, trap("USR2", previous)
  end

  def test_previous_signal_handlers_still_run
    calls = []
    original = trap("USR2") { |signo| calls << signo }
    command = cli
    command.instance_variable_set(:@signals, StringIO.new)
    previous = command.send(:trap_signals, ["USR2"])
    Process.kill("USR2", Process.pid)
    eventually { calls.any? }

    assert_equal [Signal.list.fetch("USR2")], calls
    assert_equal "USR2\n", command.instance_variable_get(:@signals).string
    assert_kind_of Proc, previous.fetch("USR2")
  ensure
    trap("USR2", original)
  end

  def test_chain_skips_named_handlers_and_reports_failures
    errors = []
    alt_config.error_handlers.replace([->(ex, ctx, _cfg) { errors << [ex.message, ctx] }])
    command = cli

    assert_nil command.send(:chain, "DEFAULT", 31)
    assert_nil command.send(:chain, nil, 31)
    assert_equal :ran, command.send(:chain, ->(signo) { (signo == 31) ? :ran : :wrong }, 31)
    command.send(:chain, ->(_) { raise "handler broke" }, Signal.list.fetch("USR2"))

    assert_equal [["handler broke", {context: "previous USR2 handler"}]], errors
  end

  def test_trap_signals_skips_unsupported_signals
    skip "JRuby accepts traps for unknown signal names" if RUBY_ENGINE == "jruby"

    assert_empty cli.send(:trap_signals, ["BOGUS"])
  end

  def test_build_launcher
    launcher = cli.send(:build_launcher)

    assert_instance_of Robin::Launcher, launcher
    assert_same alt_config, launcher.config
  end

  def test_banner_only_on_a_tty
    alt_config.capsule("other") { |c| c.queues = %w[default extra] }
    command = cli
    out, = capture_io { command.send(:print_banner) }

    assert_empty out
    tty = TTY.new
    with_stdout(tty) { command.send(:print_banner) }

    assert_includes tty.string, "Robin #{Robin::VERSION}"
    assert_includes tty.string, "10 threads · queues: default, extra"
  end

  def test_executable
    out, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "exe/robin", "version")

    assert_predicate status, :success?
    assert_equal "Robin #{Robin::VERSION}\n", out
  end
end
