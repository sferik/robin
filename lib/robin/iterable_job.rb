# frozen_string_literal: true

module Robin
  # Long-running jobs that survive deploys and restarts.
  #
  # Instead of +perform+, define how to enumerate the work and what to do
  # with each item. Robin checkpoints the cursor as it goes; when the
  # server shuts down (or the job is retried after an error) it resumes
  # right after the last finished item instead of starting over.
  #
  #   class BackfillAvatars
  #     include Robin::IterableJob
  #
  #     def build_enumerator(account_id, cursor:)
  #       active_record_records_enumerator(User.where(account_id: account_id), cursor: cursor)
  #     end
  #
  #     def each_iteration(user, account_id)
  #       user.regenerate_avatar!
  #     end
  #   end
  #
  # An enumerator yields +[item, cursor]+ pairs; the cursor is any
  # JSON-native value identifying the item, and +build_enumerator+
  # receives the cursor of the last finished item (nil on the first run).
  #
  # Optional hooks: on_start, on_resume, on_cancel, on_stop (interrupted
  # or cancelled; after on_cancel), on_complete. Inside them and
  # each_iteration, +cursor+ is the last finished item's cursor and
  # +current_object+ the item being (or last) worked on.
  #
  # A run stops and requeues itself (resuming from its checkpoint, like
  # after a deploy) once it has run for +max_iteration_runtime+ seconds:
  # the robin_option of that name, or config.max_iteration_runtime. That
  # keeps one huge job from holding a worker for hours.
  #
  # Every CHECKPOINT_SECONDS the cursor, the progress and a cancellation
  # check share one Redis round trip, so a cancelled job stops within
  # about that long (or after its current iteration, if that's longer).
  module IterableJob
    CHECKPOINT_SECONDS = 5
    STATE_TTL = 30 * 86_400

    def self.included(base)
      base.include(Job)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Iterable jobs run through #perform from Robin::IterableJob; a class
      # that defines its own would silently skip the iteration machinery.
      def method_added(name)
        if name == :perform
          raise ArgumentError, "#{self} includes Robin::IterableJob: define build_enumerator and each_iteration, not perform"
        end

        super
      end
    end

    attr_reader :cursor, :iterations, :current_object

    def perform(*args)
      config = self.class.robin_config
      key = config.key("iter", jid)
      state = config.redis { |c| c.call("HGETALL", key) }.each_slice(2).to_h
      resumed = !state.empty?
      @cursor = (Robin.load_json(state.fetch("cursor")).fetch("c") if resumed)
      @iterations = state["iterations"].to_i
      resumed ? on_resume : on_start

      enum = build_enumerator(*args, cursor: @cursor)
      if enum.nil?
        finish(config, key, @iterations)
        return
      end
      raise ArgumentError, "#{self.class}#build_enumerator must return an Enumerator" unless enum.respond_to?(:each)

      # Enumerator sizes count the remaining items (nil or Infinity when
      # unknown, and then progress is a count; see #progress_args).
      remaining = (enum.size if enum.respond_to?(:size))
      total = (remaining + @iterations if remaining.instance_of?(Integer))
      max_runtime = payload["max_iteration_runtime"] || config.max_iteration_runtime
      started = last_checkpoint = monotonic
      warned = false
      checkpointed = @iterations
      previous = started
      enum.each do |item, item_cursor|
        @current_object = item
        begin
          around_iteration { each_iteration(item, *args) }
        rescue Exception # rubocop:disable Lint/RescueException
          # Keep the progress made so far: a retry (or the next process)
          # resumes after the last finished item instead of redoing it.
          safe_checkpoint(config, key, total) if @iterations > checkpointed
          raise
        end
        @cursor = item_cursor
        @iterations += 1

        now = monotonic
        if !warned && now - previous > config.timeout
          warn_slow(now - previous, config)
          warned = true
        end
        previous = now
        if now - last_checkpoint >= CHECKPOINT_SECONDS
          last_checkpoint = now
          checkpointed = @iterations
          if checkpoint(config, key, total, check_cancel: true)
            logger.info { "#{self.class} jid=#{jid} cancelled after #{@iterations} iterations" }
            config.redis { |c| c.call("DEL", key) }
            on_cancel
            on_stop
            return
          end
        end
        reason = if interrupted?
          "interrupted"
        elsif max_runtime && now - started >= max_runtime
          "reached its max_iteration_runtime (#{max_runtime}s)"
        end
        if reason
          requeue(config, key, total, reason)
          on_stop
          return
        end
      end
      finish(config, key, total)
    end

    # Runs each iteration (the block): override to wrap them, e.g. in a
    # transaction.
    def around_iteration = yield

    def on_start
    end

    def on_resume
    end

    def on_cancel
    end

    def on_stop
    end

    def on_complete
    end

    # -- enumerator helpers ------------------------------------------------------

    # Iterates an array; the cursor is the index.
    def array_enumerator(array, cursor:)
      start = cursor.nil? ? 0 : cursor + 1
      Enumerator.new([array.size - start, 0].max) do |y|
        (start...array.size).each { |i| y.yield array.fetch(i), i }
      end
    end

    # Iterates records in primary-key order, loading +batch_size+ at a
    # time; the cursor is the last finished record's id.
    def active_record_records_enumerator(relation, cursor:, batch_size: 100)
      Enumerator.new do |y|
        active_record_batches(relation, cursor, batch_size) do |records|
          records.each { |r| y.yield r, r.id }
        end
      end
    end

    # Like active_record_records_enumerator, but yields whole batches.
    def active_record_batches_enumerator(relation, cursor:, batch_size: 100)
      Enumerator.new do |y|
        active_record_batches(relation, cursor, batch_size) { |records| y.yield records, records.last.id }
      end
    end

    # Iterates a CSV (or any enumerable of rows); the cursor is the row
    # index. Rows before the cursor are skipped, not re-processed.
    def csv_enumerator(csv, cursor:)
      Enumerator.new do |y|
        csv.each_with_index { |row, i| y.yield row, i if cursor.nil? || i > cursor }
      end
    end

    private

    def active_record_batches(relation, cursor, batch_size)
      pk = relation.primary_key
      last = cursor
      loop do
        scope = relation.reorder({pk => :asc}).limit(batch_size)
        scope = scope.where(relation.arel_table[pk].gt(last)) unless last.nil?
        records = scope.to_a
        break if records.empty?

        yield records
        last = records.last.id
      end
    end

    # Checkpoints while the job is already failing; a Redis error here is
    # reported but mustn't replace the job's own exception.
    def safe_checkpoint(config, key, total)
      checkpoint(config, key, total)
    rescue => e
      config.handle_exception(e, {context: "iterable job checkpoint", job: payload})
    end

    # One iteration outlasted the shutdown timeout: a deploy could interrupt
    # it midway, and it would run again.
    def warn_slow(seconds, config)
      logger.warn("#{self.class} jid=#{jid}: one iteration took #{seconds.round(1)}s, longer than the " \
        "#{config.timeout}s shutdown timeout; it may be interrupted midway and repeated")
      Events.emit(config, "iteration.slow", job: payload, seconds: seconds)
    end

    # Saves the cursor in one MULTI, followed by whatever the block queues
    # (so a requeued job always finds its checkpoint). With +check_cancel+,
    # returns whether the job (or its batch) was cancelled. When the job's
    # Redis is also the one progress! and cancelled? use (the usual case),
    # the progress and the cancellation check ride in the same MULTI.
    def checkpoint(config, key, total, check_cancel: false)
      shared = config.equal?(Robin.config)
      replies = config.redis do |c|
        c.multi do |tx|
          tx.call("HSET", key, "cursor", Robin.dump_json({"c" => @cursor}), "iterations", @iterations, "at", Robin.now_ms)
          tx.call("EXPIRE", key, STATE_TTL)
          tx.call(*progress_command(config, total)) if shared
          yield tx if block_given?
          # Robin::Cancellation.cancelled?, inline.
          tx.call("ZMSCORE", config.key("cancelled"), *[jid, bid && "batch:#{bid}"].compact) if shared && check_cancel
        end
      end
      report_progress(total) unless shared
      check_cancel && (shared ? replies.last.any? : cancelled?)
    end

    # How far along the job is, for Progress ([percent, message, meta]): a
    # percentage when the enumerator's size gave the total, or else no
    # percentage and the count of finished iterations ("iterations"),
    # which the Busy page shows instead.
    def progress_args(total)
      total ? [percent(total), "#{@iterations}/#{total}", {}] : [nil, nil, {"iterations" => @iterations}]
    end

    # An empty enumerator is all done.
    # mutant:disable -- Progress clamps percentages, so any above 100 is 100.
    def percent(total) = total.zero? ? 100 : @iterations * 100.0 / total

    def progress_command(config, total)
      pct, message, meta = progress_args(total)
      Progress.set_command(config, jid, Progress.entry(pct, message, meta))
    end

    def report_progress(total)
      pct, message, meta = progress_args(total)
      Progress.report(jid, pct, message, meta)
    end

    # Puts the job back on its queue (same jid) so any process can resume
    # it from the checkpoint. Bypasses client middleware: this isn't a new
    # job, so uniqueness and batch registration must not apply again.
    def requeue(config, key, total, reason)
      # As stored, so decrypted (or mutated) arguments never are.
      item = Robin.pristine(payload).dup
      %w[at error_class error_message error_backtrace failed_at retried_at].each { |k| item.delete(k) }
      item["enqueued_at"] = Robin.now_ms
      queue = item["queue"] || "default"
      checkpoint(config, key, total) do |tx|
        tx.call("SADD", config.key("queues"), queue)
        tx.call("RPUSH", config.key("queue", queue), Robin.dump_json(item))
      end
      payload["iteration_interrupted"] = true
      logger.info { "#{self.class} jid=#{jid} #{reason} after #{@iterations} iterations; requeued" }
    end

    # Drops the saved state (and reports 100%, or the count) before
    # on_complete runs.
    def finish(config, key, total)
      shared = config.equal?(Robin.config)
      config.redis do |c|
        c.pipelined do |p|
          p.call("DEL", key)
          p.call(*progress_command(config, total)) if shared
        end
      end
      report_progress(total) unless shared
      on_complete
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
