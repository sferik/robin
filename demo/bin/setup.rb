# frozen_string_literal: true

# Shared by the bin/ scripts: the demo's own bundle, run from the demo
# directory.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
Dir.chdir(File.expand_path("..", __dir__))
require "bundler/setup"
