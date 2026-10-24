# frozen_string_literal: true

require_relative "helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/robin/install/install_generator"
require "generators/robin/job/job_generator"

module GeneratorTestSupport
  ROUTES = <<~RUBY
    Rails.application.routes.draw do
      root "home#index"
    end
  RUBY

  # Per process (mutant forks its workers after loading the tests).
  def self.included(base)
    base.setup do
      self.destination_root = File.expand_path("../../tmp/generators-#{Process.pid}", __dir__)
      prepare_destination
    end
    base.teardown { FileUtils.rm_rf(destination_root) }
  end

  def write_routes
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), ROUTES)
  end
end

class InstallGeneratorTest < Rails::Generators::TestCase
  include GeneratorTestSupport

  cover "Robin::Generators::InstallGenerator*"
  tests Robin::Generators::InstallGenerator

  def test_creates_config_initializer_and_route
    write_routes
    run_generator

    assert_file "config/robin.yml" do |yaml|
      parsed = YAML.safe_load(ERB.new(yaml).result)

      assert_equal({"concurrency" => 5, "timeout" => 25, "queues" => %w[critical default low],
                    "production" => {"concurrency" => 10}}, parsed)
    end
    assert_file "config/initializers/robin.rb" do |initializer|
      assert_includes initializer, %(require "robin/web")
      assert_includes initializer, "Robin.configure do |config|"
      assert_includes initializer, "Robin.configure_server do |config|"
      assert_includes initializer, "Robin::Web.authorize"
    end
    assert_file "config/routes.rb" do |routes|
      assert_equal <<~RUBY, routes
        Rails.application.routes.draw do
          # Robin's dashboard can see and change every job: protect it, e.g. with
          # Robin::Web.authorize (config/initializers/robin.rb) or by mounting it
          # inside an authenticated route constraint.
          mount Robin::Web => "/robin"
          root "home#index"
        end
      RUBY
    end
  end

  def test_initializer_is_valid_ruby
    run_generator

    assert_file "config/initializers/robin.rb" do |initializer|
      assert RubyVM::InstructionSequence.compile(initializer) if defined?(RubyVM::InstructionSequence)
    end
  end

  def test_is_idempotent
    write_routes
    run_generator
    first = Dir[File.join(destination_root, "**/*")].sort.to_h { |f| [f, File.file?(f) && File.read(f)] }
    output = run_generator

    assert_equal first, Dir[File.join(destination_root, "**/*")].sort.to_h { |f| [f, File.file?(f) && File.read(f)] }
    assert_match(/identical\s+config\/robin.yml/, output)
    assert_equal 1, File.read(File.join(destination_root, "config/routes.rb")).scan("Robin::Web =>").size
  end

  def test_keeps_an_existing_mount
    write_routes
    routes = File.join(destination_root, "config/routes.rb")
    File.write(routes, ROUTES.sub("root", %(mount Robin::Web, at: "/jobs"\n  root)))
    before = File.read(routes)
    run_generator

    assert_equal before, File.read(routes)
  end

  def test_without_routes
    run_generator

    assert_no_file "config/routes.rb"
    assert_file "config/robin.yml"
  end
end

class JobGeneratorTest < Rails::Generators::TestCase
  include GeneratorTestSupport

  cover "Robin::Generators::JobGenerator*"
  tests Robin::Generators::JobGenerator

  def test_creates_a_job_and_a_test
    run_generator %w[report queue:low retry:15 encrypt tags:nightly backtrace:-1 dead:false unique_for:true
      debounce:5 note: label:a:b --test-framework=test_unit]

    assert_file "app/jobs/report_job.rb", <<~RUBY
      # frozen_string_literal: true

      class ReportJob
        include Robin::Job

        robin_options queue: "low", retry: 15, encrypt: true, tags: "nightly", backtrace: -1, dead: false, unique_for: true, debounce: 5, note: "", label: "a:b"

        def perform(*args)
          # Do something later
        end
      end
    RUBY
    assert_file "test/jobs/report_job_test.rb" do |test|
      assert_includes test, "class ReportJobTest < ActiveSupport::TestCase"
      assert_includes test, %(assert_equal ["low"], ReportJob.jobs.map { |job| job["queue"] })
      assert_includes test, "ReportJob.drain"
    end
    assert_no_file "spec/jobs/report_job_spec.rb"
  end

  def test_defaults_and_namespaces
    run_generator %w[admin/cleanup_job --test-framework=minitest]

    assert_file "app/jobs/admin/cleanup_job.rb", /class Admin::CleanupJob\n  include Robin::Job\n\n  robin_options queue: "default"\n/
    assert_file "test/jobs/admin/cleanup_job_test.rb", /class Admin::CleanupJobTest < ActiveSupport::TestCase/
    assert_file "test/jobs/admin/cleanup_job_test.rb", /\["default"\], Admin::CleanupJob\.jobs/
  end

  def test_class_style_names
    run_generator %w[Billing::InvoiceJob]

    assert_file "app/jobs/billing/invoice_job.rb", /class Billing::InvoiceJob\n/
  end

  def test_rspec
    run_generator %w[report queue:mail --test-framework=rspec]

    assert_file "spec/jobs/report_job_spec.rb" do |spec|
      assert_includes spec, %(require "rails_helper")
      assert_includes spec, "RSpec.describe ReportJob do"
      assert_includes spec, %(.to eq(["mail"]))
    end
    assert_no_file "test/jobs/report_job_test.rb"
  end

  def test_without_a_test_framework
    run_generator %w[report]

    assert_file "app/jobs/report_job.rb"
    assert_no_file "test/jobs/report_job_test.rb"
    assert_no_file "spec/jobs/report_job_spec.rb"
  end

  def test_generated_files_are_valid_ruby
    run_generator %w[report queue:a --test-framework=test_unit]
    run_generator %w[other --test-framework=rspec]

    %w[app/jobs/report_job.rb test/jobs/report_job_test.rb app/jobs/other_job.rb spec/jobs/other_job_spec.rb].each do |path|
      assert_file path do |source|
        assert RubyVM::InstructionSequence.compile(source) if defined?(RubyVM::InstructionSequence)
      end
    end
  end
end
