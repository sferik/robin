# Benchmark results: Robin vs Sidekiq

Robin 0.1.0 against Sidekiq 8.1.7, on Ruby 3.4, Ruby 4.0 and JRuby, all
running the same workloads against the same Redis. Configuration details
are at the [end](#configuration).

## Processing jobs

One server process draining a backlog of 500,000 no-op jobs, the
workload of Sidekiq's own load test (`bin/sidekiqload`). It measures how
many jobs per second the queue system can move through fetch, run and
acknowledge, with 10 worker threads and Redis on the same machine.

| | Robin | Sidekiq | Robin vs Sidekiq |
|---|--:|--:|--:|
| Ruby 3.4 | 119,603 jobs/s | 23,647 jobs/s | **5.1x faster** |
| Ruby 4.0 | 130,265 jobs/s | 27,842 jobs/s | **4.7x faster** |
| JRuby | 117,309 jobs/s | 40,539 jobs/s | **2.9x faster** |

## Processing jobs over a network

The same workload with 1 ms of latency added in each direction between
the server and Redis, as on a network where Redis runs on another host.
Every round trip now costs at least 2 ms. Robin's workers share their
round trips, so latency barely slows it down.

| | Robin | Sidekiq | Robin vs Sidekiq |
|---|--:|--:|--:|
| Ruby 3.4 | 100,940 jobs/s | 11,421 jobs/s | **8.8x faster** |
| JRuby | 77,664 jobs/s | 10,296 jobs/s | **7.5x faster** |

## Ruby CPU per job

The CPU time the server process spends per job, measured while processing
the 500,000 jobs. Less CPU per job means fewer servers for the same load.

| | Robin | Sidekiq | Robin vs Sidekiq |
|---|--:|--:|--:|
| Ruby 3.4 (25 threads, 1 ms latency) | 10.0 µs | 65.6 µs | **6.6x faster** |
| JRuby (25 threads) | 20.8 µs | 83.7 µs | **4x faster** |

## Redis CPU per job

The CPU time Redis spends per job while the jobs are processed over a
1 ms network. Redis runs on a single core, so its CPU per job sets how
many jobs per second one Redis can serve, however many servers share it.

| | Robin | Sidekiq | Robin vs Sidekiq |
|---|--:|--:|--:|
| Redis CPU per job | 8.9 µs | 70.9 µs | **8x faster** |

## A cluster of servers on one Redis

Several server processes of 10 threads each draining one backlog through
one Redis. Redis is the shared limit, so this measures how many jobs per
second a cluster can get out of a single Redis.

| | Robin | Sidekiq | Robin vs Sidekiq |
|---|--:|--:|--:|
| 2 processes | 226,825 jobs/s | 37,230 jobs/s | **6.1x faster** |
| 4 processes | 259,966 jobs/s | 54,391 jobs/s | **4.8x faster** |
| 8 processes | 268,845 jobs/s | 83,488 jobs/s | **3.2x faster** |

## Scheduled jobs coming due

100,000 jobs scheduled for the same moment, as with a nightly batch or a
`perform_in` burst. The scheduler has to move each one from the schedule
set onto its queue. This measures the move rate once they're due.

| | Robin | Sidekiq | Robin vs Sidekiq |
|---|--:|--:|--:|
| Move rate | 182,195 jobs/s | 3,003 jobs/s | **61x faster** |

## Retries after an outage

100,000 failed jobs in the retry set, all due at once, as after a
downstream service comes back. This measures the time from the moment
they're due until every one is back on its queue.

| | Robin | Sidekiq | Robin vs Sidekiq |
|---|--:|--:|--:|
| Time until all are queued | 1.40 s | 39.1 s | **28x faster** |

## Jobs with large arguments

No-op jobs that each carry one large string argument, as with jobs that
pass documents or API responses. Robin sends a job's payload to Redis
once; reliable fetch never copies it back.

| | Robin | Sidekiq | Robin vs Sidekiq |
|---|--:|--:|--:|
| 10 KB per job | 61,929 jobs/s | 22,099 jobs/s | **2.8x faster** |
| 100 KB per job | 14,303 jobs/s | 10,015 jobs/s | **43% faster** |

## Picking up a job on a quiet queue

One job pushed every 200 to 500 ms to an otherwise idle server, as with
an app's background jobs outside of a burst. This measures the time from
the push until the job starts, which is what a user waiting on the job
notices. The two systems are on par: both block on Redis waiting for
work, so a job starts as soon as Redis hands it over.

| | Robin | Sidekiq |
|---|--:|--:|
| Ruby 3.4, median | 2.00 ms | 2.08 ms |
| Ruby 3.4, 99th percentile | 5.38 ms | 6.57 ms |
| Ruby 4.0, median | 2.05 ms | 2.10 ms |
| Ruby 4.0, 99th percentile | 5.72 ms | 4.14 ms |
| JRuby, median | 5.80 ms | 7.37 ms |
| JRuby, 99th percentile | 9.80 ms | 11.52 ms |

## Idle servers

50 server processes of 10 threads each with no jobs to run, as in a
cluster sized for peak load. Idle servers still cost Redis something:
fetches that time out, heartbeats and scheduler polls. This measures
what they cost it.

| | Robin | Sidekiq |
|---|--:|--:|
| Redis CPU, per second | 18.4 ms | 16.6 ms |
| Redis commands, per second | 657 | 305 |

Both are small: 50 idle servers of either system use under 2% of one
Redis core. Robin sends about twice as many commands because its
heartbeats are twice as frequent (every 5 s rather than 10 s) and it
runs the cluster's leader chores.

## Surviving a crash

A server running 1,000 jobs of 50 ms on 10 threads is killed with
`kill -9` after 250 have finished, then a fresh one starts. This counts
the jobs that never run. Robin's reliable fetch puts a dead process's jobs
back on their queue; Sidekiq OSS loses the ones that were running.

| | Robin | Sidekiq | Robin vs Sidekiq |
|---|--:|--:|--:|
| Jobs lost | 0 | 10 | **0 jobs lost** |

Robin recovers a dead process's jobs once its heartbeat has expired
(`process_ttl`); in these runs every job had finished 22 s after the
kill. Delivery is at least once: in one of Robin's six runs, two jobs
that finished just as the process was killed, before their
acknowledgments reached Redis, ran a second time rather than being lost.

## What favors Sidekiq

- Sidekiq OSS fetches with a plain `BRPOP`, which takes a job off its
  queue and forgets it. Robin's reliable fetch also keeps each job in an
  in-flight list until it's acknowledged, which is what lets it survive
  a crash. That's more work per job, so the processing figures favor
  Sidekiq on this point.
- Idle, Robin costs Redis slightly more than Sidekiq: about 10% more
  CPU and twice the commands ([idle servers](#idle-servers)).
- The crash comparison is against Sidekiq OSS. Sidekiq Pro's paid
  `super_fetch` also recovers the jobs of a dead process.

## Configuration

- Measured 2026-10-20 on an Apple M1 Max (10 cores), macOS 27.0.1, with a
  dedicated Redis 8.10.2 on localhost TCP, persistence off. The desktop
  was in use (load average 1 to 16).
- Ruby 3.4.11 and 4.0.7 with YJIT; JRuby 10.1.2.0 on Java 27 (Temurin
  27+35), with each process's heap capped at 512 MB (`-Xmx512m`).
  Robin uses its C extension on CRuby and its Java extension on JRuby.
- Sidekiq is the open source edition. On CRuby it uses redis-client's
  C driver (`hiredis-client`), so both systems talk to Redis through C;
  on JRuby, where hiredis doesn't run, it uses the Ruby driver.
- Warmup: before the processing figures are measured, each server first
  runs 200,000 jobs, so YJIT and the JVM have compiled the hot paths.
  The large-argument runs push and run as many jobs again first.
- Both systems use their defaults with logging at WARN. Servers run
  embedded in the benchmark process, with 10 threads unless a row says
  otherwise. Robin's `idle_gc` is off, its default.
- Each measurement runs in fresh processes, and the two systems alternate
  run by run. Processing figures are the median of 3 runs of 500,000 jobs;
  the other figures are medians of 3 runs, idle figures medians of 2
  runs of 30 s, and pickup figures over 600 jobs in 6 runs. The crash
  figures held in both of 2 runs on each Ruby.
- Latency comes from a TCP proxy that delays each chunk by 1 ms each way.
- Scheduled jobs and retries: both schedulers poll every 1 s (Robin's
  `poll_interval`, Sidekiq's `poll_interval_average`).
- Crash: Robin's `process_ttl` is 10 s and `heartbeat_interval` 2 s, so
  recovery comes within the run.
- Tables whose rows don't name a Ruby are from Ruby 3.4. The cluster and
  idle benchmarks fork their servers, so they don't run on JRuby.

Scripts: `bench/compare/` (`run.rb`, `cluster.rb`, `scheduled.rb`,
`payloads.rb`, `pickup.rb`, `idle.rb`, `crash.rb`), runnable as
`rake bench:compare[:<name>]` with `BUNDLE_GEMFILE=bench/compare/Gemfile`.
Raw output of every run: [`bench/results/2026-10-20/`](results/2026-10-20/).
