# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-24

The first release. Everything is open source under the LGPL-3.0.
Robin needs Ruby 3.4 or later (or JRuby 10).

### Added

- Core: multithreaded processing, capsules, weighted/strict queue priority,
  scheduled jobs, exponential-backoff retries, dead set, middleware,
  strict JSON arguments, bulk push, embedded mode, deferrable push.
- Reliability: reliable fetch with per-process in-flight jobs, crash
  recovery, poison-pill detection, reliable push buffering.
- Batches with nested workflows and success/complete/death callbacks.
- Rate limiters: concurrent, bucket, window, leaky and points.
- Periodic (cron) jobs with time zones, unique jobs, debounced jobs,
  expiring jobs, encrypted arguments with key rotation, iterable jobs.
- Leader election, swarm mode with rolling restarts and memory limits.
- Metrics: per-class timings and histograms, historical rollups, StatsD
  and Prometheus output.
- Job progress reporting and cooperative cancellation.
- Web dashboard (TypeScript) with live updates, multi-cluster support
  and authorization hooks.
- Optional C extension that encodes commands, parses Redis replies, and
  sends commands and reads their replies in one release of the GVL,
  checking for dropped connections without a read.
- RBS signatures for Robin's API (`sig/`), shipped in the gem, and
  checked against the code with Steep in strict mode (`rake steep`).
- `config.fetch_timeout`: how long an idle worker waits for a job (2s).
- `Job#capsule` and `Robin::Capsule.current`: the capsule whose worker is
  running the code. A worker thread emits a `worker.started` event as it
  starts. After a resize, the capsule's `concurrency` is the new count.
- `Robin.cancel!` takes several jids, cancelling them in one round trip;
  cancelling a batch with children takes one round trip, not one each.
- A server logs the Redis it uses at startup (its version, address and
  key prefixes; never a password), so connecting to the wrong one shows.
- Iterable jobs whose enumerator has no size (the Active Record and CSV
  enumerators) report how many items they've done, shown on the Busy page
  under a moving bar; `progress!(nil, message)` reports progress without
  a percentage.
- `config.internal_key_prefix` puts Robin's own keys under a prefix of
  their own (the job keys keep `key_prefix`).
- `config.retry_backoff`, `config.recovery_handlers`,
  `config.leader_candidate`, the `:fork` lifecycle event (in swarm
  children), `batch.jobs(atomic: true)`, `around_iteration` for iterable
  jobs, `Robin::Client.new(chain:)`, and CLI plugin hooks for config file
  names and settings (`Robin::CLI.config_paths`, `config_file_hooks`).
  ActiveJob jobs' retry hooks come from the class they wrap.
- Batched fetch: one round trip fetches a job for every worker of a
  capsule asking at the same time (up to `config.fetch_batch`, 10), and
  finished jobs are acknowledged with the next round trip. Extra jobs wait
  in flight; ones no worker takes within a second, or from a queue that's
  been paused, go back to their queue, as do those of a stopping process.
- Middleware can define `self.applies?(*args)` to be skipped (and never
  built) for jobs it doesn't concern; the built-in server middleware do.
- A java-platform gem for JRuby, with a Java extension in place of the C
  one: the same reply parser and socket reader (each socket waits on a
  selector of its own), a command encoder, and lock-free bookkeeping for
  the connection pool. Built with `ROBIN_PLATFORM=java gem build` after
  `rake java:compile`; held to 100% JaCoCo coverage and 100% PIT mutation
  coverage.
- `retry_for:` keeps retrying a job until a set time after its first
  failure; `retry_queue:` runs a job's retries on another queue.
- Deploy markers (`Robin::Deploy.mark!`, `robin deploy LABEL`), drawn as
  lines on the dashboard's metrics charts.
- Events: `config.event_handlers` are called with what Robin otherwise
  only logs (expired, skipped, discarded and rate-limited jobs, recovered
  and orphaned jobs, dead workers and swarm children, slow Redis, a lapsed
  heartbeat, memory limits, slow iterations, reliable push buffering).
  See `Robin::Events`.
- Reliable push reports jobs it drops from a full buffer, and jobs still
  buffered when the process exits (after one last try to push them), to
  the error handlers, as `Robin::ReliablePush::Dropped` and `Lost`.
- GVL contention monitoring (C extension): each heartbeat
  records how much of the time the process's threads could wait for the
  GVL they did, shown on the dashboard and sent to StatsD as
  `gvl.contention`; contention kept high logs a warning and emits a
  `gvl.contended` event. `config.gvl_monitoring = false` turns it off.
- The dashboard in 25 languages, right-to-left ones included, chosen from
  the browser's languages or under Settings; each loads on demand.
- Dashboard extensions can bring their own JavaScript module, stylesheet
  and other assets, JSON data endpoints, and translations (YAML files
  used by `request.t`, the script's `t` and the navigation).
- StatsD counters for batches (created, complete, success, death,
  cancelled, plus a duration timing) and for recovered, orphaned and
  poison-pill jobs.
- Rails: `config.robin.current_attributes = ["Current"]` carries
  `ActiveSupport::CurrentAttributes` from where a job is pushed into it.
- Rate limiters take `reschedule:` and `backoff:`, `config.rate_limit_backoff`
  sets a backoff for all of them, and `Robin::Limiter.unlimited` is a
  limiter that never limits.
- `perform_bulk(..., spread_interval: 3600)` (and `"spread_interval"` in
  `Client#push_bulk`) spreads the jobs evenly over that many seconds.
- Iterable jobs: an `on_cancel` hook, a `current_object` reader, and
  `max_iteration_runtime` (config or job option), after which a run
  checkpoints and requeues itself.
- `Robin::Web.job_info(label) { |job| ... }` adds rows (text or links) to
  job pages; `Robin::Web.assets_path` serves the dashboard's assets from a
  CDN.
- `robin top`: a live terminal view of totals, queues, processes and
  running jobs.
- The Busy page can show only processes or only running jobs
  (`?only=processes`, `?only=jobs`); INFO (Ctrl-T on macOS and BSD) dumps
  threads like TTIN; a suppressed duplicate unique job's log line names
  the jid holding the lock.
- Batch tags (`batch.tags = [...]`), with `Robin::Batch.list(tag:)` and a
  tag filter on the dashboard's Batches page.
- `Robin::Statsd.new(distributions: true)` sends Datadog distributions
  (`jobs.perform_dist`, `batch.duration_dist`); under DogStatsD, batch
  metrics carry the batch's tags.
- `Robin::Client.rewriters`: callables that may rewrite a job hash before
  it's pushed. The Rails integration uses one so periodic jobs (and
  `Client.push`) can name ActiveJob classes.
- `Robin::Periodic.verify!` checks a periodic schedule in an app's test
  suite.
- Bucket and window limiters take `within_limit(used: n)`;
  `Robin::Limiter.via(pool)` keeps limiters in another Redis.
- Limiters take `policy: :skip`: when over the limit, `within_limit`
  returns nil without running the block instead of raising.
- `Robin::Queue#delete_by_class` deletes a class's jobs inside Redis; the
  dashboard offers it when the selected jobs share a class.
- `Robin::Web::BatchStatus`: a Rack app your own pages can poll for a
  batch's progress (counts and states only).
- `robin swarm -n 0.5` (or `ROBIN_SWARM_COUNT`): a decimal means that many
  processes per CPU core.
- Benchmarks: `rake bench` (parser and throughput) and `rake bench:compare`
  (Robin vs Sidekiq on the same workload, with optional added latency).
- Redis Sentinel (`sentinels:` with the master named in the URL), with a
  role check on connect; sharding with `MyJob.set(pool:)` and
  `Robin::Client.via(pool) { ... }`.
- Health checks: an HTTP endpoint per server (`config.health_port`),
  `robin health` for exec probes, and `/health` on the dashboard.
- OpenTelemetry tracing (`require "robin/opentelemetry"`) with producer
  and consumer spans and trace context carried in the job.
- Profiling single job runs with Vernier (`MyJob.set(profile: true)`),
  stored in Redis for the Firefox Profiler.
- Operations: process titles, a warning when Redis round trips are slow,
  systemd notify and watchdog support, `REDIS_PROVIDER`, connections
  named `robin`, passwords never shown by `inspect`, Capistrano- and
  Heroku-aware tags and hostnames, previous signal traps still run,
  capsules frozen after boot, optional idle connection reaping
  (`idle_timeout`).
- Jobs: per-job `log_level` and `logging: false`.
- Dashboard extensions (`Robin::Web::Extension`, `Robin::Web.register`):
  pages of your own, built from blocks, with actions.
- A Profiles page in the dashboard, to download job profiles for the
  Firefox Profiler.
- Works with any Ruby or Rack app. Extension points: `config.push_deferrer`
  (defer delivery, e.g. until a transaction commits), `Robin::Job.inclusion_checks`,
  and `robin` CLI plugins (`robin/plugins/*.rb` in any gem) that add app
  loaders and environment variables.
- Resizing a running process: a capsule's worker count changes without a
  restart, from the dashboard's Busy page, `POST
  api/processes/:identity/resize`, or `Robin::ProcessRecord#resize!`.
  New workers start at once, extra ones finish their job first, and a
  Redis pool Robin sized grows to fit (a `workers.resized` event).
- A Puma plugin (`plugin :robin`, optionally `robin_config { |config| ... }`)
  runs an embedded server in every worker once the app has loaded, and
  stops it gracefully on shutdown and on hot, phased and fork-worker
  restarts. Robin is never loaded in Puma's master, so phased restarts
  with `prune_bundler` pick up changed gem versions. `Embedded#stop`
  waits for a stop already in progress (including one asked for from the
  dashboard) instead of stopping twice.
- The Rails integration, part of the robin gem. It turns itself on in a
  Rails app (Bundler loads robin after Rails); elsewhere it loads
  nothing of Rails. `require "robin/rails"` turns it on where robin was
  required before Rails:
  - Railtie: jobs run in the Rails executor and reloader, `Rails.logger`
    outside the server, `Robin.config.environment` from `Rails.env`.
  - ActiveJob adapter (`:robin`) with `robin_options`, pipelined
    `perform_all_later` and continuation support.
  - `bundle exec robin` boots the Rails app and reads `RAILS_ENV`.
  - Errors reported to `Rails.error` (`config.robin.report_errors`).
  - Transaction-aware pushes (`config.robin.transactional_push`).
  - Generators: `robin:install` and `robin:job`.
  - Failed jobs' backtraces go through `Rails.backtrace_cleaner`.
  - What jobs log through `Rails.logger` is tagged with their class and jid.
  - Mail deliveries show as the mail they send (`UserMailer#welcome`).
  - Robin's events are published through `ActiveSupport::Notifications` as
    `"<event>.robin"` (`config.robin.notifications`).

### Changed

- Performance: at most one Redis round trip per job (a finished job is
  acknowledged by the round trip that fetches the next), replies awaited
  rather than polled for, middleware chains that build no closures per
  job, bulk pushes normalized once per batch, and job ids drawn from
  batched random bytes.
- Fewer Redis round trips outside the job path:
  - A heartbeat is one round trip (its metrics, leader lease and in-flight
    sweep go in its transaction; it reports the previous heartbeat's round
    trip time), and buffered jobs of every capsule go back in one more.
  - Recovering dead processes takes three round trips however many there
    are, not one per process and job; pruning processes and sampling queue
    sizes take one each (two), and periodic jobs take three per tick
    however many are due.
  - A debounced push, a batch callback, a deploy mark, and a limiter that
    gives up (it counts itself over its limit) take one round trip fewer;
    so does loading a Lua script Redis lost. A debounced job's claim is
    made with its push, so a push a later middleware stops no longer
    unschedules the job pushed before it.
  - `retry_all` and `kill_all`, and the dashboard's actions on selected or
    all jobs, take a few round trips per page of 100, not two per job;
    `Batch#cancel!` takes two whatever the depth of children.
  - The dashboard's stats, processes, busy jobs and limiters are read in
    one round trip each, and every page in a fixed number.
  - `Robin::Client.together { ... }` sends the jobs its block pushes in one
    round trip. The Rails integration uses it for `perform_all_later` (one round trip
    for all its classes and queues) and for transactional pushes (the jobs
    of one transaction go together when it commits).
  - Tests pin the round trips of each of these with `assert_roundtrips`.
- A finished job is acknowledged with the next round trip, or within 2
  milliseconds by a thread of its own if no round trip comes (a worker
  that takes a job fetched for it makes none, and long jobs can keep
  every worker busy), so a crash re-runs only jobs that finished just
  before it.
- An idle worker of a capsule with one queue blocks on it again without
  a non-blocking fetch first, halving the commands idle processes send.
- JRuby: hash arguments with keys that aren't symbols take braces, as
  JRuby 10.1 can't compile a method with a call passing one without
  (enforced by the `Robin/BracedHashArgument` RuboCop cop), and
  `push_bulk` does its per-job work in methods of their own, compiled
  after 50 jobs. Warm pushes are about 12% faster.
- `robin stats`, `robin top` and `robin deploy` boot the app as a client,
  so its `configure_client` blocks (Redis settings, say) apply to them.
- Redis formats shared with other Ruby job tools: schedule, retry and
  dead set scores (and a job's "at") in epoch seconds; scheduled and
  failed jobs stored without "at" (enqueued_at is set when they reach
  their queue); a 0-based "retry_count" in place of "failures"
  (Job#retry_count is now Job#failures); compressed backtraces as plain
  base64; process records at the process's identity, with signals named
  TSTP, TERM and TTIN; daily totals kept five years. Older float-second
  timestamps are still read.
- In-flight jobs are acknowledged by key, not by payload: each fetched job
  goes into a key of its own (`inflight:<identity>:<n>`, registered in the
  process's `inflight:<identity>` set and reused once acknowledged), so a
  job's payload is never sent back to Redis, and batches of large jobs
  are taken with plain commands instead of copying them through Lua. With
  100 KB arguments a process runs about 4x as many jobs per second, with a
  fifth of the Redis CPU per job; with 10 KB, about twice as many. No-op
  jobs cost a few percent more (a key per job is created and deleted).
  Recovery still reads the single in-flight list of earlier development
  versions.
- Job log lines the logger would drop cost nothing: no timing is
  formatted and the logger isn't called.
- The C extension encodes commands and, in one release of the GVL,
  checks the connection, writes the commands and reads the start of the
  replies (`NativeIO.roundtrip`).
- No shared locks per job: workers keep their running job to themselves,
  metrics are recorded per thread and merged on flush, so threads that run
  in parallel (JRuby) never wait on each other.
- Capsules with a single queue fetch with pipelined plain commands instead
  of a Lua script, which costs Redis about a third less per job.
- Pipelines run Lua scripts by their SHA, as single calls do: a
  connection remembers which scripts its server has, and loads one it
  hasn't seen in the same round trip, so a script's source is sent once
  per connection, not with every pipeline. (Transactions still send the
  source, so a server that lost its scripts can't apply half of one.)
- Error handlers run in the failed job's logging context, and the
  default handler logs an error, its context and backtrace as one entry.
- `push_bulk` inside a batch's `jobs` block adds its jobs to the batch in
  one round trip, not one per job; if it raises, none are added.
- Cancelling a batch (`Robin::Batch#cancel!`, or from the dashboard)
  cancels its child batches and their jobs too; the batch completes
  without succeeding.
- `Client.timestamp_ms(nil)` now raises instead of meaning "now".
- `logger` is a declared dependency (a bundled gem since Ruby 3.5).
- Tested against Redis 7.4, 8.2 and 8.10, Valkey 9.1 and Dragonfly 2.0.
- `rake test` runs test files in parallel processes (`rake test:serial` in
  one).
- Robin may never get slower, after [WebKit's performance
  policy](https://webkit.org/performance/) ([CONTRIBUTING.md](CONTRIBUTING.md)):
  `rake perf` runs Robin's benchmarks (`duel/`) with
  [Duel](https://github.com/sferik/duel-ruby), on every pull request and
  push in CI (CRuby with YJIT and without, and JRuby), and fails if a
  change is slower than its baseline at any of them, and each night if
  `main` is slower than the last release. CPU time, instructions and
  Redis CPU are judged by a 99% confidence interval for paired ratios,
  over three processes of each version and confirmed in fresh ones;
  allocations, round trips and Redis commands are counted, and peak
  memory measured; a regression comes with a profile of each version.
  The benchmarks cover pushing, running jobs (one worker's loop and a
  whole server), scheduling (and the leader's wake-up), heartbeats,
  crash recovery, periodic jobs, rate limiters, the dashboard's
  requests, the protocol and the JIT warm-up.
- Performance: idle workers block 2s per fetch, and check whether their
  queue was paused in the same round trip, as of the moment a job
  arrives (Redis runs the check once the blocking fetch returns); built-in client
  middleware (unique, debounce, batch, encryption) is skipped for jobs
  that don't use it (bulk pushes about 10% faster, twice as fast before
  JRuby has warmed up); `robin swarm` loads all of Robin (`Robin.eager_load!`) and
  runs `Process.warmup` before forking, so children share it
  copy-on-write (about 1 MB less private memory each); built-in
  middleware is built once instead of per job (`Middleware::Stateless`);
  stored backtraces are compressed, with `config.backtrace_cleaner`;
  `retry_all`, `kill_all` and dashboard bulk actions page through sets;
  timings and histograms leave out failed runs.
- Idle time is spent for busy time: the cluster's leader wakes its
  scheduler when the next scheduled job or retry is due, rather than at
  its next poll (jobs scheduled ahead start within milliseconds, not
  seconds, late); a standalone server runs `Process.warmup` before it
  starts, and, if asked, a full GC once it has gone idle
  (`config.idle_gc`: off by default; `true`, or the fewest jobs since the
  last collection, turns it on); and off CRuby a server warms up the JIT before its workers start
  (`config.jit_warmup`; on JRuby a new server's first pushes are about
  3x as fast, and it reaches full speed sooner).
- Jobs: `Robin::Job::Timeout` is no longer a `StandardError`.
- Test modes set with a block are thread-local.
- Finding jobs by jid searches queues inside Redis; `Robin::JobLocator`
  and an optional jid index (`config.jid_index`) point it at the right
  queue.
- Iterable jobs make one Redis round trip every five seconds: the
  checkpoint, progress and cancellation check share a transaction, so a
  cancelled job stops at its next checkpoint (within about five seconds,
  was one). An interruption saves the checkpoint and requeues the job in
  one transaction, and finishing deletes the state and reports progress
  in one pipeline. A limiter's definition is written once per process and
  Redis (and again when it changes) rather than once per limiter object,
  so limiters built inside `perform` cost no extra round trip.
- Fewer Redis round trips around jobs: a blocking fetch checks for a
  pause in the same round trip; `unique_until: :start` jobs release
  their lock once; expired jobs outside a batch and skipped cancelled
  jobs cost none. A failing batch job's failure goes in its retry's
  transaction, and a job that dies or is discarded is moved, acknowledged,
  unlocked and recorded with its batch in one transaction (was up to
  five round trips). A push inside a batch's `jobs` block registers and
  sends the job in one transaction, a new batch (child or not) is
  created in one, and `push_bulk` takes its jobs' unique locks and makes
  their debounce claims in one round trip each instead of one per job.
  `unique_for` of zero or less takes no lock.

### Fixed

- A forked child (a Puma worker, a swarm child) lets go of the TLS
  connections it inherited without a TLS goodbye, which made Redis hang
  up on the parent's connection; its parent's next command failed.
- An iterable job with nothing to iterate finishes at 100% instead of
  failing on its progress.
- Expiring jobs count `expires_in` from when the job is due, not when it
  was pushed, so a scheduled job no longer expires before it runs.
- A job that dies or is discarded now gives up its unique lock in the
  retrier, whatever ended it.
- Hardening: graceful-shutdown requeues don't count toward poison-pill
  detection; failure recording never strands a job (unreadable or binary
  error messages, bad `robin_retry_in` values); fetch errors back off
  instead of respawning threads; connections drop and reconnect after
  READONLY/LOADING/failover replies and never resend a partially written
  pipeline; the heartbeat never writes decrypted arguments; retries and
  dead jobs are stored as pushed (not as the job mutated them); iterating
  while deleting visits every job; batch jobs are never deferred; one
  shared grace period for interrupted jobs, which are only interrupted
  inside `perform`; errors caused by the shutdown don't count as failures;
  iterable jobs checkpoint when an iteration raises; jitter on custom retry
  delays; death handlers run for discarded jobs (`discarded_at`); failing
  `:startup` hooks abort the boot; boot checks for Redis 6.2+, eviction
  policy, pool size, concurrency, timeout and duplicate queues; orphaned
  in-flight jobs on live processes are swept back to their queues; the
  heartbeat and leader duties run on their own threads and Redis
  connections, and a lapsed heartbeat is reported.

### Security

- Invalid Redis URLs no longer show their password in the error.
- The dashboard rejects cross-site writes using `Sec-Fetch-Site` too.
