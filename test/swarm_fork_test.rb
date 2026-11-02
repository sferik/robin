# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/swarm"

class SwarmForkTest < RobinTest
  include SwarmTestHelpers

  def test_fork_mode
    skip "fork is unavailable on #{RUBY_ENGINE}" unless Process.respond_to?(:fork)

    run_swarm("fork")
  end
end
