# frozen_string_literal: true

# Loaded by mutant (see mutant.yml) so every subject is defined before it
# starts matching.
require "robin"
require "robin/web"
require "robin/testing"
require "robin/opentelemetry"
Robin::Testing.disable!
# The Rails integration (test/rails/), loaded before eager_load! so its
# Robin::ActiveJob autoload is loaded too.
require "rails"
require "robin/rails"
require "rails/generators"
require "generators/robin/install/install_generator"
require "generators/robin/job/job_generator"
require "active_job/queue_adapters/robin_adapter"
Robin.eager_load!
require "puma/plugin/robin"
