# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The Rails integration's tests. gemfiles/rails_*/Gemfile pin a release
# line first.
%w[activejob railties].each do |name|
  gem name, ">= 7.2" unless dependencies.any? { |dependency| dependency.name == name }
end

gem "rake"
gem "rake-compiler"
gem "minitest"
gem "minitest-strict"
gem "minitest-memory", ">= 1.1.1"
gem "rack"
gem "rack-test"
gem "rack-session"
gem "puma"
gem "tzinfo"
gem "standard", ">= 1.57"
gem "standard-performance"
gem "rubocop"
gem "rubocop-performance"
gem "rubocop-minitest"
gem "simplecov", ">= 1.3"
gem "opentelemetry-sdk"

# Duel (`rake perf`) and its plugins.
gem "duel", "~> 0.1"
gem "duel-redis", "~> 0.1"
gem "duel-gvl", "~> 0.1"
gem "duel-retained", "~> 0.1"

platforms :mri do
  gem "mutant-minitest"
  gem "vernier"
  gem "stackprof" # Duel's profile of each version with a regression
  # The type check (`rake steep`) of sig/ against lib/, with RBS (Steep's
  # dependency). Steep doesn't run on JRuby.
  gem "steep"
end
