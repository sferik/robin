# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/extension_api"
require "robin/cli"
require "robin/web"

# Robin's extension API, as EXTENDING.md promises it: what gems that build
# on Robin may call, subclass and override, and what each method takes. A
# patch release keeps every entry working, and a change here belongs in a
# minor release, with the CHANGELOG saying so. (Robin's Rails and Active
# Job API is in test/rails/rails_extension_api_test.rb.)
class ExtensionAPITest < RobinTest
  include ExtensionAPIAssertions

  def self.hook(signature) = ExtensionAPIAssertions.hook(signature)

  API = {
    "Robin.cancel!" => [[:rest], [:key, :ttl]],
    "Robin.config" => [],
    "Robin.configure_embed" => [],
    "Robin.display_class" => [[:req]],
    "Robin.dump_json" => [[:req]],
    "Robin.epoch_seconds" => [[:req]],
    "Robin.load_json" => [[:req]],
    "Robin.logger" => [],
    "Robin.now_ms" => [],
    "Robin.redis" => [],
    "Robin.server?" => [],
    "Robin::Batch" => :class,
    "Robin::Batch#bid" => [],
    "Robin::Batch#cancel!" => [],
    "Robin::Batch#cancelled?" => [],
    "Robin::Batch#config" => [],
    "Robin::Batch#jobs" => [[:key, :atomic]],
    "Robin::Batch#on" => [[:req], [:req], [:opt]],
    "Robin::Batch#parent" => [],
    "Robin::Batch#parent_for_new" => hook([]),
    "Robin::Batch#status" => [],
    "Robin::Batch.current" => [],
    "Robin::Batch.list" => [[:key, :config], [:key, :limit], [:key, :tag]],
    "Robin::Batch.new" => [[:opt], [:key, :config]],
    "Robin::Batch::Hold#closes" => [],
    "Robin::Batch::NoSuchBatch" => :class,
    "Robin::Batch::ServerMiddleware" => :class,
    "Robin::Batch::Status" => :class,
    "Robin::Batch::Status#cancelled?" => [],
    "Robin::Batch::Status#complete?" => [],
    "Robin::Batch::Status#created_at" => [],
    "Robin::Batch::Status#delete!" => [],
    "Robin::Batch::Status#description" => [],
    "Robin::Batch::Status#exists?" => [],
    "Robin::Batch::Status#failed_jobs" => [],
    "Robin::Batch::Status#failures" => [],
    "Robin::Batch::Status#parent_bid" => [],
    "Robin::Batch::Status#pending" => [],
    "Robin::Batch::Status#tags" => [],
    "Robin::Batch::Status#total" => [],
    "Robin::Batch::Status.new" => [[:req], [:key, :config]],
    "Robin::CLI" => :class,
    "Robin::CLI.app_loaders" => [],
    "Robin::CLI.config_file_hooks" => [],
    "Robin::CLI.config_paths" => [],
    "Robin::CLI.new" => [[:opt], [:key, :config]],
    "Robin::Cancellation" => :module,
    "Robin::Cancellation.cancel!" => [[:rest], [:key, :ttl], [:key, :config]],
    "Robin::Capsule" => :class,
    "Robin::Capsule#concurrency" => [],
    "Robin::Capsule#strict?" => [],
    "Robin::Capsule.current" => [],
    "Robin::Client" => :class,
    "Robin::Client#normalize" => [[:req]],
    "Robin::Client#push" => [[:req]],
    "Robin::Client#push_bulk" => [[:req]],
    "Robin::Client.interceptor" => [],
    "Robin::Client.new" => [[:key, :config], [:key, :pool], [:key, :chain]],
    "Robin::Client.timestamp_ms" => [[:req], [:opt]],
    "Robin::Client.via" => [[:req]],
    "Robin::Config" => :class,
    "Robin::Config#backtrace_cleaner=" => [[:req]],
    "Robin::Config#batch_status_class" => [],
    "Robin::Config#batch_status_class=" => [[:req]],
    "Robin::Config#capsule" => [[:req]],
    "Robin::Config#client_middleware" => [],
    "Robin::Config#concurrency" => [],
    "Robin::Config#concurrency=" => [[:req]],
    "Robin::Config#dead_max_jobs=" => [[:req]],
    "Robin::Config#dead_timeout=" => [[:req]],
    "Robin::Config#death_handlers" => [],
    "Robin::Config#encryption_keys" => [],
    "Robin::Config#encryption_keys=" => [[:req]],
    "Robin::Config#environment=" => [[:req]],
    "Robin::Config#event_handlers" => [],
    "Robin::Config#handle_exception" => [[:req], [:opt]],
    "Robin::Config#internal_key_prefix" => [],
    "Robin::Config#internal_key_prefix=" => [[:req]],
    "Robin::Config#job_timestamp" => [[:req]],
    "Robin::Config#job_timestamps" => [],
    "Robin::Config#job_timestamps=" => [[:req]],
    "Robin::Config#key" => [[:rest]],
    "Robin::Config#key_prefix" => [],
    "Robin::Config#key_prefix=" => [[:req]],
    "Robin::Config#labels=" => [[:req]],
    "Robin::Config#leader_candidate" => [],
    "Robin::Config#leader_candidate=" => [[:req]],
    "Robin::Config#lifecycle" => [],
    "Robin::Config#logger" => [],
    "Robin::Config#logger=" => [[:req]],
    "Robin::Config#max_iteration_runtime=" => [[:req]],
    "Robin::Config#max_retries" => [],
    "Robin::Config#max_retries=" => [[:req]],
    "Robin::Config#memory_limit_mb" => [],
    "Robin::Config#memory_limit_mb=" => [[:req]],
    "Robin::Config#metrics_retention_days" => [],
    "Robin::Config#metrics_retention_days=" => [[:req]],
    "Robin::Config#on" => [[:req]],
    "Robin::Config#periodic" => [],
    "Robin::Config#poll_interval" => [],
    "Robin::Config#poll_interval=" => [[:req]],
    "Robin::Config#process_key" => [[:req]],
    "Robin::Config#push_deferrer" => [],
    "Robin::Config#push_deferrer=" => [[:req]],
    "Robin::Config#queues" => [],
    "Robin::Config#queues=" => [[:req]],
    "Robin::Config#redis" => [],
    "Robin::Config#redis=" => [[:req]],
    "Robin::Config#redis_pool" => [],
    "Robin::Config#redis_pool=" => [[:req]],
    "Robin::Config#reliable_push" => [],
    "Robin::Config#reliable_push=" => [[:req]],
    "Robin::Config#retry_backoff" => [],
    "Robin::Config#server_middleware" => [],
    "Robin::Config#statsd" => [],
    "Robin::Config#statsd=" => [[:req]],
    "Robin::Config#strict_args" => [],
    "Robin::Config#strict_args=" => [[:req]],
    "Robin::Config#tag=" => [[:req]],
    "Robin::Config#timeout=" => [[:req]],
    "Robin::Config.new" => [],
    "Robin::Context" => :module,
    "Robin::Context.current" => [],
    "Robin::Context.with" => [[:req]],
    "Robin::Cron" => :class,
    "Robin::Cron#description" => [],
    "Robin::Cron#match?" => [[:req]],
    "Robin::Cron#next_time" => [[:opt]],
    "Robin::Cron#previous_time" => [[:opt]],
    "Robin::Cron#to_s" => [],
    "Robin::Cron.new" => [[:req], [:key, :tz]],
    "Robin::Cron::Every" => :class,
    "Robin::Cron::Every#match?" => [[:req]],
    "Robin::Cron::Every#next_time" => [[:opt]],
    "Robin::Cron::Every#previous_time" => [[:opt]],
    "Robin::Cron::Every.new" => [[:req]],
    "Robin::Cron::ParseError" => :class,
    "Robin::Cron::Zone::Local#label" => [],
    "Robin::DeadSet" => :class,
    "Robin::DeadSet#kill" => [[:req], [:key, :ack], [:key, :notify]],
    "Robin::DeadSet.new" => [[:key, :config]],
    "Robin::Deploy" => :module,
    "Robin::Deploy.list" => [[:keyreq, :from], [:key, :to], [:key, :config]],
    "Robin::Deploy.mark!" => [[:opt], [:key, :at], [:key, :config]],
    "Robin::Discard" => :class,
    "Robin::IterableJob" => :module,
    "Robin::IterableJob#active_record_batches_enumerator" => [[:req], [:keyreq, :cursor], [:key, :batch_size]],
    "Robin::Job" => :module,
    "Robin::Job#bid" => [],
    "Robin::Job#cancelled?" => [],
    "Robin::Job#jid" => [],
    "Robin::Job#payload" => [],
    "Robin::Job.inclusion_checks" => [],
    "Robin::Job::ClassMethods#perform_in" => [[:req], [:rest]],
    "Robin::Job::ClassMethods#robin_options" => [[:opt]],
    "Robin::Job::ClassMethods#robin_retries_exhausted" => [],
    "Robin::Job::ClassMethods#robin_retries_exhausted_block" => [],
    "Robin::Job::ClassMethods#robin_retry_in" => [],
    "Robin::Job::DEFAULT_OPTIONS" => :constant,
    "Robin::JobLogger::Formatter" => :class,
    "Robin::JobLogger::JSONFormatter" => :class,
    "Robin::JobRecord" => :class,
    "Robin::JobRecord#[]" => [[:req]],
    "Robin::JobRecord#created_at" => [],
    "Robin::JobRecord#enqueued_at" => [],
    "Robin::JobRecord#jid" => [],
    "Robin::JobRecord.new" => [[:req], [:opt], [:key, :config]],
    "Robin::JobSet" => :class,
    "Robin::JobSet#config" => [],
    "Robin::JobSet#drain" => [],
    "Robin::JobSet#drain_pages" => [],
    "Robin::JobSet#each" => [[:key, :reverse]],
    "Robin::JobSet#entry" => hook([[:req], [:req]]),
    "Robin::JobSet#fetch" => [[:req], [:opt]],
    "Robin::JobSet#find_job" => [[:req]],
    "Robin::JobSet#kill_entries" => [[:req]],
    "Robin::JobSet#retry_entries" => [[:req]],
    "Robin::JobSet#scan" => [[:req], [:key, :limit]],
    "Robin::JobSet.new" => [[:req], [:key, :config]],
    "Robin::Leader" => :class,
    "Robin::Leader.leader?" => [[:opt]],
    "Robin::Limiter" => :module,
    "Robin::Limiter.bucket" => [[:req], [:req], [:req], [:keyrest]],
    "Robin::Limiter.concurrent" => [[:req], [:req], [:key, :wait_timeout], [:key, :lock_timeout], [:keyrest]],
    "Robin::Limiter.leaky" => [[:req], [:req], [:req], [:keyrest]],
    "Robin::Limiter.points" => [[:req], [:req], [:req], [:keyrest]],
    "Robin::Limiter.unlimited" => [[:opt]],
    "Robin::Limiter.via" => [[:req]],
    "Robin::Limiter.window" => [[:req], [:req], [:req], [:keyrest]],
    "Robin::Limiter::OverLimit" => :class,
    "Robin::Limiter::OverLimit.new" => [[:req], [:opt]],
    "Robin::Middleware::Chain" => :class,
    "Robin::Middleware::Chain#add" => [[:req], [:rest]],
    "Robin::Middleware::Chain#clear" => [],
    "Robin::Middleware::Chain#insert_after" => [[:req], [:req], [:rest]],
    "Robin::Middleware::Chain#insert_before" => [[:req], [:req], [:rest]],
    "Robin::Middleware::Chain#invoke" => [[:rest]],
    "Robin::Middleware::Chain#prepend" => [[:req], [:rest]],
    "Robin::Middleware::Chain#remove" => [[:req]],
    "Robin::Middleware::Chain.new" => [[:req]],
    "Robin::Middleware::ConfigAware" => :module,
    "Robin::Middleware::Stateless" => :module,
    "Robin::Periodic" => :module,
    "Robin::Periodic.list" => [[:key, :config], [:key, :history]],
    "Robin::Periodic.verify!" => [[:opt]],
    "Robin::Periodic::Invalid" => :class,
    "Robin::Periodic::Registry#entries" => [],
    "Robin::Periodic::Registry#register" => [[:req], [:req], [:key, :queue], [:key, :args], [:key, :tz], [:key, :description], [:keyrest]],
    "Robin::ProcessRecord" => :class,
    "Robin::ProcessRecord#[]" => [[:req]],
    "Robin::ProcessRecord#quiet!" => [],
    "Robin::ProcessRecord#quiet?" => [],
    "Robin::ProcessRecord#stop!" => [],
    "Robin::ProcessRecord.new" => [[:req], [:req], [:key, :config]],
    "Robin::ProcessSet" => :class,
    "Robin::ProcessSet#each" => [],
    "Robin::ProcessSet#leader" => [],
    "Robin::ProcessSet#record" => hook([[:req], [:req]]),
    "Robin::ProcessSet#total_rss_kb" => [],
    "Robin::ProcessSet.new" => [[:key, :config]],
    "Robin::Queue" => :class,
    "Robin::Queue#each" => [],
    "Robin::Queue#record" => hook([[:req]]),
    "Robin::Queue.latency_of" => [[:req], [:opt]],
    "Robin::Redis::Connection" => :class,
    "Robin::Redis::Connection#blocking_call" => [[:req], [:rest]],
    "Robin::Redis::Connection#call" => [[:rest]],
    "Robin::Redis::Connection#close" => [],
    "Robin::Redis::Connection#multi" => [],
    "Robin::Redis::Connection#pipelined" => [[:key, :timeout]],
    "Robin::Redis::Pipeline#call" => [[:rest]],
    "Robin::Redis::Pipeline#commands" => [],
    "Robin::Redis::Pool" => :class,
    "Robin::Redis::Pool#shutdown" => [],
    "Robin::Redis::Pool#with" => [],
    "Robin::Retrier" => :class,
    "Robin::Retrier#config" => [],
    "Robin::Retrier#max_retries" => [[:req]],
    "Robin::Shutdown" => :class,
    "Robin::SortedEntry" => :class,
    "Robin::SortedEntry#at" => [],
    "Robin::SortedEntry#queued_item" => [],
    "Robin::SortedEntry#remove_and" => hook([]),
    "Robin::SortedEntry#score" => [],
    "Robin::SortedEntry.new" => [[:req], [:req], [:req]],
    "Robin::Stats" => :class,
    "Robin::Stats#history" => [[:key, :days], [:key, :now]],
    "Robin::Stats#reset" => [[:rest]],
    "Robin::Stats.new" => [[:key, :config]],
    "Robin::Unique" => :module,
    "Robin::Unique.digest" => [[:req], [:req], [:req]],
    "Robin::Unique.lock_key" => [[:req], [:req]],
    "Robin::Web" => :class,
    "Robin::Web.assets_path" => [],
    "Robin::Web.authorize" => [],
    "Robin::Web.call" => [[:req]],
    "Robin::Web.clusters" => [],
    "Robin::Web.clusters=" => [[:req]],
    "Robin::Web.job_info" => [[:req]],
    "Robin::Web.register" => [[:req]],
    "Robin::WorkSet" => :class,
    "Robin::WorkSet#each" => [],
    "Robin::WorkSet#size" => []
  }.freeze

  def test_the_extension_api_is_unchanged
    assert_extension_api API
  end

  def test_a_method_may_gain_optional_arguments
    assert_true accepts_every_call?([[:req]], [[:req], [:opt]])
    assert_true accepts_every_call?([[:req]], [[:rest]])
    assert_true accepts_every_call?([[:key, :a]], [[:key, :a], [:key, :b]])
    assert_true accepts_every_call?([[:keyreq, :a]], [[:key, :a]])
    assert_true accepts_every_call?([[:key, :a]], [[:keyrest]])
  end

  def test_a_method_may_not_lose_arguments_or_gain_required_ones
    assert_false accepts_every_call?([[:req]], [[:req], [:req]])
    assert_false accepts_every_call?([[:req], [:opt]], [[:req]])
    assert_false accepts_every_call?([[:rest]], [[:req], [:opt]])
    assert_false accepts_every_call?([[:key, :a]], [])
    assert_false accepts_every_call?([[:key, :a]], [[:keyreq, :a]])
    assert_false accepts_every_call?([], [[:keyreq, :b]])
    assert_false accepts_every_call?([[:keyrest]], [[:key, :a]])
  end

  def test_a_changed_entry_is_reported
    assert_equal "Robin::Config#key_prefix: took [[:req]], now takes []", extension_api_problem("Robin::Config#key_prefix", [[:req]])
    assert_equal "Robin::Missing: is gone", extension_api_problem("Robin::Missing", :class)
    assert_equal "Robin::Config: was a module, is now a class", extension_api_problem("Robin::Config", :module)
    assert_equal "Robin::Config#nope: not public", extension_api_problem("Robin::Config#nope", [])
    assert_equal "Robin::JobSet#nope: not defined", extension_api_problem("Robin::JobSet#nope", self.class.hook([]))
    assert_equal "Robin::Nope.it: Robin::Nope is gone", extension_api_problem("Robin::Nope.it", [])
  end

  # Subclasses get their own kind of record from the methods Robin reads
  # them with, so a subclass's own readers and writers apply to them.

  class TaggedEntry < Robin::SortedEntry
    def queued_item = super.merge("tagged" => true)
  end

  class TaggedSet < Robin::JobSet
    private

    def entry(score, value) = TaggedEntry.new(self, score, value)
  end

  def test_a_job_set_builds_its_entries_with_entry
    Robin::Client.push("class" => "Plain", "args" => [1], "at" => Time.now.to_f + 60)
    set = TaggedSet.new("schedule", config: config)
    jid = set.first.jid

    assert_instance_of TaggedEntry, set.first
    assert_instance_of TaggedEntry, set.find_job(jid)
    assert_instance_of TaggedEntry, set.scan("Plain").first
  end

  def test_an_entry_queues_what_queued_item_says
    Robin::Client.push("class" => "Plain", "args" => [1], "at" => Time.now.to_f + 60)
    TaggedSet.new("schedule", config: config).first.add_to_queue

    assert_true Robin.load_json(redis("LINDEX", config.key("queue", "default"), 0)).fetch("tagged")
  end

  class TaggedRecord < Robin::JobRecord; end

  class TaggedQueue < Robin::Queue
    private

    def record(raw) = TaggedRecord.new(raw, name, config: @config)
  end

  def test_a_queue_builds_its_jobs_with_record
    jid = Robin::Client.push("class" => "Plain", "args" => [1])
    queue = TaggedQueue.new("default", config: config)

    assert_instance_of TaggedRecord, queue.first
    assert_instance_of TaggedRecord, queue.find_job(jid)
  end

  class TaggedProcess < Robin::ProcessRecord; end

  class TaggedProcessSet < Robin::ProcessSet
    private

    def record(identity, data) = TaggedProcess.new(identity, data, config: @config)
  end

  def test_a_process_set_builds_its_processes_with_record
    redis("SADD", config.key("processes"), "p1")
    redis("HSET", config.process_key("p1"), "info", Robin.dump_json({"hostname" => "h"}), "beat", "1700000000")

    assert_instance_of TaggedProcess, TaggedProcessSet.new(config: config).first
  end

  def test_a_new_batch_takes_the_parent_parent_for_new_names
    parent = Robin::Batch.new
    parent.jobs { Robin::Client.push("class" => "Plain", "args" => [1]) }
    adopted = Class.new(Robin::Batch) { define_method(:parent_for_new) { parent.bid } }.new
    adopted.jobs { Robin::Client.push("class" => "Plain", "args" => [2]) }

    assert_equal parent.bid, adopted.parent_bid
    assert_equal parent.bid, Robin::Batch::Status.new(adopted.bid).parent_bid
  end
end
