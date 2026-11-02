# frozen_string_literal: true

module Robin
  class Web
    # JSON endpoint handlers. One instance per request.
    class API
      SETS = JobLocator::SETS
      SET_ACTIONS = {"retry" => :retry, "delete" => :delete, "kill" => :kill}.freeze #: Hash[String, :retry | :delete | :kill]
      SIGNALS = {"quiet" => :quiet!, "stop" => :stop!, "dump" => :dump_threads}.freeze #: Hash[String, :quiet! | :stop! | :dump_threads]
      MAX_CONCURRENCY = 1000

      # Every page is built in; kept in the session for older UIs.
      FEATURES = {"batches" => true, "limiters" => true, "cron" => true}.freeze

      # Integer query parameters: name => [default, minimum, maximum].
      INT_PARAMS = {
        "days" => [30, 1, 180], "minutes" => [60, 5, 480], "hours" => [24 * 7, 1, 24 * 90],
        "points" => [60, 5, 24 * 90], "page" => [1, 1, 1_000_000], "per_page" => [25, 1, 200],
        "limit" => [100, 1, 1000]
      }.freeze #: Hash[String, [Integer, Integer, Integer]]

      INFO_FIELDS = %w[redis_version redis_mode os uptime_in_seconds connected_clients used_memory_human
        used_memory_peak_human maxmemory_human maxmemory_policy mem_fragmentation_ratio total_commands_processed
        instantaneous_ops_per_sec keyspace_hits keyspace_misses role tcp_port].freeze

      # Searches return at most this many matches.
      SEARCH_LIMIT = 1000

      # Links job_info rows may have: http(s) URLs and paths on this host.
      INFO_LINK = %r{\A(?:https?://|/(?!/))}i

      # Fields describing a failure, dropped when a job is edited and re-run.
      FAILURE_FIELDS = %w[at enqueued_at error_class error_message error_backtrace failed_at retried_at retry_count].freeze

      def self.json(status, body)
        [status, {"content-type" => "application/json; charset=utf-8", "cache-control" => "no-store"}, [Robin.dump_json(body)]]
      end

      def self.parse_info(raw)
        raw.each_line.each_with_object({}) do |line, info|
          key, colon, value = line.chomp.partition(":")
          info[key] = value unless colon.empty?
        end
      end

      attr_reader :config

      def initialize(env, request, cluster, params)
        @env = env
        @request = request
        @cluster = cluster
        @config = Web.clusters.fetch(cluster)
        @params = params
      end

      def authorize!(action, resource)
        return if Permissions.allowed?(@env, action, resource)

        raise Router::HttpError.new(403, "You don't have permission to #{Permissions::ACTIONS.fetch(action).downcase}")
      end

      # -- session & overview ---------------------------------------------

      def session
        ok(
          {"title" => Web.title, "brand_color" => Web.brand_color, "version" => VERSION,
           "read_only" => !!Web.read_only, "permissions" => Permissions.for(@env),
           "clusters" => Web.clusters.keys, "cluster" => @cluster,
           "features" => FEATURES, "stream_interval" => Web.stream_interval,
           "live_updates" => Web.live_updates, "extensions" => Web.extensions.values.map(&:to_h)}
        )
      end

      def dashboard
        stats = Stats.new(config: config)
        ok(
          {"stats" => stats.to_h, "queues" => queue_rows(stats.queues),
           "history" => stats.history(days: int_param("days")),
           "realtime" => Metrics::Query.new(config).recent(minutes: int_param("minutes")).fetch("series"),
           "leader" => Leader.current(config)}
        )
      end

      def stats
        ok(live_stats)
      end

      # Server-sent events: a "stats" event now and every
      # Web.stream_interval seconds after, for Web.stream_lifetime seconds
      # (the browser then reconnects).
      def stream
        interval = Web.stream_interval
        repeats = (Web.stream_lifetime / interval).floor
        body = Enumerator.new do |out|
          out << "retry: 3000\n\n" << stats_event
          repeats.times do
            sleep interval
            out << stats_event
          end
        end
        [200, {"content-type" => "text/event-stream", "cache-control" => "no-cache", "x-accel-buffering" => "no"}, body]
      end

      def live_stats
        stats = Stats.new(config: config)
        {"stats" => stats.to_h, "queues" => stats.queues, "at" => Robin.now_ms}
      end

      def info
        raw, url = config.redis { |c| [c.call("INFO"), c.id] }
        ok(
          {"redis" => API.parse_info(raw).slice(*INFO_FIELDS), "redis_url" => url,
           "robin" => {"version" => VERSION, "ruby" => RUBY_DESCRIPTION, "key_prefix" => config.key_prefix,
                       "max_retries" => config.max_retries, "dead_max_jobs" => config.dead_max_jobs,
                       "dead_timeout_days" => config.dead_timeout / 86_400, "native_resp" => !Redis::PARSER.eql?(Redis::RESP)},
           "processes" => ProcessSet.new(config: config).size, "leader" => Leader.current(config)}
        )
      end

      # -- queues ---------------------------------------------------------

      def queues
        ok({"queues" => queue_rows(Stats.new(config: config).queues)})
      end

      def queue
        q = named_queue
        page, per = paging
        info = q.to_h
        ok({"queue" => info, "page" => page, "per_page" => per, "total" => info.fetch("size"),
          "jobs" => q.page(page, per_page: per).map { |j| job_json(j) }})
      end

      def pause_queue
        named_queue.pause!
        ok({"paused" => true})
      end

      def unpause_queue
        named_queue.unpause!
        ok({"paused" => false})
      end

      def clear_queue
        named_queue.clear
        ok({"cleared" => true})
      end

      # Deletes the given jids, walking the queue only until all are found,
      # then deleting them together.
      def delete_queue_jobs
        wanted = Array(body["jids"]).to_set #: Set[String]
        queue = named_queue
        found = [] #: Array[JobRecord]
        queue.each do |job|
          found << job if wanted.delete?(job.jid)
          break if wanted.empty?
        end
        ok({"deleted" => queue.delete_jobs(found)})
      end

      # Deletes every job of one class, wherever it is in the queue.
      def delete_queue_class
        klass = body["class"]
        raise Router::HttpError.new(400, "A class name is required") unless klass.instance_of?(String) && !klass.empty?

        ok({"deleted" => named_queue.delete_by_class(klass)})
      end

      # -- processes ------------------------------------------------------

      def busy
        work = WorkSet.new(config: config).map do |identity, tid, w|
          [identity, tid, w, JobRecord.new(w.fetch("payload"), w.fetch("queue"))]
        end #: Array[[String, String, Hash[String, json], JobRecord]]
        progress = Progress.fetch_many(work.map { |_identity, _tid, _w, record| record.jid }, config: config)
        rows = work.map do |identity, tid, w, record|
          {"identity" => identity, "thread" => tid, "queue" => w.fetch("queue"), "run_at" => w.fetch("run_at"),
           "job" => job_json(record), "progress" => progress[record.jid]}
        end
        ok({"processes" => ProcessSet.new(config: config).map(&:to_h), "work" => rows, "leader" => Leader.current(config)})
      end

      def signal_process
        signal = signal_method
        live_process.public_send(signal)
        ok({"signalled" => 1})
      end

      # Body: {"concurrency": workers, "capsule": name (default "default")}.
      def resize_process
        process = live_process
        count = body["concurrency"]
        unless count.instance_of?(Integer) && count.between?(1, MAX_CONCURRENCY)
          raise Router::HttpError.new(400, "concurrency must be a whole number from 1 to #{MAX_CONCURRENCY}")
        end

        capsule = body.fetch("capsule", "default")
        unless process["capsules"]&.key?(capsule)
          raise Router::HttpError.new(400, "Process #{process.identity} has no capsule #{capsule.inspect}")
        end

        process.resize!(count, capsule: capsule)
        ok({"resized" => 1})
      end

      def signal_all_processes
        signal = signal_method
        ok({"signalled" => ProcessSet.new(config: config).count { |p| p.public_send(signal) }})
      end

      # -- scheduled / retries / dead ------------------------------------------

      def set
        set = job_set
        page, per = paging
        query = @params["q"].to_s.strip
        newest_first = set.instance_of?(DeadSet)
        if query.empty?
          entries, total = set.page_and_size(page, per_page: per, reverse: newest_first)
        else
          matches = set.scan(query, limit: SEARCH_LIMIT)
          matches.reverse! if newest_first
          total = matches.size
          entries = matches.drop((page - 1) * per).first(per)
        end
        ok({"set" => @params.fetch("set"), "page" => page, "per_page" => per, "total" => total, "query" => query,
          "jobs" => entries.map { |e| job_json(e) }})
      end

      def set_entry
        ok({"job" => job_json(find_entry!, full: true)})
      end

      def set_bulk
        action = set_action!
        set = job_set
        ok({"affected" => apply(set, set.find_all_by_id(Array(body["ids"])), action)})
      end

      def set_all
        action = set_action!
        set = job_set
        count = if action == :delete
          set.size.tap { set.clear }
        else
          set.drain_pages { |page| apply(set, page, action) }
        end
        ok({"affected" => count})
      end

      # Replace a failed job's arguments and run it again right away.
      def edit_entry
        entry = find_entry!
        raise Router::HttpError.new(422, "Encrypted jobs can't be edited") if entry["encrypted"]

        args = body["args"]
        raise Router::HttpError.new(422, "args must be a JSON array") unless args.instance_of?(Array)
        raise Router::HttpError.new(409, "That job is no longer in the set") unless entry.delete

        item = entry.item.except("jid", *FAILURE_FIELDS).merge({"args" => args, "edited_from" => entry.jid})
        ok({"jid" => Client.new(config: config).push(item)})
      end

      def find_job
        jid = @params.fetch("jid")
        found = JobLocator.new(config: config).locate(jid).map { |r| r.merge({"job" => job_json(r.fetch("job"), full: true)}) }
        ok({"jid" => jid, "results" => found, "progress" => Progress.fetch(jid, config: config),
          "cancelled" => Cancellation.cancelled?(jid, config: config)})
      end

      def cancel_job
        Cancellation.cancel!(@params.fetch("jid"), config: config)
        ok({"cancelled" => true})
      end

      # -- metrics --------------------------------------------------------------

      def metrics
        minutes = int_param("minutes")
        ok(Metrics::Query.new(config).recent(minutes: minutes).merge({"minutes" => minutes, "deploys" => deploys(minutes * 60)}))
      end

      def metrics_history
        hours = int_param("hours")
        ok(Metrics::Query.new(config).history(hours: hours).merge({"hours" => hours, "deploys" => deploys(hours * 3600)}))
      end

      def metrics_queues
        granularity = (@params["granularity"] == "hour") ? :hour : :minute
        points = int_param("points")
        ok({"granularity" => granularity, "points" => Metrics::Query.new(config).queue_history(granularity: granularity, points: points)})
      end

      def metrics_job
        klass = @params.fetch("klass")
        minutes = int_param("minutes")
        now = Time.now
        stamps = Array.new(minutes) { |i| Metrics.minute_stamp(now - i * 60) }.reverse
        fields = %w[s f ms].map { |kind| "#{klass}|#{kind}" }
        rows = config.redis { |c| c.pipelined { |p| stamps.each { |s| p.call("HMGET", config.key("m", s), *fields) } } }
        series = stamps.zip(rows).map { |t, (s, f, ms)| {"t" => t, "s" => s.to_i, "f" => f.to_i, "ms" => ms.to_f} }
        totals = %w[s f ms].to_h { |kind| [kind, series.sum { |point| point.fetch(kind) }] }
        succeeded = totals.fetch("s") # "ms" only counts successful runs
        totals["avg_ms"] = succeeded.zero? ? 0 : (totals.fetch("ms") / succeeded).round(1)
        ok({"class" => klass, "minutes" => minutes, "series" => series, "totals" => totals, "deploys" => deploys(minutes * 60),
          "histogram" => Metrics::Query.new(config).histogram(klass, minutes: minutes)})
      end

      # Deploys in the last +seconds+.
      def deploys(seconds) = Deploy.list(from: Time.now - seconds, config: config)

      # -- batches, limiters, cron ------------------------------------------------

      def batches
        tag = @params["tag"].to_s
        ok({"available" => true, "batches" => Batch.list(config: config, limit: int_param("limit"), tag: (tag unless tag.empty?))})
      end

      def batch
        status = Batch::Status.new(@params.fetch("bid"), config: config)
        raise Router::HttpError.new(404, "No batch #{@params.fetch("bid")}") unless status.exists?

        ok({"batch" => status.to_h})
      end

      def cancel_batch
        bid = @params.fetch("bid")
        ok({"cancelled" => Batch.new(bid, config: config).cancel!})
      rescue Batch::NoSuchBatch
        raise Router::HttpError.new(404, "No batch #{bid}")
      end

      def delete_batch
        Batch::Status.new(@params.fetch("bid"), config: config).delete!
        ok({"deleted" => true})
      end

      def limiters
        ok({"available" => true, "limiters" => Limiter.list(config: config)})
      end

      def reset_limiter
        Limiter.reset!(@params.fetch("name"), config: config)
        ok({"reset" => true})
      end

      def delete_limiter
        Limiter.delete!(@params.fetch("name"), config: config)
        ok({"deleted" => true})
      end

      def cron
        ok({"available" => true, "jobs" => Periodic.list(config: config), "leader" => Leader.current(config)})
      end

      def cron_entry
        job = Periodic.list(config: config).find { |j| j.fetch("id") == @params.fetch("id") }
        raise Router::HttpError.new(404, "No cron job #{@params.fetch("id")}") unless job

        ok({"job" => job, "history" => Periodic.history(@params.fetch("id"), config: config, limit: 50)})
      end

      def cron_enqueue
        ok({"jid" => Periodic.enqueue_now(@params.fetch("id"), config: config)})
      rescue ArgumentError
        raise Router::HttpError.new(404, "No cron job #{@params.fetch("id")}")
      end

      def cron_pause
        Periodic.pause!(@params.fetch("id"), config: config)
        ok({"paused" => true})
      end

      def cron_unpause
        Periodic.unpause!(@params.fetch("id"), config: config)
        ok({"paused" => false})
      end

      # -- profiles -------------------------------------------------------------

      def profiles
        ok({"profiles" => Profiler.list(config: config)})
      end

      # The profile itself, as a download for the Firefox Profiler.
      def profile_data
        jid = @params.fetch("jid")
        data = Profiler.data(jid, config: config) or raise Router::HttpError.new(404, "That profile has expired")
        [200, {"content-type" => "application/json", "content-disposition" => %(attachment; filename="robin-#{jid.delete("^a-zA-Z0-9_-")}.json"),
               "cache-control" => "no-store"}, [data]]
      end

      def delete_profile
        ok({"deleted" => Profiler.delete(@params.fetch("jid"), config: config)})
      end

      # -- extensions -----------------------------------------------------------

      def extension_page
        extension = extension!
        request = extension_request(extension)
        blocks = guarded(extension, "page") { extension.new.blocks(request) }
        ok(extension.to_h.merge({"blocks" => blocks, "messages" => extension.messages(request.locale) || {}}))
      end

      def extension_data
        extension = extension!
        name = @params.fetch("name")
        raise Router::HttpError.new(404, "#{extension.title} has no data #{name.inspect}") unless extension.data_sources.key?(name)

        ok(guarded(extension, name) { extension.new.fetch(name, extension_request(extension)) })
      end

      def extension_action
        extension = extension!
        name = @params.fetch("action")
        raise Router::HttpError.new(404, "#{extension.title} has no action #{name.inspect}") unless extension.actions.key?(name)

        authorize!(:extensions, "extension:#{extension.slug}/#{name}")
        ok({"message" => guarded(extension, name) { extension.new.run(name, extension_request(extension, body)) }})
      end

      private

      def ok(body) = API.json(200, body)

      def stats_event = "event: stats\ndata: #{Robin.dump_json(live_stats)}\n\n"

      def extension!
        slug = @params.fetch("slug")
        Web.extensions.fetch(slug) { raise Router::HttpError.new(404, "No dashboard extension #{slug.inspect}") }
      end

      def extension_request(extension, body = {})
        params = @params.except("slug", "action", "name", "cluster", "locale")
        Extension::Request.new(config, params, @env, @params.fetch("locale", "en"), body, extension)
      end

      # An extension that raises is reported, and the user sees a 500.
      def guarded(extension, what)
        yield
      rescue => e
        config.handle_exception(e, {context: "dashboard extension #{extension.slug} (#{what})"})
        raise Router::HttpError.new(500, "#{extension.title} failed: #{e.class}: #{e}")
      end

      def body
        @body ||= begin
          raw = @request.body&.read.to_s
          parsed = raw.empty? ? {} : JSON.parse(raw) #: Hash[String, json]
          raise Router::HttpError.new(400, "Request body must be a JSON object") unless parsed.instance_of?(Hash)

          parsed
        end
      end

      def int_param(name)
        default, min, max = INT_PARAMS.fetch(name)
        (Integer(@params[name], exception: false) || default).clamp(min, max)
      end

      def paging = [int_param("page"), int_param("per_page")]

      def named_queue = Queue.new(@params.fetch("name"), config: config)

      def job_set
        klass = SETS.fetch(@params.fetch("set")) { raise Router::HttpError.new(404, "Unknown set #{@params.fetch("set").inspect}") }
        klass.new(config: config)
      end

      def find_entry!
        job_set.find_by_id(@params.fetch("id")) or
          raise Router::HttpError.new(404, "That job is no longer in the #{@params.fetch("set")} set")
      end

      def set_action!
        name = body["action"]
        action = SET_ACTIONS.fetch(name) { raise Router::HttpError.new(400, "Unknown action #{name.inspect}") }
        authorize!(action, "set:#{@params.fetch("set")}")
        action
      end

      def live_process
        process = ProcessSet.new(config: config).find { |p| p.identity == @params.fetch("identity") }
        raise Router::HttpError.new(404, "No live process #{@params.fetch("identity")}") unless process

        process
      end

      def signal_method
        SIGNALS.fetch(@params.fetch("signal")) { raise Router::HttpError.new(400, "Unknown signal #{@params.fetch("signal").inspect}") }
      end

      # Applies +action+ to +entries+ of +set+, in a few round trips;
      # returns how many it applied to. (The dead set's jobs are dead
      # already.)
      def apply(set, entries, action)
        case action
        when :retry then set.retry_entries(entries)
        when :delete then set.delete_entries(entries)
        else set.instance_of?(DeadSet) ? 0 : set.kill_entries(entries)
        end
      end

      # The queues' rows, in one round trip.
      def queue_rows(sizes)
        names = sizes.keys
        paused, *oldest = config.redis do |c|
          c.pipelined do |p|
            p.call("SMEMBERS", config.key("paused"))
            names.each { |n| p.call("LINDEX", config.key("queue", n), -1) }
          end
        end
        names.zip(oldest).map do |name, raw|
          {"name" => name, "size" => sizes.fetch(name), "latency" => Queue.latency_of(raw), "paused" => paused.include?(name)}
        end
      end

      def job_json(record, full: false)
        item = record.item
        wrapper = record.klass unless record.display_class == record.klass
        h = {
          "jid" => record.jid, "class" => record.display_class, "wrapper" => wrapper,
          "queue" => record.queue, "args" => record.display_args, "created_at" => item["created_at"],
          "enqueued_at" => item["enqueued_at"], "tags" => record.tags, "bid" => record.bid,
          "error_class" => record.error_class, "error_message" => record.error_message,
          "failures" => record.failures.nonzero?, "failed_at" => item["failed_at"], "retried_at" => item["retried_at"],
          "encrypted" => item.key?("encrypted")
        }
        if record.instance_of?(SortedEntry)
          h["id"] = record.id
          h["at"] = Robin.epoch_ms(record.score) # the dashboard's times are epoch ms
        end
        if full
          h["payload"] = record.to_h.fetch("item")
          h["backtrace"] = record.error_backtrace
          h["info"] = job_info(item)
        end
        h
      end

      # The Robin::Web.job_info rows for a job. A failing block is reported
      # and its row left out, so one bug can't break the job page.
      def job_info(item)
        Web.job_info_rows.filter_map do |label, block|
          value = block.call(item)
          info_row(label, value) unless value.nil?
        rescue => e
          config.handle_exception(e, {context: "Robin::Web.job_info #{label.inspect}", job: item})
          nil
        end
      end

      def info_row(label, value)
        return {"label" => label, "text" => value.to_s} unless value.is_a?(Hash)

        href = (value[:href] || value["href"]).to_s
        text = value[:text] || value["text"] || href
        {"label" => label, "text" => text.to_s, "href" => (href if INFO_LINK.match?(href))}.compact
      end
    end
  end
end
