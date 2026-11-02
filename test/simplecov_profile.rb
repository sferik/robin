# frozen_string_literal: true

# What coverage measures, shared by test runs (test_helper.rb) and by
# `rake test`, which merges the results of its parallel processes.
SimpleCov.profiles.define "robin" do
  enable_coverage :branch
  enable_coverage :method
  # Paths relative to the root, with (SimpleCov before 1.3) or without a
  # leading slash.
  skip %r{\A/?test/}
  skip %r{\A/?bench/}
  skip %r{\A/?duel/}
  skip %r{\A/?examples/}
  skip %r{\A/?web/}
end

module RobinCoverage
  THRESHOLDS = {line: 100, branch: 100, method: 100}.freeze

  # Enforced for full runs (CI, `rake test`), not when running one file.
  def self.strict? = ENV.key?("CI") || ENV.key?("COVERAGE_STRICT")

  # Where `rake test` has each process write its results.
  PARTS = "coverage/parts"

  # A formatter for the parts: `rake test` reports on the merged results.
  class Silent
    def format(_result) = nil
  end
end
