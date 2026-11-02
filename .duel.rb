# frozen_string_literal: true

# Robin's performance regression guards (see CONTRIBUTING.md), run by
# Duel (`rake perf`): each worker with a Redis of its own (duel-redis),
# the server benchmarks, whose threads take turns, judged on their wait
# for the GVL too (duel-gvl), and every benchmark on what it leaves alive
# (duel-retained, used last: the other plugins' metrics are read outside
# its measurement, so what they keep isn't counted). Duel's conventions
# do the rest: the benchmarks in duel/*_duel.rb, robin required from each
# version's lib/, and `rake compile` for each version.
Duel.configure do |c|
  c.use :redis
  c.use :gvl
  c.use :retained

  # A push to main is compared with the last commit Duel passed, which
  # the duel/passed/main branch marks, not the commit before it, so
  # slowdowns too small for any one push to fail add up until they fail
  # one. (No regression is accepted, so there is no c.accept_label.)
  c.push_base = :last_passed
end
