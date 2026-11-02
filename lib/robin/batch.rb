# frozen_string_literal: true

module Robin
  # A group of jobs tracked as a unit, with callbacks when the group is
  # done.
  #
  #   batch = Robin::Batch.new
  #   batch.description = "Import #{file.name}"
  #   batch.tags = ["imports", "customer:#{file.customer_id}"]
  #   batch.on(:success, ImportCallbacks, "file_id" => file.id)
  #   batch.on(:complete, "ImportCallbacks#cleanup")
  #   batch.jobs do
  #     file.rows.each_slice(500) { |rows| ImportRows.perform_async(rows) }
  #   end
  #
  # Events:
  #
  # complete:: every job has run at least once (some may have failed and
  #            be awaiting retry)
  # success::  every job has succeeded
  # death::    a job in the batch died (fires once per batch)
  #
  # Callback targets are a class (calls +on_<event>+) or "Class#method";
  # they receive (Robin::Batch::Status, options) and run in a job on the
  # batch's +callback_queue+.
  #
  # Creating a batch inside another batch's +jobs+ block, or inside a job
  # that belongs to a batch, makes it a child: the parent isn't complete
  # until the child is complete, nor successful until the child succeeds.
  # Chaining children from success callbacks builds multi-step workflows.
  #
  # Tags label a batch for finding it later: Robin::Batch.list(tag: "imports")
  # (and the web UI's batch filter) lists the batches with that tag.
  #
  # Cancelling a batch (Robin::Batch.new(bid).cancel!) cancels its child
  # batches too. Their jobs that haven't started are skipped, and running
  # ones see #cancelled? turn true (see Robin::Cancellation). The batch
  # still completes once every job has run or been skipped, but never
  # succeeds; callbacks can check status.cancelled?.
  class Batch
    class NoSuchBatch < Robin::Error; end

    EVENTS = %w[complete success death].freeze
    TTL = 30 * 86_400
    CONTEXT = :robin_batch
    RUNNING = :robin_running_bid
    HOLD = :robin_batch_hold
    FAILURE = :robin_batch_failure

    # A batch job's failure as its ServerMiddleware saw it (+info+), held
    # back while a processor runs the job (see Batch.holding_failure), to
    # be recorded with the job's retry in one round trip.
    HeldFailure = Struct.new(:payload, :info)

    # What an atomic +jobs+ block holds back until it finishes: batch
    # members to register ([batch, member]), pushes ([client, payloads]),
    # the batches it created, and the +jobs+ blocks inside it to close.
    Hold = Struct.new(:members, :pushes, :created, :closes)

    class Hold
      def self.empty = new([], [], [], [])

      # Registers the members, sends the jobs (so none can finish before
      # it's counted), then closes the inner blocks. When the jobs all go
      # straight to the Redis the batches live in, that's one transaction.
      def release
        pool = shared_pool
        if pool
          pool.with do |conn|
            conn.multi do |tx|
              by_batch.each { |batch, list| batch.queue_register(tx, list) }
              pushes.each { |client, payloads| client.queue_push(tx, payloads) }
            end
          end
        else
          by_batch.each { |batch, list| batch.register_all(list) }
          pushes.each { |client, payloads| client.deliver_now(payloads) }
        end
        closes.each(&:close)
      end

      # Undoes the batches the block created (the held jobs are dropped)
      # and closes the inner blocks of batches that already existed.
      def discard
        created.each(&:discard!)
        (closes - created).each(&:close)
      end

      private

      def by_batch = members.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }

      # The Redis pool every member and job goes to, when there are jobs and
      # they're sent right away (see Client#direct?) to the one the batches
      # use.
      def shared_pool
        return if pushes.all? { |_client, payloads| payloads.empty? }

        pool = pushes.first.first.redis_pool
        pool if pushes.all? { |client, payloads| client.redis_pool.equal?(pool) && client.direct?(payloads) } &&
          members.all? { |batch, _member| batch.config.redis_pool.equal?(pool) }
      end
    end

    # Updates counters for one member (a jid, or "batch:<bid>" for a child
    # batch) and reports which events just became due: {complete,
    # success}, and when either is, what their callbacks need too (the
    # callback queue, created_at and tags). HSETNX on the *_at fields
    # guarantees each event fires exactly once.
    #
    # KEYS: batch hash, pending members set, failed members hash
    # ARGV: mode (success|failure|close), member, now (ms), failure info, ttl
    UPDATE = Redis::Script.new(<<~LUA)
      if redis.call('EXISTS', KEYS[1]) == 0 then return {0, 0} end
      local mode = ARGV[1]
      if mode == 'success' then
        if redis.call('SREM', KEYS[2], ARGV[2]) == 0 then return {0, 0} end
        redis.call('HDEL', KEYS[3], ARGV[2])
        redis.call('HINCRBY', KEYS[1], 'pending', -1)
      elseif mode == 'failure' then
        if redis.call('SISMEMBER', KEYS[2], ARGV[2]) == 0 then return {0, 0} end
        redis.call('HSET', KEYS[3], ARGV[2], ARGV[4])
        redis.call('EXPIRE', KEYS[3], ARGV[5])
      elseif mode == 'close' then
        redis.call('HINCRBY', KEYS[1], 'open', -1)
      end
      local failures = redis.call('HLEN', KEYS[3])
      redis.call('HSET', KEYS[1], 'failures', failures)
      if tonumber(redis.call('HGET', KEYS[1], 'open') or '0') > 0 then return {0, 0} end
      local pending = tonumber(redis.call('HGET', KEYS[1], 'pending') or '0')
      local complete, success = 0, 0
      if pending <= failures and redis.call('HSETNX', KEYS[1], 'complete_at', ARGV[3]) == 1 then complete = 1 end
      if pending == 0 and redis.call('HEXISTS', KEYS[1], 'cancelled_at') == 0
        and redis.call('HSETNX', KEYS[1], 'success_at', ARGV[3]) == 1 then success = 1 end
      if complete + success == 0 then return {0, 0} end
      local info = redis.call('HMGET', KEYS[1], 'callback_queue', 'created_at', 'tags')
      return {complete, success, info[1], info[2], info[3]}
    LUA

    # Marks a batch and all its descendants cancelled (the first time;
    # cancelled_at stays) and returns their bids, the batch's first.
    # KEYS: none (they're built from ARGV). ARGV: batch hash key prefix
    # ("<prefix>b:"), bid, now (ms).
    CANCEL = Redis::Script.new(<<~LUA)
      local bids = {ARGV[2]}
      local i = 1
      while bids[i] do
        local hash = ARGV[1] .. bids[i]
        redis.call('HSETNX', hash, 'cancelled_at', ARGV[3])
        for _, child in ipairs(redis.call('SMEMBERS', hash .. ':children')) do bids[#bids + 1] = child end
        i = i + 1
      end
      return bids
    LUA

    # Records when a batch first had a job die: {1, callback queue, tags}
    # the first time, {0} after. A batch that doesn't
    # exist (expired, or a job's "bid" from elsewhere) isn't created.
    # KEYS: batch hash. ARGV: now (ms).
    MARK_DEATH = Redis::Script.new(<<~LUA)
      if redis.call('EXISTS', KEYS[1]) == 0 or redis.call('HSETNX', KEYS[1], 'death_at', ARGV[1]) == 0 then return {0} end
      local info = redis.call('HMGET', KEYS[1], 'callback_queue', 'tags')
      return {1, info[1], info[2]}
    LUA

    class << self
      # The batch whose +jobs+ block is currently running in this fiber.
      def current = Thread.current[CONTEXT]

      # The atomic +jobs+ block's hold, if one is running in this thread.
      def hold = Thread.current[HOLD]

      # Inside a +jobs+ block, holds back the batch members the block
      # registers and the jobs it pushes until it finishes, then registers
      # each batch's members in one round trip before pushing: push_bulk
      # counts its jobs together instead of one by one. If the block
      # raises, nothing is registered or pushed. Inside an atomic +jobs+
      # block, that block's hold already does this.
      def holding
        return yield if hold || !current

        held = Thread.current[HOLD] = Hold.empty
        begin
          result = yield
        ensure
          Thread.current[HOLD] = nil
        end
        held.release
        result
      end

      # The batch hash, pending members set and failed members hash.
      def tracking_keys(config, bid)
        base = config.key("b", bid)
        [base, "#{base}:jids", "#{base}:failed"]
      end

      def keys(config, bid) = [*tracking_keys(config, bid), "#{config.key("b", bid)}:children"]

      # The index of batches tagged +tag+, newest last.
      def tag_key(config, tag) = config.key("batches", "tag", tag)

      # mutant:disable -- a class and its name serialize identically to JSON
      def error_info(exception) = {"error_class" => exception.class.name, "error_message" => exception.message[0, 1000]}

      # Newest batches first (only those tagged +tag+, if given).
      def list(config: Robin.config, limit: 100, tag: nil)
        index = tag ? tag_key(config, tag) : config.key("batches")
        _, bids = config.redis do |c|
          c.pipelined do |p|
            p.call("ZREMRANGEBYSCORE", index, "-inf", Robin.now_ms - TTL * 1000)
            p.call("ZRANGE", index, 0, limit - 1, "REV")
          end
        end #: Array[untyped]
        rows = config.redis { |c| c.pipelined { |p| bids.each { |b| p.call("HGETALL", config.key("b", b)) } } }
        bids.zip(rows).filter_map do |bid, row|
          Status.summarize(bid, row.each_slice(2).to_h) unless row.empty?
        end
      end

      # -- tracking hooks, called by middleware and the retrier ---------------

      def job_succeeded(config, bid, member)
        update(config, bid, "success", member)
      end

      def job_failed(config, bid, member, info)
        update(config, bid, "failure", member, Robin.dump_json(info))
      end

      # A batch job that raised: its ServerMiddleware records the failure,
      # unless the processor running the job holds it back (see
      # #holding_failure).
      def failed(config, payload, info)
        held = Thread.current[FAILURE]
        return held.info = info if held&.payload.equal?(payload)

        job_failed(config, payload.fetch("bid"), payload.fetch("jid"), info)
      end

      # Runs the block (a batch job) with its failure held back in +held+
      # (a HeldFailure).
      def holding_failure(held)
        previous = Thread.current[FAILURE]
        Thread.current[FAILURE] = held
        begin
          yield
        ensure
          Thread.current[FAILURE] = previous
        end
      end

      # Queues a job's failure into +tx+ (a pipeline or transaction), for
      # #updated to handle its reply.
      def queue_failure(tx, config, payload, info)
        eval_update(tx, config, payload.fetch("bid"), "failure", payload.fetch("jid"), Robin.dump_json(info))
      end

      # A job in a batch won't run again: records its failure and the
      # batch's first death, in one round trip.
      def job_died(config, payload, exception)
        bid = payload["bid"]
        return unless bid

        replies = config.redis { |c| c.pipelined { |p| queue_death(p, config, payload, exception) } }
        death_recorded(config, bid, replies)
      end

      # Queues what #job_died records into +tx+ (a pipeline or transaction),
      # for #death_recorded to handle the two replies.
      def queue_death(tx, config, payload, exception)
        info = exception ? error_info(exception) : payload.slice("error_class", "error_message")
        queue_failure(tx, config, payload, info)
        eval_mark_death(tx, config, payload.fetch("bid"))
      end

      # Runs the callbacks the replies to #queue_death call for.
      def death_recorded(config, bid, replies)
        update, death = replies
        updated(config, bid, update)
        death_marked(config, bid, death)
      end

      def died(config, bid) = death_marked(config, bid, config.redis { |c| eval_mark_death(c, config, bid) })

      # Runs MARK_DEATH on +redis+: a connection (returns the reply), or a
      # pipeline or transaction to queue it in.
      #
      # mutant:disable -- Connection#evalsha splats ARGV, so passing the
      # time bare or wrapped in an Array is identical.
      def eval_mark_death(redis, config, bid) = redis.evalsha(MARK_DEATH, [config.key("b", bid)], [Robin.now_ms])

      # The first death of a batch runs its death callbacks.
      def death_marked(config, bid, reply)
        first, queue, tags = reply
        return unless first == 1

        enqueue_callback(config, bid, "death", queue: queue)
        report(config, ["death"], nil, tags)
      end

      def update(config, bid, mode, member = nil, info = nil)
        updated(config, bid, config.redis { |c| eval_update(c, config, bid, mode, member, info) })
      end

      # Runs UPDATE on +redis+: a connection (returns the reply), or a
      # pipeline or transaction to queue it in (#updated handles the reply).
      def eval_update(redis, config, bid, mode, member, info)
        redis.evalsha(UPDATE, tracking_keys(config, bid), [mode, member, Robin.now_ms, info, TTL])
      end

      # Runs the callbacks an UPDATE reply says just became due.
      def updated(config, bid, reply)
        complete, success, queue, created, tags = reply
        # "complete" runs first and chains "success" when both are due.
        events = [] #: Array[String]
        events << "complete" if complete == 1
        events << "success" if success == 1
        return if events.empty?

        # One or two events: the event, and the one it chains.
        enqueue_callback(config, bid, events.fetch(0), events.at(1), queue: queue)
        report(config, events, created, tags)
      end

      # Counts batch events, and times completed batches (+created+ is
      # the batch's created_at, needed for "complete"; +tags+ its tags as
      # JSON), in StatsD.
      def report(config, events, created, tags)
        statsd = config.statsd or return
        # Plain StatsD would fold each tag into the metric's name.
        tags = statsd.dogstatsd? ? {tag: Robin.load_json(tags || "[]")} : {} #: Statsd::tags
        events.each { |event| statsd.increment("batch.#{event}", tags: tags) }
        return unless events.include?("complete")

        duration = Robin.now_ms - Integer(created)
        statsd.timing("batch.duration", duration, tags: tags)
        statsd.distribution("batch.duration_dist", duration, tags: tags) if statsd.distributions?
      end

      # Pushes the job running +bid+'s callbacks for +event+ (then
      # +chain+'s) onto +queue+, the batch's callback queue.
      def enqueue_callback(config, bid, event, chain = nil, queue:)
        Client.new(config: config).push({"class" => Callback, "queue" => queue, "args" => [bid, event, chain].compact,
          "batch_callback" => true})
      end
    end

    attr_reader :bid, :config, :parent_bid, :tags
    attr_accessor :description, :callback_queue

    def initialize(bid = nil, config: Robin.config)
      @config = config
      @callbacks = {}
      @cancelled = false
      @tags = []
      if bid
        data = config.redis { |c| c.call("HGETALL", config.key("b", bid)) }.each_slice(2).to_h
        raise NoSuchBatch, "no batch #{bid} (expired or deleted?)" if data.empty?

        @bid = bid
        @persisted = true
        @description = data["description"]
        @callback_queue = data["callback_queue"]
        @parent_bid = data["parent_bid"]
        @cancelled = data.key?("cancelled_at")
        @callbacks = Robin.load_json(data["callbacks"] || "{}")
        @tags = Robin.load_json(data["tags"] || "[]")
      else
        @bid = SecureRandom.hex(10)
      end
    end

    # Registers a callback for :complete, :success or :death.
    def on(event, target, options = {})
      event = event.to_s
      raise ArgumentError, "unknown batch event #{event.inspect}; expected #{EVENTS.join(", ")}" unless EVENTS.include?(event)

      (@callbacks[event] ||= []) << [target.to_s, options.transform_keys(&:to_s)]
      if @persisted
        config.redis { |c| c.call("HSET", config.key("b", bid), "callbacks", Robin.dump_json(@callbacks)) }
      end
      self
    end

    def callbacks = @callbacks.dup

    # Labels for finding the batch later; set before the first +jobs+.
    def tags=(list)
      raise ArgumentError, "a batch's tags are set before its first jobs" if @persisted

      @tags = Array(list).map(&:to_s).reject(&:empty?).uniq
    end

    # Runs the block; every job pushed inside it belongs to this batch.
    # May be called again later (e.g. from a job in the batch) to add more
    # jobs. Returns the bid.
    #
    # Jobs are pushed as the block pushes them. With +atomic+, they're all
    # pushed when the block finishes instead, and none at all if it raises
    # (batches it created are then deleted). A unique job's lock, taken
    # when it was pushed, stays until it expires.
    def jobs(atomic: false)
      hold = Thread.current[HOLD] = Hold.empty if atomic && !self.class.hold
      # A new batch opens its first block as it's created.
      @persisted ? config.redis { |c| c.call("HINCRBY", config.key("b", bid), "open", 1) } : persist!
      previous = Thread.current[CONTEXT]
      Thread.current[CONTEXT] = self
      completed = false
      begin
        yield
        completed = true
      ensure
        Thread.current[CONTEXT] = previous
        if hold
          Thread.current[HOLD] = nil
          completed ? hold.release : hold.discard
          close unless @discarded
        elsif (outer = self.class.hold)
          # (Once the outer block is done.)
          outer.closes << self
        else
          close
        end
      end
      bid
    end

    # Ends one +jobs+ block; with none left open, a batch whose jobs are
    # all done completes.
    def close = self.class.update(config, bid, "close")

    def status = Status.new(bid, config: config)

    # Cancels this batch and its child batches (see the class comment), in
    # two round trips. Returns the bids cancelled.
    def cancel!
      bids = config.redis { |c| c.evalsha(CANCEL, [], ["#{config.key("b")}:", bid, Robin.now_ms]) }
      Cancellation.cancel!(bids.map { |b| "batch:#{b}" }, ttl: TTL, config: config)
      config.statsd&.increment("batch.cancelled", bids.size)
      @cancelled = true
      bids
    end

    # Was this batch (or one of its parents) cancelled?
    def cancelled? = @cancelled

    def parent = parent_bid && Batch.new(parent_bid, config: config)

    # Adds +member+ to the pending set. Called before the job is pushed, so
    # a fast job can never finish before it's counted. Inside an atomic
    # +jobs+ block, that waits until the block finishes.
    def register(member)
      hold = self.class.hold
      return hold.members << [self, member] if hold

      register_all([member])
    end

    def register_all(members)
      config.redis { |c| c.multi { |tx| queue_register(tx, members) } }
    end

    # Queues the commands registering +members+ into +tx+ (a transaction).
    def queue_register(tx, members)
      hash, jids = self.class.keys(config, bid)
      tx.call("SADD", jids, *members)
      tx.call("EXPIRE", jids, TTL)
      tx.call("HINCRBY", hash, "pending", members.size)
      tx.call("HINCRBY", hash, "total", members.size)
    end

    # Deletes a batch an atomic +jobs+ block created before it raised.
    def discard!
      Status.new(bid, config: config).delete!
      config.redis { |c| c.call("SREM", self.class.keys(config, parent_bid).fetch(3), bid) } if parent_bid
      @discarded = true
    end

    private

    # The batch a new batch becomes a child of: the one whose +jobs+ block
    # is running, else the one the running job belongs to.
    def parent_for_new = Thread.current[CONTEXT]&.bid || Thread.current[RUNNING]

    def persist!
      parent = parent_for_new
      @parent_bid = parent
      hold = self.class.hold
      hold.created << self if hold
      now = Robin.now_ms
      hash = config.key("b", bid)
      parent_batch = parent && Batch.new(parent, config: config)
      member = "batch:#{bid}"
      # In an atomic +jobs+ block, the parent counts its new child once the
      # block finishes, before the jobs are sent.
      hold.members << [parent_batch, member] if parent_batch && hold
      # pending/total start at zero implicitly (HINCRBY, or read as 0).
      fields = {"created_at" => now, "callbacks" => Robin.dump_json(@callbacks)}
      fields["description"] = description if description
      fields["callback_queue"] = callback_queue if callback_queue
      fields["parent_bid"] = parent if parent
      fields["tags"] = Robin.dump_json(tags) unless tags.empty?
      config.redis do |c|
        c.multi do |tx|
          if parent_batch
            parent_batch.queue_register(tx, [member]) unless hold
            children_key = self.class.keys(config, parent).fetch(3)
            tx.call("SADD", children_key, bid)
            tx.call("EXPIRE", children_key, TTL)
          end
          tx.call("HSET", hash, *fields.flatten)
          tx.call("HINCRBY", hash, "open", 1) # the +jobs+ block creating it
          tx.call("EXPIRE", hash, TTL)
          tx.call("ZADD", config.key("batches"), now, bid)
          tags.each do |tag|
            tx.call("ZADD", self.class.tag_key(config, tag), now, bid)
            tx.call("EXPIRE", self.class.tag_key(config, tag), TTL)
          end
        end
      end
      config.statsd&.increment("batch.created")
      @persisted = true
      cancel! if parent_batch&.cancelled?
    end

    # Read-only view of a batch, handed to callbacks and the web UI.
    class Status
      INTS = %w[total pending failures created_at complete_at success_at death_at cancelled_at].freeze

      def self.summarize(bid, data)
        h = {"bid" => bid, "description" => data["description"], "parent_bid" => data["parent_bid"],
             "callbacks" => Robin.load_json(data["callbacks"] || "{}"), "tags" => Robin.load_json(data["tags"] || "[]")}
        INTS.each { |k| h[k] = data[k]&.to_i }
        %w[total pending failures].each { |k| h[k] ||= 0 }
        h
      end

      attr_reader :bid

      def initialize(bid, config: Robin.config)
        @bid = bid
        @config = config
        @data = config.redis { |c| c.call("HGETALL", config.key("b", bid)) }.each_slice(2).to_h
      end

      def exists? = !@data.empty?

      def total = @data["total"].to_i

      def pending = @data["pending"].to_i

      def failures = @data["failures"].to_i

      def description = @data["description"]

      def parent_bid = @data["parent_bid"]

      def callback_queue = @data["callback_queue"]

      def tags = Robin.load_json(@data["tags"] || "[]")

      def created_at = @data["created_at"]&.to_i

      def complete? = !@data["complete_at"].nil?

      def success? = !@data["success_at"].nil?

      def dead? = !@data["death_at"].nil?

      def cancelled? = !@data["cancelled_at"].nil?

      def callbacks = Robin.load_json(@data["callbacks"] || "{}")

      def jids
        @config.redis { |c| c.call("SMEMBERS", Batch.keys(@config, bid).fetch(1)) }.reject { |m| m.start_with?("batch:") }
      end

      def children
        @config.redis { |c| c.call("SMEMBERS", Batch.keys(@config, bid).fetch(3)) }
      end

      def failed_jobs
        @config.redis { |c| c.call("HGETALL", Batch.keys(@config, bid).fetch(2)) }.each_slice(2).map do |jid, json|
          {"jid" => jid}.merge(Robin.load_json(json).slice("error_class", "error_message"))
        end
      end

      # Counts and states only, as Web::BatchStatus shows them.
      def progress
        {"bid" => bid, "total" => total, "pending" => pending, "failures" => failures,
         "complete" => complete?, "success" => success?, "dead" => dead?, "cancelled" => cancelled?}
      end

      def to_h
        Status.summarize(bid, @data).merge({"failed_jobs" => failed_jobs, "children" => children, "jids" => jids})
      end

      def delete!
        @config.redis do |c|
          c.multi do |tx|
            tx.call("UNLINK", *Batch.keys(@config, bid))
            tx.call("ZREM", @config.key("batches"), bid)
            tags.each { |tag| tx.call("ZREM", Batch.tag_key(@config, tag), bid) }
          end
        end
        @data = {}
        true
      end
    end

    # Runs a batch's callbacks for one event, then propagates the outcome
    # to the parent batch. Runs as a normal job, so failing callbacks are
    # retried (callbacks for that event run again; make them idempotent).
    class Callback
      include Robin::Job

      def perform(bid, event, chain = nil)
        config = self.class.robin_config
        status = begin
          config.batch_status_class.new(bid, config: config)
        rescue NoSuchBatch # a status class that refuses a missing batch
          return
        end
        return unless status.exists?

        Array(status.callbacks[event]).each do |target, options|
          klass_name, method = target.split("#", 2) #: [String, String] | [String]
          Object.const_get(klass_name).new.public_send(method || "on_#{event}", status, options || {})
        end

        Batch.enqueue_callback(config, bid, chain, queue: status.callback_queue) if chain
        parent = status.parent_bid
        return unless parent

        member = "batch:#{bid}"
        case event
        when "success"
          Batch.job_succeeded(config, parent, member)
        when "complete"
          unless status.success? || chain
            message = status.cancelled? ? "child batch #{bid} was cancelled" : "child batch #{bid} has #{status.failures} failure(s)"
            Batch.job_failed(config, parent, member, {"error_class" => "Robin::Batch::ChildFailed", "error_message" => message})
          end
        else # "death"
          Batch.died(config, parent)
        end
      end
    end

    # Tags jobs pushed inside a +jobs+ block with the batch id.
    class ClientMiddleware
      include Middleware::ConfigAware
      include Middleware::Stateless

      # Only inside a batch's +jobs+ block.
      def self.applies?(*) = !Batch.current.nil?

      def call(_job_class, payload, _queue, _redis)
        batch = Batch.current
        if batch && !payload["bid"] && !payload["batch_callback"]
          payload["bid"] = batch.bid
          batch.register(payload.fetch("jid"))
        end
        yield
      end
    end

    # Records the outcome of batch jobs.
    class ServerMiddleware
      include Middleware::ConfigAware
      include Middleware::Stateless

      def self.applies?(_job, payload, _queue) = payload.key?("bid")

      def call(_job, payload, _queue)
        bid = payload["bid"]
        return yield unless bid

        previous = Thread.current[RUNNING]
        Thread.current[RUNNING] = bid
        begin
          result = yield
        rescue Discard
          Batch.job_succeeded(config, bid, payload.fetch("jid"))
          raise
        rescue Exception => e # rubocop:disable Lint/RescueException
          Batch.failed(config, payload, Batch.error_info(e)) unless Robin.shutdown?(e) || e.is_a?(Limiter::OverLimit)
          raise
        ensure
          Thread.current[RUNNING] = previous
        end
        # Iterable jobs that were interrupted re-enqueue themselves and are
        # still pending.
        Batch.job_succeeded(config, bid, payload.fetch("jid")) unless payload["iteration_interrupted"]
        result
      end
    end
  end
end
