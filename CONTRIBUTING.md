# Contributing to Robin

Setting up, running the tests and the checks CI enforces are in the
README's [Development](README.md#development) section. This document is
about the one rule that's easiest to break without noticing, and, at the
end, keeping the type signatures in step with the code.

## Performance: never slower

The way to make a program faster is to never let it get slower.

We have a zero-tolerance policy for performance regressions. If a patch
lands that regresses performance according to our benchmarks, then the
person responsible must either back the patch out of the tree or drop
everything immediately and fix the regression.

Common excuses people give when they regress performance are, "But the
new way is cleaner!" or "The new way is more correct." We don't care. No
performance regressions are allowed, regardless of the reason. There is
no justification for regressing performance. None.

(The policy, and its wording, are [WebKit's](https://webkit.org/performance/).)

### The guards

The policy isn't left to good intentions: CI's Performance workflow, run
by [Duel](https://github.com/sferik/duel-ruby), measures every pull
request against where it left `main`, and every push to `main` against
the commit before it, and fails if the change is slower at any benchmark
in [`duel/`](duel/). It runs on CRuby with YJIT
and without, and on JRuby (where the Java extension is measured).

Each night it also measures `main` against the last release. A change
slower by less than the limit passes on its own; a run of them adds up,
and fails there.

Each benchmark is judged on:

| Metric | What it means | Tolerance |
|---|---|---|
| CPU | the benchmark thread's CPU time (a server's: the process's) | 2%, with 99% confidence |
| Instructions | instructions retired, from the CPU's counters (where the OS shows them) | 1%, with 99% confidence |
| Redis CPU | the time Redis spent running the benchmark's commands | 2%, with 99% confidence |
| Allocations | Ruby objects allocated (CRuby) | none: one more per operation fails |
| Round trips | round trips to Redis | none: one more fails |
| Redis commands | commands Redis ran | none: one more fails |
| Peak memory | the most memory a benchmark needs (those with large arguments) | 10%, and 1 MB |

The counts are exact, so any increase is a regression. (The same code's
allocations can differ by a few objects from run to run, as random ids
vary in length, so for them it's one more per operation: one more per
job pushed, say.) Timings
are never exact, so for them the guard is built to fail only on a real
regression, never on noise:

- **CPU time, not elapsed time.** The benchmark thread's CPU time isn't
  inflated by other processes on the machine. Each sample is the fastest
  of several runs, as interference only ever adds time, and garbage
  collection is kept out of the timed runs (its cost is in the
  allocation count, exactly).
- **Side by side.** The baseline and the candidate each run in three
  worker processes, each on a Redis server of its own, and take turns:
  one sample from each, in alternating order, each pair from a different
  pair of processes, so a busy moment weighs on both alike and no one
  process's luck decides anything. A benchmark is judged on the ratios of
  these pairs.
- **A confidence interval, not an average.** A timed metric is slower
  only when a 99% distribution-free confidence interval for the median
  ratio lies entirely above the limit (1.02), so no one outlier sample
  can decide it. Samples are taken in rounds of 10 until the interval
  settles the question (up to 60 pairs; a benchmark still unsettled then
  is reported as such, and doesn't fail).
- **Measured again before failing.** Everything that looked slower is
  measured again from scratch, three times, each time in fresh processes
  (two runs of the very same code can differ by a few percent, process to
  process, from where things land in memory). It fails only if every
  measurement agrees, and then shows where the extra CPU went (a profile
  of each version).
- **Warm.** Every benchmark runs before it's measured, so the JIT has
  compiled it: for a few runs under YJIT, for five seconds under JRuby,
  whose timings stay noisier (small timing regressions there are left
  unsettled; its counts are as exact).

A timing that stays too close to the limit to settle either way is
reported, and doesn't fail: the guard never fails on a maybe. So a timing
fails once it's more than 2% slower, with 99% confidence, where a
benchmark's timings are steady; where they're noisier, it takes a few
percent more to be sure. The counts are exact whatever the noise.

Run it yourself before you push:

```sh
bundle exec rake compile
bundle exec rake perf                            # against where your branch left origin/main
DUEL_BASE=v0.1.0 bundle exec rake perf           # against any git ref
DUEL_BASE=last-release bundle exec rake perf     # against the newest release tag
DUEL_BASE=../robin-old bundle exec rake perf     # against a tree on disk, already compiled
DUEL_FILTER=push bundle exec rake perf           # only the benchmarks matching a regexp
```

It needs `redis-server` on your `PATH` (each version of Robin gets a
Redis of its own, on a Unix socket; any other Redis is left alone). It
does nothing when `lib/` and `ext/` haven't changed (`DUEL_FORCE=1`
measures anyway). Duel's conventions do most of the setup; what's
Robin's own is [`.duel.rb`](.duel.rb), which uses three plugins, and
the helpers in [`duel/duel_helper.rb`](duel/duel_helper.rb):

- [duel-redis](https://github.com/sferik/duel-ruby/tree/main/plugins/redis): each worker's Redis,
  and the Redis metrics (Redis CPU, commands and round trips).
- [duel-gvl](https://github.com/sferik/duel-ruby/tree/main/plugins/gvl): how long the server
  benchmarks' threads wait for the GVL (`gvl_wait`), on CRuby, where
  `bundle install` builds its extension.
- [duel-retained](https://github.com/sferik/duel-ruby/tree/main/plugins/retained): the objects
  each benchmark leaves alive (`retained_objects`, on CRuby), so a job,
  middleware or cache that keeps something for every call is a
  regression, and a regression names what it kept, by class and where.

[Duel's guide](https://github.com/sferik/duel-ruby/tree/main/docs) has the rest.

### When it fails

Back the change out, or fix it, before anything else. If the slower code
is the price of a fix, find another fix that doesn't pay it, or make
something else on that path faster first.

Don't make the guard pass instead of the code: raising the limit,
loosening a benchmark, marking one `only: :timing` or `only: :count`
when it has no threads of its own or doesn't wait, or deleting one (except along with the feature it
measures) are all regressions too.

### Adding benchmarks

Anything a job or a server does on every job, or a cluster does all the
time, needs a benchmark: a new feature's hot path comes with one. A
benchmark is a few lines in [`duel/`](duel/), in the `*_duel.rb` file of
its kind:

```ruby
# duel/push_duel.rb
require_relative "duel_helper"

setup { configure_robin } # a fresh Robin.config on the worker's own Redis

duel "push: one job" do
  setup { @job = define_job(:PushJob) } # once, not timed
  @job.perform_async(1, "two")          # timed, as many times as a sample needs
end
```

Work done for many jobs at once takes the number of iterations, and
`untimed` pauses measuring for what it prepares each time:

```ruby
duel "run: fetch, run and acknowledge a job" do |n|
  setup { @job = define_job(:RunJob) }
  untimed { @job.perform_bulk(Array.new(n) { |i| [i] }) } # not timed
  run_jobs(n)                                             # timed
end
```

A benchmark is judged on its timings and its counts. Options change
that: `only: :count` for work that's mostly waiting (a few iterations,
judged on its counts alone), `only: :timing` for work done by threads
of the benchmark's own (a whole server: its CPU is the process's, and
its counts, which those threads make vary, aren't judged), and
`peak_memory: true` to judge its peak memory too (for work with large
data). A benchmark the baseline can't run (it uses something new) is
skipped until the baseline has it.

## Type signatures

Robin's [RBS](https://github.com/ruby/rbs) signatures are in `sig/`, laid out
like `lib/`, and ship in the gem, so an application's
[Steep](https://github.com/soutaro/steep) check sees Robin's API. CI
checks them on CRuby 3.4 and 4.0 (Steep doesn't run on JRuby): they must
be valid RBS, and `lib/` must pass Steep's strict check against them
(the Steepfile names the few diagnostics it relaxes, and why) with no
errors or warnings.

```sh
bundle exec rake steep                       # rbs validate, then steep check
bundle exec steep check lib/robin/client.rb  # one file
```

A change to a method's arguments or return value, or a new instance
variable, needs the same change in the signature. Keep `untyped` for
what really is arbitrary (job arguments, JSON, Redis replies). Where
Steep can't follow the code, first try code it can follow at no cost
(an instance variable read into a local before a nil check, a plain
call rather than a tuple splatted into one, a Struct reopened rather
than given a Struct.new block); else a `#:` assertion or `# @type`
annotation (comments both) tells it. `# steep:ignore` is the last
resort, naming the diagnostic, with the reason on the line above.

`sig/` can't name the types of gems Robin doesn't depend on (an app's
check may not have their signatures): it uses an interface of what Robin
calls instead, and `rake steep` validates it on its own. `steep/` holds
what Robin uses of those gems (Rack, Rails, Puma...), and the signatures
of Robin's classes built on Rails' and Puma's: for the check only, not
in the gem.
