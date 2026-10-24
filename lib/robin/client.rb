# frozen_string_literal: true

module Robin
  # Pushes jobs into Redis.
  #
  #   Robin::Client.push("class" => "ReportJob", "args" => [1], "queue" => "low")
  #   Robin::Client.push_bulk("class" => ReportJob, "args" => [[1], [2], [3]])
  class Client
    class ArgumentError < ::ArgumentError; end

    class << self
      # A callable that may take over delivery (Robin::Testing uses it to
      # keep jobs in memory). It returns truthy when it handled the push.
      attr_accessor :interceptor

      # Callables that may rewrite a job hash (string keys) before #push
      # handles it, each returning the hash to use. The Rails integration
      # adds one that turns an ActiveJob class into its wrapper, so
      # periodic jobs (and Client.push) can name ActiveJob classes.
      def rewriters = (@rewriters ||= [])
    end

    # Sends every push made by this thread inside the block to +pool+ (a
    # Robin::Redis::Pool) instead of the configured Redis, e.g. to spread
    # jobs over several Redis shards:
    #
    #   SHARDS = [Robin::Redis::Pool.new { Robin::Redis::Connection.new(url: A) }, ...]
    #   Robin::Client.via(SHARDS.sample) { ReportJob.perform_async(1) }
    #
    # Each shard needs its own Robin processes to work its jobs.
    def self.via(pool)
      previous = Thread.current[:robin_client_pool]
      Thread.current[:robin_client_pool] = pool
      yield
    ensure
      Thread.current[:robin_client_pool] = previous
    end

    # The pool set by an enclosing Client.via block, if any.
    def self.current_pool = Thread.current[:robin_client_pool]

    # Holds back the jobs this thread's pushes send inside the block, and
    # sends them all when it finishes: in one round trip when they go
    # straight to the same Redis. If the block raises, none are sent.
    # Returns the block's value.
    #
    #   Robin::Client.together { reports.each { |r| ReportJob.perform_async(r.id) } }
    #
    # mutant:disable -- on CRuby, setting a fiber-local to nil removes it,
    # so key? would do; on JRuby the key stays, and every later block would
    # take itself for a nested one.
    def self.together
      return yield if Thread.current[:robin_client_together]

      held = Thread.current[:robin_client_together] = []
      begin
        result = yield
      ensure
        Thread.current[:robin_client_together] = nil
      end
      send_together(held)
      result
    end

    # Sends what a Client.together block held: [client, payloads] each.
    def self.send_together(held)
      return if held.empty?

      pool = held.first.first.redis_pool
      if held.all? { |client, _payloads| client.redis_pool.equal?(pool) && client.plain? }
        pool.with { |conn| conn.pipelined { |pipe| held.each { |client, payloads| client.queue_push(pipe, payloads) } } }
      else
        held.each { |client, payloads| client.__send__(:send_payloads, payloads) }
      end
    end
    private_class_method :send_together

    def self.push(item) = new.push(item)

    def self.push_bulk(items) = new.push_bulk(items)

    # Converts a delay (seconds), a Time, or an epoch timestamp (seconds or
    # milliseconds) to epoch milliseconds.
    def self.timestamp_ms(value, now = Robin.now_ms)
      case value
      when nil then raise ArgumentError, "a time is required, not nil"
      when Numeric
        if value > 100_000_000_000 then Integer(value) # already epoch milliseconds
        elsif value > 1_000_000_000 then Integer(value * 1000) # epoch seconds
        else now + Integer(value * 1000) # a delay in seconds
        end
      when Time then Integer(value.to_r * 1000) # Time#to_time needs the date library
      else
        if value.respond_to?(:to_time) && !value.respond_to?(:parts)
          Integer(value.to_time.to_r * 1000) # Date, DateTime...
        else
          now + Integer(value.to_f * 1000) # e.g. ActiveSupport::Duration
        end
      end
    end

    # +count+ times spread evenly over +interval+ seconds, the first at
    # +start+ (anything #timestamp_ms takes; default now), as epoch
    # milliseconds.
    def self.spread(count, interval, start = 0)
      raise ArgumentError, "'spread_interval' must be a positive number of seconds" unless interval.is_a?(Numeric) && interval.positive?

      first = timestamp_ms(start)
      Array.new(count) { |i| first + Integer(interval * 1000 * i / count) }
    end

    attr_reader :config

    # +pool+ pushes to another Redis (see Client.via); +chain+ replaces the
    # configured client middleware for this client's pushes.
    def initialize(config: Robin.config, pool: nil, chain: nil)
      @config = config
      @pool = pool || Client.current_pool
      @chain = chain
    end

    def middleware = @chain || @config.client_middleware

    def redis_pool
      @pool || @config.redis_pool
    end

    # Pushes a single job. Returns its jid, or nil if a client middleware
    # stopped the push (e.g. a duplicate unique job).
    def push(item)
      item = Client.rewriters.reduce(item.transform_keys(&:to_s)) { |rewritten, rewriter| rewriter.call(rewritten) }
      normalized = normalize(item)
      # Inside a batch's +jobs+ block, the job joins the batch as it's sent
      # (see Batch.holding).
      payload = Batch.holding do
        pushed = invoke_middleware(normalized)
        deliver([pushed]) if pushed
        pushed
      end
      payload&.fetch("jid")
    end

    # Pushes many jobs of the same class at once. "args" is an array of
    # argument arrays; "at" may be a single time or one per job, and
    # "spread_interval" (seconds) spreads the jobs evenly over that long,
    # from "at" or now. Returns the jids (nil for any job stopped by
    # middleware).
    def push_bulk(item)
      base = item.transform_keys(&:to_s)
      args_list = base["args"]
      raise ArgumentError, "push_bulk needs 'args' to be an Array of Arrays" unless args_list.is_a?(Array) && args_list.all?(Array)

      ats = base["at"]
      if ats.is_a?(Array) && !ats.size.equal?(args_list.size)
        raise ArgumentError, "push_bulk 'at' must have the same size as 'args'"
      end
      if (interval = base.delete("spread_interval"))
        raise ArgumentError, "push_bulk takes 'spread_interval' or an 'at' per job, not both" if ats.is_a?(Array)

        # (Steep can't tell that ats, not an Array, splats to one argument.)
        ats = Client.spread(args_list.size, interval, *ats) # steep:ignore UnexpectedPositionalArgument
      end

      jids = base.delete("jids")
      jid = base.delete("jid")
      # What every job shares is worked out once; then each gets its own
      # arguments, jid and (when given one per job) time.
      template = normalize(base.merge({"args" => [], "at" => (ats unless ats.is_a?(Array)), "jid" => ""}))
      built = args_list.each_with_index.map { |args, i| build(template, args, jids&.fetch(i) || jid, (ats.fetch(i) if ats.is_a?(Array))) }
      # Inside a batch's +jobs+ block, the jobs join the batch together.
      payloads = Batch.holding do
        # Their unique locks are taken together too.
        Unique.claiming(middleware, built) { built.map { |payload| run_middleware(payload) } }
          .tap { |list| deliver(list.compact) }
      end
      payloads.map { |p| p&.fetch("jid") }
    end

    # Fills in defaults and validates a job hash. Mutates and returns it.
    def normalize(item)
      item = item.transform_keys(&:to_s)
      klass = item["class"]
      raise ArgumentError, "job must have a 'class'" unless klass
      raise ArgumentError, "job 'args' must be an Array" unless item["args"].is_a?(Array)

      if klass.instance_of?(Class)
        # (A job class: Steep only knows it's a Class.)
        item = klass.robin_options.merge(item) if klass.respond_to?(:robin_options) # steep:ignore NoMethod
        item["class"] = klass.name
      else
        item["class"] = klass.to_s
      end
      queue = item["queue"].to_s
      item["queue"] = queue.empty? ? "default" : queue
      item["retry"] = true unless item.key?("retry")
      item["jid"] ||= Robin.generate_jid
      item["created_at"] ||= Robin.now_ms
      at = item.delete("at")
      at_ms = self.class.timestamp_ms(at) if at
      item["at"] = Robin.epoch_seconds(at_ms) if at_ms
      if (expires_in = item.delete("expires_in"))
        # The clock starts when the job is due to run.
        item["expires_at"] = [at_ms, item.fetch("created_at")].compact.max + Integer(expires_in.to_f * 1000)
      end
      if (window = item["retry_for"]) && !(window.is_a?(Numeric) && window.positive?)
        raise ArgumentError, "job 'retry_for' must be a positive number of seconds"
      end
      item["retry_queue"] = item.fetch("retry_queue").to_s if item["retry_queue"]
      %w[wait wait_until sync].each { |k| item.delete(k) }
      check_args(item) if @config.strict_args
      item
    end

    private

    # The work push_bulk does for each job is in methods of their own:
    # JRuby compiles a method after 50 calls, so these are compiled after
    # 50 jobs, rather than with push_bulk after 50 bulk pushes.

    # A bulk-pushed job: +template+ with its own arguments, jid (or a new
    # one) and time, if it has one.
    def build(template, args, jid, at)
      payload = template.merge({"args" => args, "jid" => jid || Robin.generate_jid})
      schedule(payload, self.class.timestamp_ms(at)) if at
      payload
    end

    # The job as client middleware leaves it, or nil if it stopped it.
    def run_middleware(payload)
      check_args(payload) if @config.strict_args
      invoke_middleware(payload)
    end

    def invoke_middleware(payload)
      middleware.invoke(payload.fetch("class"), payload, payload.fetch("queue"), redis_pool) { payload }
        .tap { |result| Debounce.carry(payload, result) }
    end

    # Sets a bulk-pushed job's own time (epoch ms); its expiry, if any,
    # counts from then (the template's counted from its creation).
    def schedule(payload, at_ms)
      payload["at"] = Robin.epoch_seconds(at_ms)
      payload["expires_at"] += [at_ms - payload.fetch("created_at"), 0].max if payload["expires_at"]
    end

    # Config#push_deferrer may take over delivery (e.g. until a database
    # transaction commits); otherwise the jobs go out now.
    def deliver(payloads)
      # An atomic batch block sends its jobs once it finishes.
      hold = Batch.hold
      return hold.pushes << [self, payloads] if hold

      deliver_now(payloads)
    end

    public

    # Would #deliver_now send these jobs to Redis right away (with no
    # interceptor, push deferrer or reliable push buffer in the way)?
    def direct?(payloads)
      plain? && (!@config.push_deferrer || payloads.any? { |p| p.key?("bid") })
    end

    # Does #send_payloads go straight to Redis (with no interceptor or
    # reliable push buffer in the way)?
    def plain? = !Client.interceptor && !@config.reliable_push

    # Delivers now, without waiting for an atomic batch block (see
    # Batch#jobs).
    def deliver_now(payloads)
      # Batch jobs are never deferred: their batch has already counted them,
      # and a deferred push that never happens (e.g. a rolled-back
      # transaction) would leave the batch waiting forever.
      deferrable = payloads.none? { |p| p.key?("bid") }
      return if deferrable && @config.push_deferrer&.call(payloads) { send_payloads(payloads) }

      send_payloads(payloads)
    end

    private

    def send_payloads(payloads)
      held = Thread.current[:robin_client_together]
      return held << [self, payloads] if held

      if @config.reliable_push
        ReliablePush.for(@config, @pool).push(payloads) { raw_push(payloads) }
      else
        raw_push(payloads)
      end
    end

    def raw_push(payloads)
      return if Client.interceptor&.call(payloads)

      redis_pool.with { |conn| conn.pipelined { |pipe| queue_push(pipe, payloads) } }
    end

    public

    # Queues the commands pushing +payloads+ into +pipe+ (a pipeline or
    # transaction on #redis_pool).
    def queue_push(pipe, payloads)
      Debounce.queue_claims(pipe, payloads)
      now = Robin.now_ms
      due = Robin.epoch_seconds(now)
      payloads.group_by { |p| (p.key?("at") && p.fetch("at") > due) ? :later : p.fetch("queue") }.each do |queue, group|
        if queue == :later
          # The score says when; enqueued_at is set when it's moved onto
          # its queue.
          args = group.flat_map { |p| [p.fetch("at"), Robin.dump_json(p.except("at", "enqueued_at"))] }
          pipe.call("ZADD", @config.key("schedule"), *args)
        else
          entries = group.map do |p|
            p.delete("at")
            p["enqueued_at"] = now
            Robin.dump_json(p)
          end
          pipe.call("SADD", @config.key("queues"), queue)
          pipe.call("LPUSH", @config.key("queue", queue), *entries)
        end
      end
      index_jids(pipe, payloads)
    end

    private

    # Records each job's queue for Robin::JobLocator (see Config#jid_index).
    def index_jids(pipe, payloads)
      ttl = @config.jid_index
      return unless ttl

      payloads.each { |p| pipe.call("SET", @config.key("jid", p.fetch("jid")), p.fetch("queue"), "EX", ttl) }
    end

    def check_args(item)
      bad = find_non_native(item.fetch("args"))
      return unless bad

      message = "Job arguments for #{item["class"]} must be JSON-native types (String, Integer, Float, " \
        "true, false, nil, Array, or Hash with String keys); got #{bad.inspect} (#{bad.class}). " \
        "Pass IDs or plain values instead of objects."
      case @config.strict_args
      when :warn then @config.logger.warn(message)
      else raise ArgumentError, message
      end
    end

    # Returns the first value (or hash key) that doesn't survive a JSON round
    # trip unchanged, or nil. (Such a value is never nil or false: those are
    # JSON-native, and come back from the last branch as "nothing found".)
    def find_non_native(obj)
      case obj
      when String, Integer, Float, true then nil
      when Array
        obj.each do |o|
          bad = find_non_native(o)
          return bad if bad
        end
        nil
      when Hash
        obj.each do |k, v|
          bad = k.is_a?(String) ? find_non_native(v) : k
          return bad if bad
        end
        nil
      else obj
      end
    end
  end
end
