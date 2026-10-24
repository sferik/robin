# frozen_string_literal: true

require "rails/generators/named_base"

module Robin
  module Generators
    # rails generate robin:job NAME [option:value ...]
    #
    #   rails generate robin:job report queue:low retry:5
    #
    # Creates app/jobs/report_job.rb, a Robin::Job with those robin_options
    # (queue defaults to "default"), and a test: spec/jobs/report_job_spec.rb
    # when the app generates RSpec tests, else test/jobs/report_job_test.rb.
    class JobGenerator < ::Rails::Generators::NamedBase
      # The job to generate. (Kept out of the generator, where every public
      # method is a step of the generator.)
      class Blueprint
        attr_reader :path, :class_name, :robin_options

        # A trailing "_job" is implied, so "report" and "report_job" match.
        # "queue:low retry:5 encrypt" means {"queue" => "low", "retry" =>
        # "5", "encrypt" => nil}.
        def initialize(name, pairs)
          base = name.underscore.delete_suffix("_job") # "Admin::Report" is "admin/report"
          @path = "#{base}_job"
          @class_name = "#{base.camelize}Job"
          options = pairs.to_h do |pair|
            key, colon, value = pair.partition(":")
            [key, (value unless colon.empty?)]
          end
          @robin_options = {"queue" => "default"}.merge(options)
        end

        def queue = robin_options.fetch("queue")

        # As Ruby source: `queue: "low", retry: 5, encrypt: true`.
        def robin_options_source
          robin_options.map { |key, value| "#{key}: #{literal(value)}" }.join(", ")
        end

        private

        def literal(value)
          case value
          when nil then "true"
          when /\A-?\d+\z/, "true", "false" then value
          else value.dump
          end
        end
      end

      source_root File.expand_path("templates", __dir__)
      desc "Creates a Robin job and its test."

      argument :options_list, type: :array, default: [], banner: "option:value option:value"
      class_option :test_framework, type: :string, desc: "Test framework for the job's test (rspec or test_unit)"

      def initialize(*)
        super
        @job = Blueprint.new(name, options_list)
      end

      def create_job
        template "job.rb", "app/jobs/#{@job.path}.rb"
      end

      # Follows the app's generator settings (config.generators.test_framework);
      # none when it's unset.
      def create_test
        case options[:test_framework].to_s
        when "" then nil
        when "rspec" then template "job_spec.rb", "spec/jobs/#{@job.path}_spec.rb"
        else template "job_test.rb", "test/jobs/#{@job.path}_test.rb"
        end
      end
    end
  end
end
