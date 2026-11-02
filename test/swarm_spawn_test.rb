# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/swarm"

class SwarmSpawnTest < RobinTest
  include SwarmTestHelpers

  def test_spawn_mode
    run_swarm("spawn")
  end
end
