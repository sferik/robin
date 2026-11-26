# Extending Robin

The [README](README.md) documents what an application uses. This
document is for gems that build on Robin: adapters, compatibility
layers, dashboard pages and other plugins. It lists the rest of what they
may rely on, and what Robin promises about it.

## What Robin promises

Robin's public API is what the README documents and what this document
lists. From Robin 0.1.3:

- **A patch release** (0.1.4, say) never removes any of it or changes it
  in a way that breaks code using it.
- **A minor release** (0.2.0) may, and the CHANGELOG names each such
  change under Changed or Removed.
- **From 1.0**, only a major release may.

So a gem that uses only the public API can depend on
`">= 0.1.3", "< 0.2"` and take Robin's patch releases as they come.

A compatible change adds something: a class, a method, an optional
argument, a keyword with a default. Removing or renaming any of these
breaks code, and so does a new required argument, one fewer argument, a
different kind of return value, or a hook Robin no longer calls where
this document says it does.

Everything else is internal and may change in any release: methods and
constants listed nowhere here or in the README, private methods not
listed as hooks below, and instance variables.

Robin may add methods to any of its classes in any release. A module that
adds methods to one of them (with `include` or `prepend`) should give
them names Robin is unlikely to use, or call `super` where it replaces
one of Robin's.

The tests hold Robin to this: `test/extension_api_test.rb` and
`test/rails/rails_extension_api_test.rb` pin each entry in the
[reference](#reference) below, what it is and the arguments it takes,
and fail when an entry stops taking a call it took. Robin's other tests
check that it calls the hooks below where it says it does.

## Registries

Robin consults these, so a gem can add to them as it loads.

- `Robin::CLI.app_loaders`: callables the `robin` command tries in
  order with the application directory, before it boots anything. The
  first that returns truthy has loaded the app. Otherwise the directory's
  `app.rb`, if any, is required. A loader that prepares something and
  returns falsy leaves the boot to the next one.
- `Robin::CLI.config_paths`: the config files the command reads without
  `-C`, the first that exists.
- `Robin::CLI.config_file_hooks`: callables run with the config file's
  settings (a Hash with Symbol keys, the environment's section merged
  in) and the config, once the command's own options are applied, so a
  gem can apply settings of its own.
- `Robin::Job.inclusion_checks`: callables run with each class about to
  include `Robin::Job`. One that raises rejects the class.
- `Robin::Client.interceptor`: a callable that may take over delivering
  pushed jobs, returning truthy when it did.
- `config.queue_filter`: a callable run with each fetch's capsule and
  its queues, in the order they'd be checked, that returns the queues to
  fetch from (to leave one out for now, say). Jobs a fetch already took
  for the capsule's other workers still run.
- `config.push_deferrer`: a callable that may defer delivering pushed
  jobs (until a transaction commits, say), returning truthy when it took
  over delivery.
- `config.event_handlers`: callables run with each of Robin's events
  (`Robin::Events` lists them).
- `config.on` and `config.lifecycle`: callbacks run at a server's
  lifecycle events.
- `config.batch_status_class`: the class of the status batch callbacks
  get, which may be a subclass of `Robin::Batch::Status` taking
  `(bid, config:)`.
- `config.retry_backoff`: a callable that replaces the retry backoff.
- `config.client_middleware` and `config.server_middleware`: the
  middleware chains (`Robin::Middleware::Chain`). A middleware including
  `Robin::Middleware::ConfigAware` gets the config, and one including
  `Robin::Middleware::Stateless` is built once and shared.
- `Robin::Web.register`, `.job_info`, `.authorize`, `.clusters` and
  `.assets_path`: the dashboard's pages, job rows, authorization, Redis
  clusters and where browsers load its assets from.

## Subclasses and overrides

These classes may be subclassed: `Robin::Stats`, `Robin::Queue`,
`Robin::JobRecord`, `Robin::SortedEntry`, `Robin::JobSet` (and its
`ScheduledSet`, `RetrySet` and `DeadSet`), `Robin::ProcessRecord`,
`Robin::ProcessSet`, `Robin::WorkSet`, `Robin::Batch`,
`Robin::Batch::Status` and `ActiveJob::QueueAdapters::RobinAdapter`.

Robin builds and decides things through these methods, so a subclass
that overrides one (or a module prepended to the class) changes what
Robin does. Those marked private stay private, and a subclass may call
them.

| Method | Robin calls it |
|---|---|
| `Robin::JobSet#entry(score, value)` (private) | for every entry it reads from the set, so a subclass's sets hold its own kind of entry |
| `Robin::SortedEntry#queued_item` | for the job `#add_to_queue` pushes |
| `Robin::Queue#record(raw)` (private) | for every job it reads from the queue |
| `Robin::ProcessSet#record(identity, data)` (private) | for every process it reads |
| `Robin::Batch#parent_for_new` (private) | for the parent of a batch it creates |
| `ActiveJob::QueueAdapters::RobinAdapter#payload(job, timestamp)` (private) | for the job hash of each Active Job job it enqueues |
| `Robin::Retrier#max_retries(payload)` | for how many times a failed job may retry |
| `Robin::Config#handle_exception(error, context = {})` | for every error Robin reports, which it hands to the error handlers |

`Robin::SortedEntry#remove_and` (private) is for subclasses to call:
it removes the entry from its set and, if this call removed it, runs
the block with the job (without its `at` and `enqueued_at`) and returns
true. Otherwise it returns false and runs nothing, so two processes
acting on one entry never both act on it.

A job's `#payload` is the job hash it runs, unless its class has a
`payload` of its own (as jobs written for another library may). Robin
reads and sets the job hash with `#robin_payload` (and
`#robin_payload=`), which a gem should use too.

## Reference

Everything in the extension API, by class, including what the README
documents. Where a class is listed without methods, the class itself is
the API (to subclass, rescue, include or pass to Robin).

- `ActiveJob::QueueAdapters::RobinAdapter`: `#payload(job, timestamp)` (private)
- `Robin`: `.cancel!(*jids, ttl: …)`, `.config`, `.configure_embed { … }`, `.display_class(payload)`, `.dump_json(obj)`, `.epoch_seconds(ms)`, `.load_json(str)`, `.logger`, `.now_ms`, `.redis { … }`, `.server?`
- `Robin::ActiveJob::Options` (module)
- `Robin::ActiveJob::Options::ClassMethods`: `#robin_options(opts = …)`
- `Robin::ActiveJob::Wrapper` (class)
- `Robin::Batch` (class): `.current`, `.list(config: …, limit: …, tag: …)`, `.new(bid = …, config: …)`, `#bid`, `#cancel!`, `#cancelled?`, `#config`, `#jobs(atomic: …)`, `#on(event, target, options = …)`, `#parent_for_new` (private), `#parent`, `#status`
- `Robin::Batch::Hold`: `#closes`
- `Robin::Batch::NoSuchBatch` (class)
- `Robin::Batch::ServerMiddleware` (class)
- `Robin::Batch::Status` (class): `.new(bid, config: …)`, `#cancelled?`, `#complete?`, `#created_at`, `#delete!`, `#description`, `#exists?`, `#failed_jobs`, `#failures`, `#parent_bid`, `#pending`, `#tags`, `#total`
- `Robin::CLI` (class): `.app_loaders`, `.config_file_hooks`, `.config_paths`, `.new(argv = …, config: …)`
- `Robin::Cancellation` (module): `.cancel!(*jids, ttl: …, config: …)`
- `Robin::Capsule` (class): `.current`, `#concurrency`, `#strict?`
- `Robin::Client` (class): `.interceptor`, `.new(config: …, pool: …, chain: …)`, `.timestamp_ms(value, now = …)`, `.timestamp_seconds(value, now = …)`, `.via(pool)`, `#normalize(item)`, `#push(item)`, `#push_bulk(item)`
- `Robin::Config` (class): `.new`, `#backtrace_cleaner = value`, `#batch_status_class = value`, `#batch_status_class`, `#capsule(name)`, `#client_middleware`, `#concurrency = n`, `#concurrency`, `#dead_max_jobs = value`, `#dead_timeout = value`, `#death_handlers`, `#encryption_keys = value`, `#encryption_keys`, `#environment = value`, `#event_handlers`, `#handle_exception(ex, context = …)`, `#internal_key_prefix = value`, `#internal_key_prefix`, `#job_timestamp(ms)`, `#job_timestamps = unit`, `#job_timestamps`, `#key(*parts)`, `#key_prefix = value`, `#key_prefix`, `#labels = value`, `#leader_candidate = value`, `#leader_candidate`, `#lifecycle`, `#logger = value`, `#logger`, `#max_iteration_runtime = value`, `#max_retries = value`, `#max_retries`, `#memory_limit_mb = value`, `#memory_limit_mb`, `#metrics_retention_days = value`, `#metrics_retention_days`, `#on(event) { … }`, `#periodic { … }`, `#poll_interval = value`, `#poll_interval`, `#process_key(identity)`, `#push_deferrer = value`, `#push_deferrer`, `#queues = list`, `#queues`, `#redis = options`, `#redis { … }`, `#redis_pool = value`, `#redis_pool`, `#reliable_push = value`, `#reliable_push`, `#retry_backoff`, `#server_middleware`, `#statsd = value`, `#statsd`, `#strict_args = value`, `#strict_args`, `#tag = value`, `#timeout = value`
- `Robin::Context` (module): `.current`, `.with(hash)`
- `Robin::Cron` (class): `.new(expression, tz: …)`, `#description`, `#match?(time)`, `#next_time(from = …)`, `#previous_time(from = …)`, `#to_s`
- `Robin::Cron::Every` (class): `.new(expression)`, `#match?(time)`, `#next_time(from = …)`, `#previous_time(from = …)`
- `Robin::Cron::ParseError` (class)
- `Robin::Cron::Zone::Local`: `#label`
- `Robin::DeadSet` (class): `.new(config: …)`, `#kill(raw, ack: …, notify: …)`
- `Robin::Deploy` (module): `.list(from:, to: …, config: …)`, `.mark!(label = …, at: …, config: …)`
- `Robin::Discard` (class)
- `Robin::IterableJob` (module): `#active_record_batches_enumerator(relation, cursor:, batch_size: …)`
- `Robin::Job` (module): `.inclusion_checks`, `#bid`, `#cancelled?`, `#jid`, `#payload`, `#robin_payload`
- `Robin::Job::ClassMethods`: `#perform_in(interval, *args)`, `#robin_options(opts = …)`, `#robin_retries_exhausted { … }`, `#robin_retries_exhausted_block`, `#robin_retry_in { … }`
- `Robin::Job::DEFAULT_OPTIONS` (constant)
- `Robin::JobLogger::Formatter` (class)
- `Robin::JobLogger::JSONFormatter` (class)
- `Robin::JobRecord` (class): `.new(value, queue = …, config: …)`, `#[](key)`, `#created_at`, `#enqueued_at`, `#jid`
- `Robin::JobSet` (class): `.new(name, config: …)`, `#config`, `#drain { … }`, `#drain_pages`, `#each(reverse: …)`, `#entry(score, value)` (private), `#fetch(score, jid = …)`, `#find_job(jid)`, `#kill_entries(entries)`, `#retry_entries(entries)`, `#scan(term, limit: …)`
- `Robin::Leader` (class): `.leader?(config = …)`
- `Robin::Limiter` (module): `.bucket(name, count, interval, **options)`, `.concurrent(name, size, wait_timeout: …, lock_timeout: …, **options)`, `.leaky(name, size, interval, **options)`, `.points(name, points, interval, **options)`, `.unlimited(name = …)`, `.via(pool)`, `.window(name, count, interval, **options)`
- `Robin::Limiter::OverLimit` (class): `.new(limiter, retry_after = …)`
- `Robin::Middleware::Chain` (class): `.new(config)`, `#add(klass, *args)`, `#clear`, `#entries`, `#insert_after(target, klass, *args)`, `#insert_before(target, klass, *args)`, `#invoke(*args) { … }`, `#prepend(klass, *args)`, `#remove(klass)`
- `Robin::Middleware::ConfigAware` (module)
- `Robin::Middleware::Entry` (class): `#args`, `#klass`
- `Robin::Middleware::Stateless` (module)
- `Robin::Periodic` (module): `.list(config: …, history: …)`, `.verify!(config = …) { … }`
- `Robin::Periodic::Invalid` (class)
- `Robin::Periodic::Registry`: `#entries`, `#register(cron, klass, queue: …, args: …, tz: …, description: …, **options)`
- `Robin::ProcessRecord` (class): `.new(identity, data, config: …)`, `#[](key)`, `#quiet!`, `#quiet?`, `#stop!`
- `Robin::ProcessSet` (class): `.new(config: …)`, `#each { … }`, `#leader`, `#record(identity, data)` (private), `#total_rss_kb`
- `Robin::Queue` (class): `.latency_of(raw, now = …)`, `#each`, `#record(raw)` (private)
- `Robin::Rails::CurrentAttributes` (module): `.install(config, names)`
- `Robin::Rails::TransactionalPush` (module)
- `Robin::Redis::Connection` (class): `#blocking_call(timeout, *args)`, `#call(*args)`, `#close`, `#multi`, `#pipelined(timeout: …)`
- `Robin::Redis::Pipeline`: `#call(*args)`, `#commands`
- `Robin::Redis::Pool` (class): `#shutdown`, `#with`
- `Robin::Retrier` (class): `#config`, `#max_retries(payload)`
- `Robin::Shutdown` (class)
- `Robin::SortedEntry` (class): `.new(parent, score, value)`, `#at`, `#queued_item`, `#remove_and` (private), `#score`
- `Robin::Stats` (class): `.new(config: …)`, `#history(days: …, now: …)`, `#reset(*names)`
- `Robin::Unique` (module): `.digest(klass_name, queue, args)`, `.lock_key(config, digest)`
- `Robin::Web` (class): `.assets_path`, `.authorize { … }`, `.call(env)`, `.clusters = hash`, `.clusters`, `.job_info(label) { … }`, `.register(extension)`
- `Robin::WorkSet` (class): `#each`, `#size`
