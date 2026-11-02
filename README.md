<p align="center">
  <img src="assets/robin-logo.svg" alt="Robin" width="420">
</p>

<p align="center"><strong>Fast, reliable background jobs for Ruby. Every feature open source.</strong></p>

<p align="center">
  <a href="https://github.com/sferik/duel-ruby"><img src="https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg" alt="Duel"></a>
  <a href="https://github.com/sferik/robin/actions/workflows/test.yml"><img src="https://github.com/sferik/robin/actions/workflows/test.yml/badge.svg" alt="Test"></a>
  <a href="https://github.com/sferik/robin/actions/workflows/lint.yml"><img src="https://github.com/sferik/robin/actions/workflows/lint.yml/badge.svg" alt="Lint"></a>
  <a href="https://github.com/sferik/robin/actions/workflows/mutant.yml"><img src="https://github.com/sferik/robin/actions/workflows/mutant.yml/badge.svg" alt="Mutant"></a>
  <a href="https://rubygems.org/gems/robin"><img src="https://badge.fury.io/rb/robin.svg" alt="Gem Version"></a>
</p>

Robin is a Redis-backed job system for Ruby. Batches, reliable fetch, rate limiting,
cron, unique jobs, encryption, multi-process swarms with rolling restarts,
historical metrics and a modern dashboard with multi-cluster support and
authorization hooks are all included under the LGPL-3.0. There is no paid tier.

```ruby
class SendReceipt
  include Robin::Job
  robin_options queue: "mailers", retry: 5

  def perform(order_id)
    OrderMailer.receipt(Order.find(order_id)).deliver_now
  end
end

SendReceipt.perform_async(order.id)
SendReceipt.perform_in(300, order.id)                   # in 5 minutes
SendReceipt.set(queue: "critical").perform_async(order.id)
```

```sh
bundle exec robin -r ./app.rb -c 10 -q critical,3 -q default
```

## Why Robin

**Faster.** Robin processes jobs 5x as fast as Sidekiq 8.1 OSS on the
same machine, 8.8x with Redis 1 ms away, and moves scheduled jobs onto
their queues 61x as fast, with an eighth of the Redis CPU per job
([benchmarks](#performance)).

**Built not to lose jobs, or run them twice.**

- **A crash loses nothing.** A fetched job stays in Redis until it has
  finished or its retry has been recorded. Kill a server with `kill -9` in
  the middle of 1,000 jobs: Robin loses none, Sidekiq OSS loses every job
  that was running ([crash benchmark](bench/RESULTS.md#surviving-a-crash)).
  The cluster puts a dead process's jobs back on their queues by itself,
  and a job that keeps killing its process goes to the dead set instead of
  taking down the next one.
- **Each step happens once.** A due scheduled job or retry is moved by a
  script that only queues it if it removed it from its set, so any number
  of servers polling queue it once. Each cron tick is claimed with an
  atomic `SET NX`, so it runs once across the cluster. A job's retry (or
  death) is recorded in the same transaction that removes it from flight,
  so a failure is never both retried and lost. A command is only resent
  after a dropped connection if none of it reached Redis, so a failover
  doesn't push a job twice.
- **Duplicates only where they can't be avoided.** Delivery is at least
  once, as with any job system that survives crashes: a job runs again
  only if its process dies while it runs (or within 2 ms of it finishing)
  or a shutdown interrupts it. [Unique jobs](#unique-debounced-expiring-and-encrypted-jobs)
  and idempotent jobs cover the rest.
- **Tested to the hilt.** About 1,900 tests run on CRuby 3.4, 4.0 and
  JRuby. CI enforces 100% line, branch and method coverage of the Ruby, C,
  Java and TypeScript code, and 100% mutation coverage of the Ruby, Java
  and TypeScript code: every deliberate bug a mutation tester plants makes
  some test fail ([details](#development)).

## Contents

- [Why Robin](#why-robin)
- [Features](#features)
- [Installation](#installation)
- [Jobs](#jobs)
- [Running servers](#running-servers)
- [Reliability](#reliability)
- [Batches and workflows](#batches-and-workflows)
- [Rate limiting](#rate-limiting)
- [Periodic (cron) jobs](#periodic-cron-jobs)
- [Unique, debounced, expiring and encrypted jobs](#unique-debounced-expiring-and-encrypted-jobs)
- [Long-running (iterable) jobs](#long-running-iterable-jobs)
- [Progress and cancellation](#progress-and-cancellation)
- [Middleware](#middleware)
- [Errors, retries and the dead set](#errors-retries-and-the-dead-set)
- [Metrics](#metrics)
- [Tracing and profiling](#tracing-and-profiling)
- [Web dashboard](#web-dashboard)
- [Rails and ActiveJob](#rails-and-activejob)
- [Testing](#testing)
- [The data API](#the-data-api)
- [Performance](#performance)
- [Development](#development)
- [License](#license)

## Features

| Area | What you get |
|---|---|
| Core | Multithreaded workers, capsules, strict or weighted queue priority, scheduled jobs, retries with exponential backoff (limited by count or by time, optionally on another queue), dead set, client and server middleware, strict JSON arguments, bulk push (optionally spread over time), embedded mode, deferrable pushes (transaction-aware in Rails), a Ruby API for everything in Redis |
| Reliability | Reliable fetch (in-flight jobs survive crashes), automatic recovery from dead processes, poison-pill detection, reliable push (buffers jobs while Redis is unreachable), queue pausing |
| Workflows | Batches with `success`, `complete` and `death` callbacks, nested batches, tags for finding batches, cancelling a batch and its children, a status endpoint your own pages can poll |
| Throughput control | Concurrent, bucket, sliding-window, leaky-bucket and points rate limiters, each with its own reschedule count and backoff, calls that count as several uses, a policy that skips work instead of waiting, limiters on a Redis of their own, plus an unlimited stand-in; expiring jobs |
| Scheduling | Cron jobs (Robin jobs or ActiveJobs) with time zones, run exactly once by an elected leader, and a checker for your test suite |
| Deduplication | Unique jobs, and debounced jobs (Robin-only) |
| Security | AES-256-GCM argument encryption with key rotation, web UI authorization and read-only mode |
| Operations | Swarm mode (multi-process, copy-on-write preload, sized per CPU core), rolling restarts, per-process memory limits, leader election, remote quiet/stop/resize, `robin top` (a live view in the terminal) |
| Observability | Per-class timings and latency histograms, hourly history kept for 90 days by default, queue size and latency history, deploy markers on the charts, StatsD/DogStatsD (jobs, queues, batches, recovered jobs; Datadog distributions), Prometheus endpoint |
| Long jobs | Iterable jobs that checkpoint and resume across deploys (and yield their worker after a maximum runtime), live progress reporting, cooperative cancellation (Robin-only) |
| Dashboard | TypeScript single-page app in 25 languages (including right-to-left ones) with live updates, light and dark themes, search, editing a dead job's args before retrying it, multi-cluster support, rows of your own on job pages, pages of your own (built from blocks, or with your own script), and assets from a CDN |

## Installation

```ruby
# Gemfile
gem "robin"
```

Robin needs Ruby 3.4+ (or JRuby 10) and Redis 6.2+, Valkey or Dragonfly.
CI runs every test on Ruby 3.4 and 4.0 (and Ruby's development version),
JRuby 10.1, Redis 6.2, 7.2, 7.4, 8.2 and 8.10, Valkey 9.1 and
Dragonfly 2.0. CI runs them on TruffleRuby 40 too, where Robin uses pure
Ruby, but TruffleRuby isn't supported yet: a few of its bugs fail tests
(a refused connection is reported as `EINVAL`, for one).
Dragonfly needs `--default_lua_flags=allow-undeclared-keys`, because some of
Robin's Lua scripts build key names from the key prefix. Robin has no runtime
dependencies besides `json` and `logger`: it ships its own small Redis
client. It works with any Ruby or Rack app, and in a Rails app its
[Rails integration](#rails-and-activejob) turns itself on. An optional C extension, compiled at
install time, reads and parses Redis replies faster. If it can't be built,
Robin falls back to pure Ruby automatically.

**Coming from Sidekiq?** Replace `gem "sidekiq"` (and `sidekiq-pro` or
`sidekiq-ent`) with `gem "robin-compat"`, and your app runs on Robin
unchanged, picking up Sidekiq's queued, scheduled, retrying and dead jobs
where they are. See [robin-compat](https://github.com/sferik/robin-compat).

On JRuby (10.1+), RubyGems installs Robin's java-platform gem instead. It
ships a compiled Java extension in place of the C one: the same reply parser
and socket reader, a command encoder, and lock-free bookkeeping for the
connection pool, so worker threads, which run in parallel on the JVM, never
wait on each other. Nothing needs compiling at install time. Give the JVM
a maximum heap (`JRUBY_OPTS=-J-Xmx512m`, say): without one, it grows the
heap under load toward a quarter of the machine's memory, though a busy
server's live heap is far smaller.

Point Robin at Redis with `ROBIN_REDIS_URL` or `REDIS_URL` (or
`REDIS_PROVIDER`, naming the variable that holds the URL, as some hosting
add-ons expect), or configure it:

```ruby
Robin.configure do |config|
  config.redis = {url: "redis://localhost:6379/0"} # also rediss://, unix://
end
```

Other Redis options: `pool_size`, `pool_timeout`, `idle_timeout` (close
connections idle that many seconds), `name`, `connect_timeout`,
`read_timeout`, `write_timeout`, `ssl_params`.

With Redis Sentinel, name the master in the URL (or `master_name:`) and
list the Sentinels. Robin asks them where the master is on every new
connection, checks it really is the master, and moves to the new one after
a failover:

```ruby
config.redis = {
  url: "redis://mymaster/0",
  sentinels: ["10.0.0.1:26379", "10.0.0.2:26379", {host: "10.0.0.3", port: 26379}],
  sentinel_password: ENV["SENTINEL_PASSWORD"] # if the Sentinels need one
}
```

To spread jobs over several Redis servers (shards), push through a pool for
the shard you want. Each shard needs its own Robin processes:

```ruby
SHARDS = %w[redis://r1 redis://r2].map do |url|
  Robin::Redis::Pool.new(size: 10) { Robin::Redis::Connection.new(url: url) }
end

ReportJob.set(pool: SHARDS.sample).perform_async(42)
Robin::Client.via(SHARDS[1]) { ReportJob.perform_async(1); OtherJob.perform_async(2) }
```

## Jobs

```ruby
class ResizeImage
  include Robin::Job
  robin_options queue: "media",
    retry: 10,         # true (default: 20 retries), false, or a number
    retry_for: 86_400, # or keep retrying for a day after the first failure
    retry_queue: "slow", # retries run on this queue
    backtrace: 20,     # keep 20 backtrace lines on failure
    tags: ["images"],  # shown and searchable in the dashboard
    timeout: 120,      # last-resort hard timeout in seconds
    log_level: :debug  # level of its start/done lines (logging: false drops them)

  def perform(image_id, width)
    # ...
  end
end

ResizeImage.perform_async(1, 640)
ResizeImage.perform_at(Time.now + 3600, 1, 640)
ResizeImage.set(queue: "urgent", wait: 30).perform_async(1, 640)
ResizeImage.perform_bulk([[1, 640], [2, 640], [3, 640]])  # pipelined
ResizeImage.perform_bulk(ids.map { [_1, 640] }, spread_interval: 3600) # evenly over the next hour
ResizeImage.perform_inline(1, 640)                        # run now, in this thread
Robin::Client.together { images.each { ResizeImage.perform_async(_1.id, 640) } } # one round trip
```

`Robin::Client.together` holds back the jobs its block pushes and sends
them all when it finishes, in one round trip when they go straight to the
same Redis (none if the block raises).

Arguments must be JSON-native: strings, numbers, booleans, nil, arrays, and
hashes with string keys. Robin raises at push time if they aren't. Set
`config.strict_args = :warn` or `false` to relax this.

Raise `Robin::Discard` from a job to stop it without retrying.

`timeout:` raises `Robin::Job::Timeout` inside the job. It isn't a
`StandardError`, so a job's own `rescue => e` can't swallow it. Like any
`Timeout.timeout`, though, it can interrupt the job anywhere, even inside
an `ensure` block or halfway through a database call. Put timeouts on the
slow operations themselves (HTTP clients, queries) and keep this one as a
last resort.

## Running servers

```sh
robin -r ./app.rb -c 10 -q critical,3 -q default,1   # weighted
robin -r . -q critical -q default -q low             # strict order (app directory)
robin -C config/robin.yml
robin swarm -n 4                                     # 4 processes, preloaded
robin swarm -n 0.5                                   # one process per two CPU cores
robin stats                                          # cluster stats as JSON
robin top                                            # live view of queues, processes and running jobs
robin deploy "v42"                                   # mark a deploy on the metrics charts
robin health --health-port 7433                      # exit 0 if this host's server is healthy
```

```yaml
# config/robin.yml
concurrency: 10
queues: [critical, default, low]
timeout: 25
capsules:
  serial:
    concurrency: 1
    queues: [ledger]
production:
  concurrency: 20
```

`robin top` shows a live view of the cluster in the terminal: totals and
queues, processes, and the jobs running now, refreshed every 2 seconds.
1, 2 and 3 (or tab) switch views, r refreshes and q quits. It only reads.
`robin stats`, `robin top` and `robin deploy` load the app as a client,
like a web process: its `configure_client` blocks run, not its
`configure_server` blocks.

`robin swarm -n` takes a number of processes, or a decimal meaning that
many per CPU core (`-n 1.5` on 8 cores starts 12). `ROBIN_SWARM_COUNT`
works too, and the default is one per core. Each child runs
`config.on(:fork)` hooks first, e.g. to reconnect to a database.

**Capsules** isolate work inside one process, each with its own threads and queues:

```ruby
Robin.configure_server do |config|
  config.capsule("serial") do |cap|
    cap.concurrency = 1
    cap.queues = %w[ledger]
  end
end
```

A job's `capsule` (or `Robin::Capsule.current`, anywhere on a worker's
thread) is the capsule running it, with its `name`, `queues` and
`concurrency`; it's nil outside a server's workers.

The process title shows the version, tag and how many jobs are running
(`robin 0.1.0 shop [3 of 10 busy]`). The tag defaults to the app
directory's name (the app's, in a Capistrano `releases/` directory). On
Heroku, processes are named after their dyno. Robin's Redis connections
are named `robin` (see `CLIENT LIST`). The heartbeat warns when Redis
round trips take over 50ms. A trap the app had already set for one of
Robin's signals still runs, after Robin's.

**systemd.** As a `Type=notify` service, Robin tells systemd when it's
ready and when it's stopping. With `WatchdogSec=` (a few heartbeat
intervals, e.g. 30), its heartbeat keeps the watchdog happy.

**Signals:**

| Signal | Effect |
|---|---|
| `TERM` / `INT` | Graceful shutdown: running jobs get `timeout` seconds, then the rest go back to the queue |
| `TSTP` | Quiet: stop picking up new jobs |
| `TTIN` (or `INFO`, Ctrl-T, on macOS and BSD) | Log every thread's backtrace |
| `USR2` | Under `robin swarm`, rolling restart: a replacement child starts before each old one stops |

You can also quiet or stop any process from the dashboard.

**Resizing.** A running process can change how many workers a capsule
runs, without a restart: from the dashboard's Busy page (for users with
the `:process_control` permission), with `POST
<mount>/api/processes/:identity/resize` and a JSON body like
`{"concurrency": 20, "capsule": "default"}` (1 to 1000; `capsule`
defaults to `"default"`), or from Ruby:

```ruby
Robin::ProcessSet.new.each { |process| process.resize!(20) } # the default capsule
Robin::ProcessSet.new.first.resize!(2, capsule: "serial")
```

The process applies it at its next heartbeat. New workers start right
away; when there are to be fewer, the extra workers finish the job they're
running (it isn't interrupted) and then stop. Robin grows its Redis
connection pool to fit more workers, and never shrinks it. If you set
`pool_size` yourself, it stays as it is, and a resize that would leave
fewer than two connections beyond the workers is refused with a warning
in that process's log (as is one sent to a quiet process). Each resize is
logged and emits a `workers.resized` event, and the capsule's
`concurrency` reports the new count. It lasts until the process
restarts, which starts it with its configured concurrency again. There's
no OS signal for it (`TTIN` already dumps the threads): it travels like
the dashboard's quiet and stop, as a `RESIZE <count> <capsule>` remote
command on the process's signal list.

An idle worker waits up to `config.fetch_timeout` seconds (default 2) for a
job before checking whether it should stop, so an idle process stops within
that time. Lower it for faster shutdowns, at the cost of more round trips
while idle.

`config.fetch_batch` (default 10) caps how many jobs one round trip to
Redis fetches for a process's waiting workers. Higher means fewer round
trips under heavy load; `1` fetches one job at a time.

**Idle time spent for busy time.** Robin does work while it's quiet so
that it doesn't have to when jobs come:

- A standalone `robin` loads all of Robin and tidies its heap
  (`Process.warmup`) before it starts.
- If you turn it on, a standalone `robin` collects its garbage when it
  goes idle (see below).
- On JRuby, a server first runs Robin's push, fetch and middleware code
  for about a second and a half, without Redis or your middleware, so
  the JIT has compiled it before real jobs come (`config.jit_warmup`; on
  by default except on CRuby). Without it, a new process pushes its
  first 20,000 or so jobs about a third as fast as one that warmed up.
- The cluster's leader wakes its scheduler when the next scheduled job or
  retry it knows of is due, rather than at its next poll (about every
  `config.poll_interval` seconds, 5 by default), so jobs scheduled ahead
  start within milliseconds of their time.

**Garbage collection when idle (off by default).** A standalone `robin`
can run a full GC each time it goes idle: no job running, none finished
for a second. The next burst of jobs then starts on a clean heap, and
doesn't pay for the last burst's garbage. Turn it on in `Robin.configure`:

```ruby
config.idle_gc = true   # after any work
config.idle_gc = 1_000  # only after at least 1,000 jobs since the last one
```

It has costs, and they're why it's off:

- **It stops the process.** A full GC pauses every thread while it runs:
  a few milliseconds for a small heap, tens or hundreds for a large one
  (on JRuby, it pauses the whole JVM). A job that arrives during it waits.
- **It costs CPU every time the process goes quiet.** For bursty work
  with short gaps, that can mean a full GC every few seconds, each one
  marking the whole heap, where Ruby's own GC would mostly have run
  cheaper minor collections. A minimum number of jobs (`1_000` above)
  limits it to quiet spells that follow real work.
- **It doesn't make garbage go away.** The work is the same, only moved
  into idle time. If your process is rarely idle, or your jobs allocate
  little, it gains nothing.

Try it if your jobs come in bursts after quiet spells, and the first jobs
of each burst are slower than the rest. Measure the latency of those
first jobs, and Robin's CPU use, with it on and off. Embedded servers
never do it, as they share their process with your app.

**Health checks.** With `config.health_port = 7433` (or `--health-port`,
`health_port:` in `robin.yml`, `ROBIN_HEALTH_PORT`), each server answers
HTTP requests on that port with `200` while its heartbeat reaches Redis
and it isn't shutting down, and `503` otherwise, plus a JSON report.
Swarm children listen on the port plus their index. Point a Kubernetes
probe at it:

```yaml
livenessProbe:
  httpGet: {path: /, port: 7433}
# or, without HTTP probes:
#   exec: {command: [bundle, exec, robin, health, --health-port, "7433"]}
```

The dashboard has its own `/health` (e.g. `/robin/health`) that pings each
cluster's Redis, for load balancers and uptime monitors.

**Swarm** boots your app once and forks `-n` children (default: number of
CPUs), so memory is shared through copy-on-write. Children that crash are
restarted. With `config.memory_limit_mb = 1024`, a child that grows past
the limit restarts gracefully.

**Embedded mode** runs a server inside another process:

```ruby
robin = Robin.configure_embed do |config|
  config.queues = %w[default]
  config.concurrency = 2
end
robin.run
at_exit { robin.stop }
```

In Puma, use the plugin instead. It runs a server in every worker (or in
the one process in single mode), started once the app has loaded, so your
app's own Robin configuration applies, and stopped gracefully whenever
Puma stops a worker: on shutdown, hot restarts (`SIGUSR2`), phased
restarts (`SIGUSR1`, `pumactl phased-restart`) and `fork_worker` reforks.
`robin_config` (optional, after `plugin :robin`) takes the same block as
`configure_embed` and runs once per worker:

```ruby
# config/puma.rb
workers 2
prune_bundler
extra_runtime_dependencies ["robin"]
plugin :robin
robin_config do |config|
  config.concurrency = 2
end
```

Keep `require "robin"` out of `config/puma.rb`, and don't start Robin
from `before_worker_boot`: both load Robin before the app's bundle is
set up, which activates Robin's gem dependencies at whatever versions
are installed, so after a deploy that changes them, phased restarts boot
workers that fail with "You have already activated ...". The plugin only
loads Robin in workers, after the app. With `prune_bundler`, add
`extra_runtime_dependencies ["robin"]` so Puma's master can find the
plugin without activating the gem (the plugin logs a warning if Robin is
loaded in a pruned master). Phased restarts need `preload_app!` off,
which `prune_bundler` implies. Jobs running when a worker stops get
`config.timeout` to finish before they're pushed back to their queues;
keep it (plus 3 seconds) under Puma's `worker_shutdown_timeout` (30s by
default) or Puma kills the worker first (the plugin warns at boot).

## Reliability

Robin never loses a job that has been fetched:

- **Reliable fetch.** A worker moves a job from its queue into an
  in-flight key of its process in one atomic step. The job is only removed
  from it after it finishes, or after its retry or death has been
  recorded, and it's removed by deleting that key, so a job's arguments
  travel from Redis once, however large. When several workers of a
  process ask for jobs at once, one round trip fetches for all of them (up
  to `config.fetch_batch`, 10 by default), and finished jobs are removed
  with the next round trip, so under load a job costs a fraction of a
  round trip. Jobs fetched for a worker stay in flight until they're done;
  ones no worker takes within a second (because every worker got busy) go
  back to their queue, as do the fetched jobs of a process that stops or
  a queue that's paused. A finished job is removed with the next round
  trip of its process, or by a thread of its own if none comes within 2
  milliseconds, so a crash can make only jobs that finished just before
  it run again.
- **Jobs must be idempotent.** Delivery is at least once: a job runs
  again if its process crashes while it runs, or just after it finishes,
  and if a shutdown interrupts it. Write jobs so that running one twice
  does no harm (check whether the work was already done, or use unique
  keys or upserts).
- **Recovery.** If a process crashes, is OOM-killed or loses its node, its
  heartbeat expires. The cluster leader then moves that process's in-flight
  jobs back to the front of their queues. `config.recovery_handlers` (like
  `death_handlers`) are called with each recovered job and whether it was
  a poison pill. A server with `config.leader_candidate = false` never
  becomes the leader, so it never runs the leader's duties (periodic jobs,
  recovery).
- **Poison pills.** A job that was running when its process died more than
  `config.max_recoveries` (3) times goes to the dead set instead of taking
  down process after process.
- **Graceful shutdown.** Jobs still running when the shutdown timeout ends
  are interrupted and pushed back to their queue.
- **Reliable push.** With `config.reliable_push = true`, pushes made while
  Redis is unreachable are buffered in memory (up to 1,000 by default) and
  sent in order once it's back. When the process exits it tries once more;
  jobs it still can't push, and jobs dropped from a full buffer, are
  reported to the error handlers (as `Robin::ReliablePush::Lost` and
  `Dropped`).
- **Deferred push.** `config.push_deferrer` can hold pushed jobs back, e.g.
  until a database transaction commits: it's called with the jobs and a
  block that sends them, and returns truthy when it took over. The Rails
  integration uses it for [transaction-aware pushes](#rails-and-activejob).

Pause a queue (workers skip it until it's unpaused) with
`Robin::Queue.new("mailers").pause!` or from the dashboard.

Shutdowns and failovers are handled conservatively too:

- Jobs pushed back by a graceful shutdown don't count toward the
  poison-pill limit, even if the process is killed while stopping.
- `Robin::Shutdown` only interrupts a job's `perform`, never Robin's own
  bookkeeping, and interrupted jobs share one 3-second grace period.
- After a Redis failover (READONLY, LOADING and similar replies) the
  connection is dropped so the next command reaches the new primary. A
  command is only resent if none of it reached the server.
- The heartbeat and the leader's duties use their own Redis connections
  and higher-priority threads, so busy jobs can't starve them. If a
  heartbeat lapses anyway, the process logs a warning: its running jobs may
  have been recovered and run elsewhere.
- Every minute a process checks its own in-flight keys and puts back jobs
  that no worker holds (for example, a worker that died after finishing a
  job but before acknowledging it, or a round trip whose reply never
  arrived).

At boot, Robin refuses to start on Redis older than 6.2, with a concurrency
or shutdown timeout of 0, a Redis pool smaller than the worker count plus
two, or a queue listed twice. It warns if Redis may evict keys
(`maxmemory-policy` other than `noeviction`). An exception in a `:startup`
hook stops the boot.

## Batches and workflows

```ruby
batch = Robin::Batch.new
batch.description = "Import #{file.name}"
batch.on(:success, ImportCallbacks, "file_id" => file.id)     # every job succeeded
batch.on(:complete, "ImportCallbacks#finished", "file_id" => file.id) # every job ran
batch.on(:death, ImportCallbacks)                             # a job died
bid = batch.jobs do
  rows.each_slice(100) { |slice| ImportRows.perform_async(file.id, slice) }
end

class ImportCallbacks
  def on_success(status, options)
    Notifier.import_done(options["file_id"], status.total)
  end

  def finished(status, options) = ...
end
```

Inside a batch job, `batch` returns the job's batch, so a job can add more
jobs to its own batch (`batch.jobs { ... }`). A batch created inside
another batch's `jobs` block, or inside a running batch job, becomes a
child, and the parent isn't complete until its children are. You can build
multi-step workflows by nesting batches and chaining callbacks.

`batch.jobs(atomic: true) { ... }` pushes the block's jobs when it
finishes, all at once, and none at all if it raises (a batch it created is
deleted again). Without `atomic`, jobs are pushed as the block pushes
them.

Inspect batches with `Robin::Batch::Status.new(bid)` or on the dashboard.

To show a batch's progress on your own pages (a progress bar for an
import, say), mount `Robin::Web::BatchStatus` and poll it from the browser:

```ruby
# config/routes.rb
mount Robin::Web::BatchStatus.new => "/batch_status"
```

`GET /batch_status/<bid>.json` returns `{"bid", "total", "pending",
"failures", "complete", "success", "dead", "cancelled"}`, or a 404 once the
batch is gone. It skips the dashboard's authorization, so it shows counts
and states only (never jobs, arguments, errors or the description), and a
bid's 80 random bits are what keep other people's batches out of reach.
Pass `config:` to read another Redis.

Tag a batch to find it later. `Robin::Batch.list(tag: "imports")` lists
the batches with that tag, newest first, and so does the dashboard's
Batches page when you click a tag:

```ruby
batch.tags = ["imports", "customer:#{file.customer_id}"]   # before the first `jobs`
```

Jobs are pushed as they're created inside `jobs`, never collected first,
so a batch of any size takes no more memory in the process creating it.

Cancel a batch with `Robin::Batch.new(bid).cancel!` (or from the
dashboard). Its child batches are cancelled too. Their jobs that haven't
started are skipped, and running ones see `cancelled?` turn true, so they
can stop early. A cancelled batch still completes once every job has run
or been skipped, so `complete` callbacks fire (check
`status.cancelled?`), but `success` never does, and a cancelled child
counts as a failure in its parent.

## Rate limiting

Limiters work from any Ruby code. If a job hits a limit, it is rescheduled
with backoff rather than counted as a failure.

```ruby
STRIPE = Robin::Limiter.concurrent("stripe", 10, wait_timeout: 5, lock_timeout: 30)
GEO    = Robin::Limiter.bucket("geocoder", 50, :second)
EMAIL  = Robin::Limiter.window("smtp", 1_000, :hour)          # sliding window
CRAWL  = Robin::Limiter.leaky("crawler", 60, 60)              # drips 1/second
OPENAI = Robin::Limiter.points("llm-tokens", 90_000, 60)      # token bucket

def perform(user_id)
  STRIPE.within_limit { Stripe::Charge.create(...) }
  OPENAI.within_limit(points: estimated_tokens) { ... }
end
```

When a limiter doesn't free up within `wait_timeout`, it raises
`Robin::Limiter::OverLimit`. Inside a job, Robin catches that and
reschedules the job with a jittered backoff. After
`config.max_rate_limit_retries` (20) reschedules, normal retries apply.
Points limiters can `adjust` or `refund` points once the real cost is known.

For work that can simply be dropped, such as refreshing a cache, give the
limiter `policy: :skip`: when it doesn't free up in time, `within_limit`
returns nil without running the block (and the dashboard still counts it
as over the limit).

```ruby
REFRESH = Robin::Limiter.bucket("price-refresh", 10, :minute, wait_timeout: 0, policy: :skip)
REFRESH.within_limit { PriceCache.refresh(sku) }
```

Bucket and window limiters can count one call as several uses, e.g. an
API call that covers a batch of records: `GEO.within_limit(used: 10) { ... }`.

Limiters keep their state in the configured Redis. To keep them in another
Redis (a shard of their own, say), wrap the calls in `Robin::Limiter.via`:

```ruby
LIMITS = Robin::Redis::Pool.new(size: 10) { Robin::Redis::Connection.new(url: ENV["LIMITER_REDIS_URL"]) }
Robin::Limiter.via(LIMITS) { STRIPE.within_limit { charge! } }
```

The dashboard's Limiters page shows the limiters in the configured Redis
only.

Every kind of limiter also takes `reschedule:` (how many times a job that
hits it is rescheduled before it counts as a failure; 0 fails at once) and
`backoff:`, a callable that picks the delay:

```ruby
PARTNER = Robin::Limiter.window("partner-api", 100, :minute,
  reschedule: 5, backoff: ->(count, error, payload) { error.retry_after || 30 * count })

Robin.configure_server do |config|
  config.rate_limit_backoff = ->(count, error, payload) { 10 * count } # for every limiter without one
end
```

A backoff returning nil gets the default (5 seconds times the count, or
however long the limiter says capacity takes to free up, up to 5 minutes,
with jitter). `Robin::Limiter.unlimited` never limits and never touches
Redis: swap it in where a limit shouldn't apply, such as in tests.

## Periodic (cron) jobs

```ruby
Robin.configure_server do |config|
  config.periodic do |cron|
    cron.register "*/5 * * * *", "PruneSessions"
    cron.register "0 9 * * MON-FRI", "DailyDigest", queue: "mailers", tz: "America/New_York"
    cron.register "@hourly", "SyncInventory", args: ["warehouse-1"], description: "Pull stock levels"
  end
end
```

Only the elected leader enqueues periodic jobs, and each tick is
deduplicated in Redis, so a job runs once per tick no matter how many
processes you run. After a leader failover, at most one missed tick is
caught up. The dashboard lists every periodic job with its next run and
history, and lets you run one now or pause it.

IANA time zones need the `tzinfo` gem. `UTC` and fixed offsets like `+05:30`
work without it.

In a Rails app, a periodic job can be an ActiveJob class: Robin pushes it
like `perform_later` would (on the given queue, else the job's own), but
without running ActiveJob's enqueue callbacks.

To catch a broken schedule before it ships, check it in your test suite.
`Robin::Periodic.verify!` takes the block you give `config.periodic` (or a
config, to check all of its blocks) and raises listing every bad cron
expression or time zone, class that doesn't exist or isn't a job, and
argument that JSON would change:

```ruby
# config/initializers/robin.rb
SCHEDULE = ->(cron) { cron.register "0 3 * * *", "NightlyReport" }
Robin.configure_server { |config| config.periodic(&SCHEDULE) }

# test/robin_schedule_test.rb
test("the schedule is valid") { Robin::Periodic.verify!(&SCHEDULE) }
```

## Unique, debounced, expiring and encrypted jobs

```ruby
class RebuildSearchIndex
  include Robin::Job
  robin_options unique_for: 600            # duplicate pushes (same args) for 10 min are dropped
end

class SyncContact
  include Robin::Job
  robin_options debounce: 30               # runs once, 30s after the *last* push
end

class SendFlashSale
  include Robin::Job
  robin_options expires_in: 3600           # skipped if it hasn't started within an hour
end

class ChargeCard
  include Robin::Job
  robin_options encrypt: true              # arguments are encrypted at rest
end

Robin.configure do |config|
  config.encryption_keys = {1 => ENV["ROBIN_KEY_V1"], 2 => ENV["ROBIN_KEY_V2"]}
end
```

- **Unique locks** are released when the job succeeds (the default) or, with
  `unique_until: :start`, when it starts. Define `robin_unique_args(args)` on
  the class to choose which arguments count toward uniqueness.
- **Encryption** uses AES-256-GCM, with the job id as authenticated data.
  New jobs are encrypted with the highest-numbered key, and any listed key
  can decrypt, so you can rotate keys without downtime. Decrypted arguments
  are never written back to Redis, including in retries and the dead set.

## Long-running (iterable) jobs

Iterable jobs save their position as they go. On deploys and restarts they
stop between iterations and resume elsewhere, without redoing work.

```ruby
class BackfillAvatars
  include Robin::IterableJob

  def build_enumerator(account_id, cursor:)
    active_record_records_enumerator(User.where(account_id: account_id), cursor: cursor)
  end

  def each_iteration(user, _account_id)
    user.regenerate_avatar!
  end
end
```

Also available: `array_enumerator`, `active_record_batches_enumerator` and
`csv_enumerator`, plus `on_start`, `on_resume`, `on_cancel`, `on_stop`
(after an interruption or a cancellation) and `on_complete` hooks, and
`around_iteration`, which wraps each iteration (yield to run it). Inside
them and `each_iteration`, `cursor` is the last finished item's cursor and
`current_object` the item being worked on.

A long iteration can hold a worker for hours. Set
`config.max_iteration_runtime` (seconds), or the `max_iteration_runtime`
option on a job, and a run that goes past it checkpoints and goes back on
its queue, as it does on a deploy, so other jobs get a turn.

If an iteration raises, the progress made so far is saved first, so the
retry resumes after the last finished item. A cancelled iterable job
stops at its next checkpoint, about every five seconds: saving its
position, reporting progress and checking for cancellation share one
Redis round trip. Progress is a percentage when the enumerator knows its
size (`array_enumerator` does), and otherwise a count of the items done
(the Active Record and CSV enumerators). Iterable jobs don't define
`perform` (Robin raises if one does). Robin logs a warning when a single
iteration takes longer than the shutdown timeout, since a deploy could
interrupt it midway.

## Progress and cancellation

```ruby
def perform(ids)
  ids.each_with_index do |id, i|
    return if cancelled?
    process(id)
    progress!((i + 1) * 100.0 / ids.size, "#{i + 1} of #{ids.size}")
  end
end

jid = Export.perform_async(ids)
Robin.cancel!(jid)   # jobs that haven't started are skipped; running ones see cancelled?
Robin.cancel!(*jids) # several, in one round trip
```

Progress shows live on the dashboard's Busy page. Pass `nil` for the
percentage when the job can't tell how far along it is: the page shows the
message without a percentage.

## Middleware

```ruby
class TenantMiddleware
  include Robin::Middleware::ConfigAware # optional: gives you config, redis, logger

  # client side: return without yielding to stop the push
  def call(job_class, payload, queue, redis)
    payload["tenant"] ||= Current.tenant_id
    yield
  end
end

class TenantServerMiddleware
  def call(job, payload, queue)
    Current.set(tenant_id: payload["tenant"]) { yield }
  end
end

Robin.configure do |config|
  config.client_middleware { |chain| chain.add TenantMiddleware }
end
Robin.configure_server do |config|
  config.server_middleware { |chain| chain.add TenantServerMiddleware }
end
```

A middleware is instantiated for every job. If yours keeps no per-job state
in instance variables, `include Robin::Middleware::Stateless` and one
instance serves every job instead (on every thread). The built-in
middleware all work this way.

A middleware that only matters to some jobs can say which with a class
method `applies?`, taking the same arguments as `call`. The chain skips it
for the others, without building it:

```ruby
class AuditMiddleware
  def self.applies?(_job, payload, _queue) = payload.key?("audit")

  def call(job, payload, queue) = Audit.around(payload) { yield }
end
```

The built-in middleware (encryption, expiry, uniqueness, debouncing,
batches, profiling) use it, so jobs that use none of those features skip
them.

## Errors, retries and the dead set

Failed jobs are retried with exponential backoff. The delay starts at about
15 seconds, grows 1.7x per attempt with ±20% jitter, and is capped at one
week. The default 20 retries span about ten days. After the last retry the
job moves to the dead set, which keeps 10,000 jobs for 180 days by default.
From the dashboard you can retry dead jobs, with or without editing their
arguments first.

```ruby
class CallWebhook
  include Robin::Job
  robin_options retry: 8

  robin_retry_in do |count, exception, payload|
    case exception
    when Net::HTTPTooManyRequests then 60 * count
    when ArgumentError then :kill       # straight to the dead set
    when RecordGone then :discard       # drop it
    end                                 # nil: default backoff
  end

  robin_retries_exhausted do |payload, exception|
    Alerts.webhook_gave_up(payload["args"].first, exception)
    :discard if payload["args"].first.nil? # drop it instead of keeping it in the dead set
  end
end

Robin.configure do |config|
  config.error_handlers << ->(ex, context, _config) { ErrorTracker.notify(ex, context) }
  config.death_handlers << ->(payload, ex) { ... }
end
```

Error handlers run in the failed job's logging context (its class, jid,
batch and tags). The default handler logs each error as one entry: the
error, its context and the start of its backtrace.

Things that aren't errors but are worth knowing about (a job expired,
skipped or rate limited, a worker died, Redis is slow, the heartbeat
lapsed, a reliable push was buffered or lost, and so on) are events.
`config.event_handlers` are called with each event's name and a Hash
about it; `Robin::Events` lists them. In a Rails app they're published through
`ActiveSupport::Notifications` as `"<event>.robin"`.

```ruby
config.event_handlers << ->(name, payload) { Metrics.increment("robin.#{name}") }
```

`retry_for:` limits retries by time instead: the job keeps retrying (with
the same backoff) until a retry would come more than that many seconds
after its first failure, and then dies. Without an explicit `retry:` count
it can take as many attempts as fit; with one, whichever limit comes first
applies. `retry_queue:` sends a job's retries to another queue, e.g. a
low-priority one, so failing jobs don't hold up fresh ones.

Delays returned by `robin_retry_in` get up to 10% (at most 10 seconds) of
jitter, so jobs that failed together don't all retry at the same moment.
`config.retry_backoff` replaces the backoff altogether: a callable
`(failures, exception, payload, custom)` returning the seconds before the
retry, where `custom` is the job's `robin_retry_in` answer (or nil); Robin
adds no jitter to it. An ActiveJob job's retry hooks come from the class
it wraps.

Death handlers run whenever a job won't run again: when it moves to the
dead set, and when it's discarded (`retry: false`, `:discard` from
`robin_retry_in`, `dead: false`, or `:discard` from `robin_retries_exhausted`).
Discarded jobs have `payload["discarded_at"]` set.

A retry or dead job is stored as it was pushed, plus the failure details.
If `perform` or a middleware changed the job's arguments in memory, those
changes aren't saved.

Jobs with `backtrace: true` (or a number of lines) keep the error's
backtrace, compressed. `config.backtrace_cleaner` trims it first (in a Rails
app, `Rails.backtrace_cleaner`); read it back with
`entry.error_backtrace`. `retry_all`, `kill_all` and the dashboard's
"all" actions work through a set a page at a time, so huge sets never have
to fit in memory.

## Metrics

Each process tracks per-class counts, total time and a latency histogram in
memory (times and histograms cover successful runs only), and flushes them with its heartbeat, so recording adds no Redis
round-trips per job. Data kept:

- per-minute data for the last 8 hours;
- hourly rollups for `config.metrics_retention_days` (90 by default);
- queue size and latency history sampled by the leader.

```ruby
Robin.configure do |config|
  config.statsd = Robin::Statsd.new(host: "127.0.0.1", port: 8125, prefix: "robin",
                                    tags: {env: "production"}, dogstatsd: true)
end
```

Besides job counts and timings and queue sizes and latency, StatsD gets
`batch.created`, `batch.complete`, `batch.success`, `batch.death` and
`batch.cancelled` counters and a `batch.duration` timing (creation to
completion), plus `jobs.recovered` (in-flight jobs put back from dead
processes), `jobs.orphaned` (in-flight jobs no worker held) and
`jobs.poison` (by class) counters. Under DogStatsD, the batch metrics
carry the batch's tags (`tag:<tag>` for each).

For percentiles across every process, add `distributions: true` (DogStatsD
only) to also send Datadog distributions: `jobs.perform_dist` (by class;
this sends a packet per successful job) and `batch.duration_dist`.

The dashboard also serves Prometheus metrics at `<mount>/metrics`. Browsers
asking for HTML get the Metrics page at that path instead.

**Deploy markers.** Mark each deploy, and the dashboard's metrics charts
draw a line where it happened, so a change in throughput, failures or
timing can be matched to the deploy that caused it:

```ruby
Robin::Deploy.mark!("v42 #{`git rev-parse --short HEAD`.strip}")
```

or `bundle exec robin deploy "v42"` from a deploy script. Every process
may mark the same deploy (at boot, say): a label already marked in the
last hour isn't marked again. Markers are kept as long as hourly metrics.

**GVL contention.** Only one of a process's threads runs Ruby code at a
time; the others wait for the GVL. With the C extension, each process
measures how long its threads wait, and every heartbeat records its
contention: the share of the time its threads could have spent waiting
that they did. Near 0%, threads rarely get in
each other's way; near 100%, every thread wanted to run all the time, so
more threads won't run more Ruby code. Threads waiting on I/O (Redis, a
database, an HTTP call) don't wait for the GVL, so an I/O-heavy process
stays low however many threads it has.

The dashboard shows each process's contention, StatsD gets it as the
`gvl.contention` gauge, Prometheus as
`robin_process_gvl_contention_percent`, and a process whose contention stays at 50% or
more for three heartbeats in a row logs a warning (at most every 10
minutes) and emits a `gvl.contended` event. When it's persistently high,
CPU-heavy jobs would finish sooner with fewer threads per process and
more processes (or `robin swarm`). Robin doesn't change your concurrency
itself. Measuring costs under 2% even in code that does nothing but
switch threads; `config.gvl_monitoring = false` turns it off. JRuby has
no GVL, so there's nothing to measure (nor is there on a 32-bit platform,
where the extension can't keep a wait's start with its thread).

## Tracing and profiling

**OpenTelemetry.** With the `opentelemetry-api` gem (and an SDK exporting
somewhere), Robin traces pushes and runs:

```ruby
require "robin/opentelemetry"

Robin.configure do |config|
  Robin::OpenTelemetry.install(config)               # runs are children of their push
  # Robin::OpenTelemetry.install(config, parent: :link) # or new traces, linked to it
end
```

Pushing opens a `publish <queue>` producer span and stores the trace
context in the job; running it opens a `process <queue>` consumer span.
Both follow the messaging semantic conventions, plus `robin.job.class`
and `robin.job.retry_count`.

**Profiling one job.** With `gem "vernier"` (CRuby only), push a job with
`profile:` to record a sampling profile of that run, even if it fails:

```ruby
ReportJob.set(profile: true).perform_async(42)
ReportJob.set(profile: "big export").perform_async(43) # labelled
```

Profiles are kept in Redis for a week (the newest 100). The dashboard lists
them and opens them in the [Firefox Profiler](https://profiler.firefox.com);
from Ruby, use `Robin::Profiler.list` and `Robin::Profiler.data(jid)`. A
process profiles one job at a time; others asking meanwhile run unprofiled.

## Web dashboard

```ruby
# config/routes.rb
require "robin/web"
mount Robin::Web => "/robin"

# or config.ru
require "robin/web"
run Robin::Web
```

The dashboard is a TypeScript single-page app built with bun and shipped
pre-built inside the gem. Its pages are the dashboard, busy processes and
jobs (with live progress), queues, scheduled, retries, dead, batches,
limiters, cron, job profiles, and per-class metrics. It updates live by polling every
few seconds. Set `Robin::Web.live_updates = :stream` to push updates
over Server-Sent Events instead. Each open stream occupies a web server
thread, so streaming is off by default.

```ruby
Robin::Web.authorize do |env, action, resource|
  user = env["warden"]&.user
  action == :read ? user&.staff? : user&.admin?
end
Robin::Web.read_only = true                               # nobody can change anything
Robin::Web.clusters = {"us-east" => us_config, "eu-west" => eu_config} # multi-cluster
```

**Rows of your own on job pages.** Add a row to every job's details, as
text or as a link (http(s) URLs and paths only). The block gets the job's
payload, and returning nil leaves the row out:

```ruby
Robin::Web.job_info("Customer") do |job|
  id = job["args"].first
  {text: "##{id}", href: "/admin/customers/#{id}"} if job["class"] == "InvoiceJob"
end
```

**Assets from a CDN.** Serve the dashboard's scripts, stylesheets, fonts
and images from elsewhere by copying `lib/robin/web/dist/assets` (that is,
`Robin::Web::DIST + "/assets"`) there for each Robin version. The CDN must
send CORS headers, because the scripts are modules. The content security
policy lets the dashboard load from that host.

```ruby
Robin::Web.assets_path = "https://cdn.example.com/robin/#{Robin::VERSION}/"
```

**Languages.** The dashboard speaks Arabic, Chinese (simplified and
traditional), Czech, Danish, Dutch, English, French, German, Hebrew,
Hindi, Italian, Japanese, Korean, Norwegian, Persian, Polish, Portuguese
(Brazil), Russian, Spanish, Swedish, Turkish, Ukrainian, Urdu and
Vietnamese, with right-to-left layouts for Arabic, Hebrew, Persian and
Urdu. It picks the first of the browser's languages it knows, and can be
switched under Settings (the choice is remembered). Numbers, dates and
durations follow the language too. Each language is a separate file,
loaded only when it's chosen. The translations were machine-made; native
speakers are welcome to improve them (see [Development](#development)).

Changes require a same-origin request with the `X-Robin-Request` header
(and, from browsers that send it, a same-origin `Sec-Fetch-Site`), so
cross-site requests can't make them (CSRF protection). The dashboard
also sends a strict Content Security Policy.

**Your own pages.** Add a tab to the dashboard without writing any
frontend code: describe the page with blocks, and attach actions to its
buttons.

```ruby
class BillingPage < Robin::Web::Extension
  slug "billing"
  title "Billing"

  def blocks(request) # request.config, request.params, request.env
    [
      {type: "stats", items: [{label: "Invoices waiting", value: Robin::Queue.new("invoices").size}]},
      {type: "heading", text: "Overdue"},
      {type: "table", columns: ["Customer", "Total"], rows: Invoice.overdue.map { [_1.customer, _1.total] }},
      {type: "text", text: "Invoices go out at 6am."},
      {type: "actions", items: [{label: "Send now", action: "send", confirm: "Send every invoice?"}]}
    ]
  end

  action "send" do |request|
    SendInvoices.perform_async
    "Sending invoices" # the message the user sees
  end
end

Robin::Web.register(BillingPage)
```

Values in blocks are always shown as text, never as HTML. Running an
action needs the `:extensions` permission (the resource passed to
`authorize` is `"extension:billing/send"`).

For anything blocks can't show, a page can bring its own frontend code: a
JavaScript module (and a stylesheet), served from a directory of assets,
plus JSON data endpoints for it to call.

```ruby
class ReportsPage < Robin::Web::Extension
  slug "reports"
  assets File.expand_path("reports", __dir__) # served at <mount>/extensions/reports/
  script "reports.js"
  stylesheet "reports.css"
  translations File.expand_path("reports/locales", __dir__) # de.yml, ja.yml, ...

  data "late" do |request|                    # GET api/extensions/reports/data/late
    Report.late.limit(Integer(request.params.fetch("limit", 20))).map(&:to_h)
  end

  action "rerun" do |request|                 # request.body is the JSON sent
    RerunReport.perform_async(request.body.fetch("id"))
    request.t("Rerunning {name}", name: request.body.fetch("name"))
  end
end
```

```js
// reports/reports.js: called with an element to render into and a context
export default function render(element, robin) {
  const heading = document.createElement("h2");
  heading.textContent = robin.t("Late reports");
  element.append(heading);
  robin.data("late", { limit: 50 }).then((reports) => { /* draw them */ });
  // robin.action("rerun", { id, name }) resolves to the action's message;
  // robin.toast(message), robin.navigate("/queues"), robin.locale, robin.slug
  return () => { /* the page went away: stop timers, remove listeners */ };
}
```

The script runs with the dashboard's own Content Security Policy, so it
can load further files from its assets directory but nothing from other
sites, and inline `<script>` and `<style>` elements are blocked. Translations are YAML files
mapping English text to the language (`de.yml`: `Late reports: Verspätete
Berichte`); they translate the page's title in the navigation, text passed
to `request.t` in blocks and actions, and `robin.t` in the script. Viewing
the page, its assets and its data needs the `:read` permission.

## Rails and ActiveJob

The Rails integration is part of the `robin` gem, and turns itself on in
a Rails app: Bundler loads robin after Rails, and robin then joins the
app's boot. Elsewhere it stays off and loads nothing of Rails. If robin is
required before Rails (or outside Bundler.require), add
`require "robin/rails"` after Rails. It needs Rails (railties and Active
Job) 7.2 or newer, and is tested in CI against the latest 7.2, 8.0 and 8.1
releases.

```ruby
# Gemfile
gem "robin"
```

```sh
bin/rails generate robin:install            # config/robin.yml, an initializer, the dashboard route
bin/rails generate robin:job report queue:low retry:5   # app/jobs/report_job.rb and its test
bundle exec robin                           # boots the Rails app in this directory
```

`robin:install` creates:

- `config/robin.yml`, the server settings (concurrency, queues, timeout,
  per-environment sections) read by `bundle exec robin`
- `config/initializers/robin.rb`, with `Robin.configure` (every process)
  and `Robin.configure_server` (only the robin process) blocks, and a
  commented `Robin::Web.authorize` example
- a `mount Robin::Web => "/robin"` line in `config/routes.rb`. The
  dashboard can see and change every job, so protect it: with
  `Robin::Web.authorize`, or by mounting it inside an authenticated route
  constraint (e.g. Devise's `authenticate :user, ->(user) { user.admin? } do ... end`).

Running it again changes nothing.

`robin:job NAME [option:value ...]` creates `app/jobs/NAME_job.rb`, a
`Robin::Job` with those `robin_options` (`queue` defaults to `"default"`;
numbers, `true` and `false` stay literals, and a bare `option` means
`true`), and a test: `spec/jobs/NAME_job_spec.rb` when the app generates
RSpec tests, `test/jobs/NAME_job_test.rb` otherwise. Pass
`--test-framework=rspec` or `test_unit` to choose.

In a Rails app:

- **Executor and reloader.** Every job runs inside the app's reloader, so
  code reloading, query caches and connection checkin work as in a request.
- **`bundle exec robin`** boots the Rails app in the current directory (or
  the one given with `-r`), and `RAILS_ENV` picks the `config/robin.yml`
  section. `-e production` sets `RAILS_ENV` too.
- **Environment and logging.** `Robin.config.environment` follows
  `Rails.env` (set before your initializers, so they can override it).
  Outside the robin process (web, console), Robin logs to `Rails.logger`.
- **Error reporting.** Errors go to the Rails error reporter
  (`Rails.error`), so Sentry, Honeybadger, AppSignal and friends see them
  through their Rails integration. A failed job is reported as unhandled
  with source `"robin.job"` and context `robin` (what failed), `job_class`,
  `jid`, `queue`, `retry_count` and `bid`, never its arguments. Robin's own
  errors (e.g. Redis unreachable) are reported as handled with source
  `"robin"`. The executor doesn't report jobs' exceptions itself, and
  `Rails.error` reports an exception only once, so nothing is reported
  twice. `Robin::Discard` is never reported.
- **ActiveJob.** `config.active_job.queue_adapter = :robin` runs ActiveJob
  jobs on Robin. They can use `robin_options` (retries, tags, expiry...),
  `perform_all_later` takes one round trip, however many classes and
  queues its jobs have, and job continuations checkpoint when the server
  shuts down. Periodic jobs can be ActiveJob classes
  (`cron.register "0 3 * * *", "NightlyReportJob"`): Robin pushes them as
  `perform_later` would, on the given queue or the job's own, but without
  running enqueue callbacks. `Robin::Job` can't be included in ActiveJob
  classes: use one or the other.
- **Transaction-aware pushes** (opt-in): jobs pushed inside Active Record
  transactions are sent once every open transaction commits, and dropped
  when it rolls back, so a job never runs before its data is visible. The
  jobs pushed in the same transaction go in one round trip.
- **Current attributes** (opt-in): the `ActiveSupport::CurrentAttributes`
  classes you list (e.g. `Current`) are saved in each job as it's pushed
  and set while it runs, so `Current.user` or `Current.tenant` mean the
  same thing in the job as where it was pushed. They're serialized like
  ActiveJob arguments (records travel as GlobalIDs) and stored as they
  are, readable in Redis and the dashboard, so leave secrets out. Classes
  are looked up by name, so code reloading keeps working, and one renamed
  since a job was pushed is skipped.

```ruby
# config/application.rb
config.active_job.queue_adapter = :robin
config.robin.report_errors = true      # the default; false to stop reporting to Rails.error
config.robin.transactional_push = true # push jobs only after Active Record transactions commit
config.robin.current_attributes = ["Current"] # carry Current.* from where a job is pushed into the job
config.robin.notifications = false     # stop publishing Robin's events as "<event>.robin" notifications
```

With `notifications` (on by default), Robin's events (see `Robin::Events`)
are published through `ActiveSupport::Notifications` as `"<event>.robin"`:

```ruby
ActiveSupport::Notifications.subscribe("job.expired.robin") do |event|
  Rails.logger.info("expired before it ran: #{event.payload[:job]["jid"]}")
end
```

Outside Rails' configuration, the same pieces are available directly:
`Robin.config.push_deferrer = Robin::Rails::TransactionalPush`,
`Robin.config.error_handlers << Robin::Rails::ErrorReporter.new(Rails.error)`,
`Robin.config.event_handlers << Robin::Rails::Notifications` and
`Robin::Rails::CurrentAttributes.install(Robin.config, ["Current"])`.

## Testing

```ruby
require "robin/testing"   # fake mode by default

SendReceipt.perform_async(1)
assert_equal 1, SendReceipt.jobs.size
SendReceipt.drain                     # run them
Robin::Testing.inline! { SendReceipt.perform_async(1) }   # run immediately
Robin::Testing.disable! { ... }       # talk to real Redis
```

A mode set with a block applies to the current thread only, so tests can
run in parallel; without a block it's the default for every thread.

## The data API

Everything in the dashboard is also available from Ruby:

```ruby
stats = Robin::Stats.new
stats.processed; stats.failed; stats.enqueued; stats.queues; stats.history(days: 7)

queue = Robin::Queue.new("mailers")
queue.size; queue.latency; queue.pause!
queue.each { |job| job.delete if job.args.first == 42 }
queue.delete_by_class("ReportJob") # inside Redis, a slice at a time

Robin::RetrySet.new.scan("NoMethodError").each(&:retry!)
Robin::DeadSet.new.retry_all
Robin::ScheduledSet.new.find_job(jid)&.add_to_queue
Robin::JobLocator.new.locate(jid) # running, scheduled, retrying, dead or queued
Robin::ProcessSet.new.each(&:quiet!)
Robin::ProcessSet.new.first.resize!(20, capsule: "default") # workers, from its next heartbeat
Robin::WorkSet.new.each { |identity, thread, work| ... }
Robin::Metrics::Query.new.recent(minutes: 60)
```

`delete_by_class` matches the class the dashboard shows (an ActiveJob's
own class, not the wrapper's) and returns how many jobs it deleted; the
dashboard does the same when the jobs you've selected on a queue's page
share a class. Looking a job up by jid also searches queues inside Redis,
a slice at a time.
With `config.jid_index = true`, Robin also remembers which queue each job
was pushed to (for a week, or the number of seconds you give), so lookups
search that queue first: one small key per job, in exchange for fast
lookups in large backlogs.

## Performance

Robin never gets slower: a change that makes it slower at any of its
benchmarks fails CI, whatever else it improves, and is backed out or
fixed at once. That's [WebKit's performance policy](https://webkit.org/performance/),
enforced by [Duel](https://github.com/sferik/duel-ruby), which runs
Robin's benchmarks ([`duel/`](duel/)) on each change and on the code it
changes, side by side, and fails when the change is slower at any of
them: by CPU time, instructions, Redis CPU, allocations, round trips,
Redis commands or peak memory. Each night it also compares `main` with
the last release, so small slowdowns can't add up unnoticed.
[CONTRIBUTING.md](CONTRIBUTING.md#performance-never-slower) has the
policy and how the guards tell a real regression from noise.

On an Apple M1 Max with local Redis, one CRuby process (YJIT) with 10
threads runs about 120,000 no-op jobs per second, a cluster of processes
about 280,000 against one Redis, and `perform_bulk` pushes about 360,000
jobs per second. Workers asking for jobs at the same time share one round
trip to Redis, so under load a job costs a fraction of one.

Against Sidekiq 8.1 OSS on the same machine and Redis
(`rake bench:compare`), Robin is many times faster at many operations:

| | Robin vs Sidekiq |
|---|--:|
| Processing jobs | 5.1x faster |
| Processing jobs with Redis 1 ms away | 8.8x faster |
| A cluster of processes on one Redis | 4.8x faster |
| Moving scheduled jobs onto queues when due | 61x faster |
| Requeuing retries after an outage | 28x faster |
| Redis CPU per job | 8x faster |
| Jobs lost when a server is killed | 0 vs 10 |

[bench/RESULTS.md](bench/RESULTS.md) has the detailed results on Ruby 3.4,
Ruby 4.0 and JRuby, what each benchmark tests and how they were run.

The optional C extension encodes commands, then sends them, waits for the
replies and reads them in one release of the GVL, checking for dropped
connections in the same call. It also parses replies 3–10x faster than pure
Ruby, which speeds up the dashboard and the data API on large queues. The
Java extension parses, encodes and reads on JRuby and keeps the connection
pool's bookkeeping lock-free.

## Redis layout

Every key starts with `config.key_prefix` (default `robin:`), so Robin can
share a database with other data. Robin uses Lua scripts for its atomic
operations and doesn't support Redis Cluster; use a single primary, with a
replica for failover if you need one.

The keys a job's life runs through (`queue:<name>`, `queues`, `schedule`,
`retry`, `dead`, `paused`, `processes`, `stat:*`, and each running
process's record at its identity) keep the formats common Ruby job tools
share: queues are lists pushed at the head and taken from the tail; the
schedule, retry and dead sets are scored in epoch seconds; jobs are JSON
with `created_at` and `enqueued_at` in epoch milliseconds, a 0-based
`retry_count` and a compressed `error_backtrace`. Robin's own keys
(batches, limiters, metrics, in-flight jobs...) can get a prefix of
their own with `config.internal_key_prefix`, so with `key_prefix = ""` the
job keys sit at the top level, where other tools look for them.

A process keeps each job it has fetched in a list of its own,
`inflight:<identity>:<n>`, registered in the set `inflight:<identity>`
(listed in `inflights`) before a job is first moved into it; a key is
used again once its job is acknowledged. Recovery still reads the single
`inflight:<identity>` list that processes of earlier development versions
kept their jobs in.

## Development

```sh
bundle install
rake compile          # build the C extension (optional); on JRuby, the Java one
rake test             # needs a local Redis; uses db 15 (ROBIN_TEST_REDIS_URL)
                      # one process per test file, TEST_JOBS at a time
                      # (default: one per CPU); rake test:serial for one process
rake test:rails       # just the Rails integration's tests (test/rails/)
rake web:build        # rebuild the dashboard (needs bun)
cd web && bun run dev # dashboard watch mode
rake bench
rake bench:compare   # Robin vs Sidekiq (installs bench/compare/Gemfile)
rake perf            # fails if this tree is slower than origin/main (Duel; needs redis-server)
```

To try things out by hand, [`demo/`](demo/README.md) is a small app with
sample jobs and seed data: `cd demo && bin/seed && bin/dev`.

Robin holds itself to 100% test coverage and 100% mutation coverage, on
the Ruby, C, Java and TypeScript sides. CI enforces it:

| Check | Command |
|---|---|
| Ruby lint | `bundle exec rubocop` and `bundle exec standardrb` |
| Ruby tests (MRI and JRuby) | `rake test` |
| Ruby coverage: 100% lines, branches and methods | `COVERAGE_STRICT=1 rake test` |
| Ruby mutation coverage: 100% | `bundle exec mutant run` |
| Ruby types: RBS signatures (`sig/`) and Steep, strict (CRuby) | `rake steep` |
| Performance: never slower than the baseline at any benchmark ([Duel](https://github.com/sferik/duel-ruby); [CONTRIBUTING.md](CONTRIBUTING.md#performance-never-slower)) | `rake perf` |
| C lint: clang-format, clang-tidy, `-Werror` | `rake c:lint` |
| C coverage: 100% lines, branches and functions | `rake c:coverage` (needs gcovr) |
| Java lint: google-java-format, `javac -Xlint:all -Werror` | `rake java:lint` |
| Java coverage: 100% lines, branches and methods (JaCoCo) | `rake java:coverage` |
| Java mutation coverage: 100% (PIT) | `rake java:mutation` |
| Frontend lint and types | `cd web && bun run lint && bun run typecheck` |
| Frontend coverage: 100% | `cd web && bun run test:coverage` |
| Frontend mutation coverage: 100% | `cd web && bun run test:mutation` |

The Java tasks run under JRuby with a JDK 21 (or set `JRUBY_JAR` to JRuby's
`lib/jruby.jar`); they download their pinned, checksummed tools into
`tmp/java-tools`. The java-platform gem is built under JRuby with
`rake java:compile` and then `ROBIN_PLATFORM=java gem build robin.gemspec`.

**Translating the dashboard.** Messages are written in English in the
code, wrapped in `t()` (or `tn()` for plurals), and each language's
`web/src/locales/<code>.ts` maps them to translations. `bun run
scripts/messages.ts de` (in `web/`) lists what German is missing, and the
tests check that every catalogue has every message, keeps its
placeholders and gives each plural form its language uses.

Tests pin how many Redis round trips Robin makes with `assert_roundtrips`
(from `test/support/roundtrips.rb`), so a change that adds one fails:

```ruby
assert_roundtrips(1) { Robin::Client.push("class" => "Thing", "args" => [1]) }
```

It counts the calls, pipelines and transactions the block's thread sends
(`all_threads: true` for every thread's), not connecting or reloading a
Lua script Redis lost, takes an Integer or a Range, returns the block's
value, and lists the commands of each round trip when the count is wrong.

Assertions are strict (minitest-strict): `assert`, `refute` and the
predicate and operator assertions take only `true` and `false`, so a
method that returns `nil` where it means `false` fails its test. On CRuby,
`test/allocations_test.rb` holds the paths every job takes (pushing,
fetching, running, the middleware chain, metrics, logging) to allocation
budgets with minitest-memory's `assert_allocations`; re-measure them with
`ROBIN_MEASURE_ALLOCATIONS=1`.

Mutation testing starts many test processes at once. Point
`ROBIN_TEST_REDIS_URL` at a Redis listening on a Unix socket (e.g.
`unix:///tmp/redis.sock?db=15`) so they don't exhaust local TCP ports.

## License

Robin is released under the [GNU Lesser General Public License v3.0](LICENSE)
(see also [COPYING](COPYING) for the GPL v3 it builds on). You can use Robin
in proprietary applications. Changes to Robin itself must be shared under
the same license.

The Robin mascot and logos in `assets/` are part of the project and
licensed under the same terms.
