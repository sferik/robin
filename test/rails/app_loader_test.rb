# frozen_string_literal: true

require_relative "helper"
require "tmpdir"
require "fileutils"

# Files loaded by the app loader under test record themselves here.
module AppLoaderProbe
  class << self
    attr_accessor :value
  end
end

class AppLoaderTest < Minitest::Test
  cover "Robin::Rails::AppLoader*"

  Loader = Robin::Rails::AppLoader

  # Stands in for Robin::CLI's registries.
  FakeCLI = Struct.new(:app_loaders, :environment_variables)

  def tmpdir
    dir = Dir.mktmpdir("robin-rails")
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

  def spy_requires
    log = []
    Loader.define_singleton_method(:require) do |path|
      log << path
      super(path)
    end
    yield log
  ensure
    Loader.singleton_class.send(:remove_method, :require)
  end

  def test_boots_rails_app_directories
    tmpdir do |dir|
      write(dir, "app/config/application.rb", "")
      write(dir, "app/config/environment.rb", "AppLoaderProbe.value = :booted\n")
      Dir.chdir(dir) do
        environment = File.join(Dir.pwd, "app/config/environment.rb")
        spy_requires do |required|
          assert_true Loader.call("app")
          assert_equal ["robin/rails", environment], required
          assert_true Loader.call("app") # already loaded
        end
      end

      assert_equal :booted, AppLoaderProbe.value
    end
  end

  def test_declines_other_directories
    tmpdir do |dir|
      write(dir, "config/environment.rb", "AppLoaderProbe.value = :wrong\n")
      AppLoaderProbe.value = nil
      spy_requires do |required|
        assert_false Loader.call(dir)
        assert_empty required
      end

      assert_nil AppLoaderProbe.value
    end
  end

  def test_robins_cli_boots_rails_apps_first
    assert_equal Loader, Robin::CLI.app_loaders.first
    assert_equal "RAILS_ENV", Robin::CLI.environment_variables.first
  end
end
