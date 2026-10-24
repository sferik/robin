# frozen_string_literal: true

require "open3"

# Splits the subjects mutant runs across CI runners (see
# .github/workflows/mutant.yml): every one, or those a diff touches.
module MutantShard
  extend self

  # The subjects touched since +ref+ (a revision), or every one (no ref).
  def subjects(ref = nil)
    ref = nil if ref.to_s.empty?
    command = %w[bundle exec mutant environment subject list]
    command += ["--since", ref] if ref
    output, status = Open3.capture2(*command)
    raise "mutant couldn't list its subjects#{" touched since #{ref}" if ref}" unless status.success?

    # A subject is a constant's name (Robin::Fetcher#fetch, say), without
    # a space, which tells it apart from the "Subjects in environment: N"
    # line mutant ends the listing with.
    output.lines.map(&:chomp).grep(/\A[A-Z]\S*\z/)
  end

  # Dealt out in turn rather than in contiguous slices: mutant lists
  # subjects sorted, so a namespace's slow subjects (those whose tests
  # wait on Redis, or start processes) would land in one shard, the one
  # that times out. Every TOTAL-th subject spreads them across the
  # runners instead.
  def shard(subjects, index, total) = subjects.select.with_index { |_subject, position| position % total == index }
end
