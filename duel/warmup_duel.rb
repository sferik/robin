# frozen_string_literal: true

require_relative "duel_helper"

# The JIT warm-up a server runs before its workers start (on by default
# off CRuby; see Robin::Warmup): Robin's push, fetch and middleware code,
# without Redis. On JRuby it holds up every server's start.

setup { configure_robin }

duel "warmup: one round of the JIT warm-up" do
  Robin::Warmup.run(Robin.config, rounds: 1)
end
