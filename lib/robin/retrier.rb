# frozen_string_literal: true

require "zlib"

module Robin
  # Decides what happens to a job that raised: schedule a retry with
  # exponential backoff, move it to the dead set, or discard it.
  class Retrier
    MAX_MESSAGE_BYTES = 10_000
    MAX_DELAY = 7 * 86_400
    # Earlier versions marked compressed backtraces with this.
    BACKTRACE_PREFIX = "deflate:"

    # Backtraces are stored compressed, as the base64 of the deflated JSON
    # lines: they're often most of a failed job's size, and the retry and
    # dead sets can hold a lot of failed jobs.
    def self.pack_backtrace(lines)
      return lines if lines.empty?

      [Zlib.deflate(Robin.dump_json(lines))].pack("m0")
    end

    # A stored error_backtrace (compressed or a plain array) as an array
    # of lines.
    def self.unpack_backtrace(value)
      return value unless value.instance_of?(String)

      # (unpack1("m0") returns a String; Steep can't tell from the format.)
      deflated = value.delete_prefix(BACKTRACE_PREFIX).unpack1("m0") #: String
      Robin.load_json(Zlib.inflate(deflated))
    rescue Zlib::Error, ArgumentError, JSON::ParserError
      ["(unreadable backtrace)"]
    end

    attr_reader :config

    def initialize(config)
      @config = config
    end

    # Default backoff: ~15s, 26s, 45s, ... growing by 1.7x per failure,
    # capped at a week, with +/-20% jitter so retries of a large failed
    # batch don't stampede. 20 retries span roughly 10 days.
    def self.default_delay(failures)
      base = [15 * (1.7**(failures - 1)), MAX_DELAY].min
      (base * (0.8 + rand * 0.4)).round
    end

    # A custom delay pushed up to 10% (at most 10s) later, so jobs that
    # failed together don't all retry in the same instant.
    def self.jitter(seconds)
      seconds + rand * [seconds * 0.1, 10].min
    end

    # An exception's message as valid UTF-8, even when reading it raises.
    def self.message_of(exception)
      Robin.utf8(exception.message.to_s)
    rescue => e
      "(#{e.class} raised reading the error message)"
    end

    # A job with +retry_for+ and no explicit retry count retries until its
    # time is up, however many attempts that takes.
    def max_retries(payload)
      case payload["retry"]
      when true, nil then payload["retry_for"] ? Float::INFINITY : config.max_retries
      when false then 0
      else Integer(payload.fetch("retry"))
      end
    end

    # Fields a failure adds to a job before it's written back to Redis.
    FAILURE_FIELDS = %w[error_class error_message error_backtrace failed_at retried_at retry_count discarded_at].freeze

    # Records the failure and acknowledges the unit of work. Returns the
    # outcome: :retry, :dead or :discard. Whatever the exception or the
    # job's hooks do, only Redis errors make this raise (and the job then
    # stays in flight).
    #
    # The failure details are added to +payload+ (for hooks and handlers),
    # but what's written back to Redis is the job as it was stored plus
    # those details, so arguments the job or middleware changed in memory
    # (or decrypted) never are.
    #
    # +batch_failure+ is the failure the job's batch middleware held back
    # (see Batch.holding_failure): it's recorded with the retry, in the
    # same transaction. A job that won't run again records its failure
    # with the batch anyway.
    def handle(unit, payload, job_class, exception, batch_failure: nil)
      payload["error_class"] = exception.class.name
      payload["error_message"] = truncate(self.class.message_of(exception))
      now = Robin.now_ms
      payload["failed_at"] ||= now
      # retry_count is 0 after the first failure, then counts the retries
      # that failed too.
      if payload["retry_count"]
        payload["retried_at"] = now
        payload["retry_count"] = Integer(payload.fetch("retry_count")) + 1
      else
        payload["retry_count"] = 0
      end
      if (lines = backtrace_lines(payload))
        payload["error_backtrace"] = self.class.pack_backtrace(backtrace_of(exception, lines))
      end
      return discard(unit, payload, exception) if payload["retry"] == false

      failures = payload.fetch("retry_count") + 1
      delay = (failures <= max_retries(payload)) ? retry_delay(job_class, failures, exception, payload) : :kill
      at = now + Integer(delay * 1000) if delay.is_a?(Numeric)
      delay = :kill if at && out_of_time?(payload, at)

      case delay
      when :discard
        discard(unit, payload, exception)
      when :kill
        die(unit, payload, job_class, exception)
      else
        # (at is set when delay is a number of seconds, as it is here.)
        payload["at"] = Robin.epoch_seconds(at) # steep:ignore ArgumentTypeMismatch
        entry = stored(payload)
        entry["queue"] = payload["queue"] = payload.fetch("retry_queue") if payload["retry_queue"]
        replies = config.redis do |conn|
          conn.multi do |tx|
            Batch.queue_failure(tx, config, payload, batch_failure) if batch_failure
            tx.call("ZADD", config.key("retry"), payload.fetch("at"), Robin.dump_json(entry))
            unit.acknowledge(tx)
          end
        end
        Batch.updated(config, payload.fetch("bid"), replies.first) if batch_failure
        :retry
      end
    end

    # Moves a job to the dead set, trimming it by age and size, then runs
    # the class's retries_exhausted hook and the global death handlers. The
    # hook may return :discard to drop the job instead (it isn't kept in
    # the dead set; handlers still run, with "discarded_at" set).
    def die(unit, payload, job_class, exception)
      if discard_requested?(job_class, payload, exception) || payload["dead"] == false
        discard(unit, payload, exception)
      else
        raw = Robin.dump_json(stored(payload))
        terminal(payload, exception) { |tx| DeadSet.new(config: config).queue_kill(tx, raw, unit) }
        :dead
      end
    end

    private

    # Drops a job for good: acknowledges it, records when, and tells its
    # batch and the death handlers that it won't run again.
    def discard(unit, payload, exception)
      payload["discarded_at"] = Robin.now_ms
      terminal(payload, exception) { |tx| unit&.acknowledge(tx) }
      :discard
    end

    # A job that won't run again: in one transaction, it goes where the
    # block (yielded the transaction) puts it and is acknowledged, gives
    # up its unique lock (if it has one), and tells its batch (if any);
    # then the batch callbacks this calls for and the death handlers run.
    def terminal(payload, exception)
      bid = payload["bid"]
      replies = config.redis do |conn|
        conn.multi do |tx|
          yield tx
          Unique.eval_release(tx, config, payload)
          Batch.queue_death(tx, config, payload, exception) if bid
        end
      end
      Batch.death_recorded(config, bid, replies.last(2)) if bid
      config.death_handlers.each do |handler|
        handler.call(payload, exception)
      rescue => e
        config.handle_exception(e, {context: "death handler", job: payload})
      end
    end

    # Runs the class's retries_exhausted hook; true when it asks for the
    # job to be discarded instead of kept in the dead set.
    def discard_requested?(job_class, payload, exception)
      hooks = hook_class(job_class, payload)
      return false unless hooks.respond_to?(:robin_retries_exhausted_block)

      hooks.robin_retries_exhausted_block&.call(payload, exception) == :discard
    rescue => e
      config.handle_exception(e, {context: "retries_exhausted hook", job: payload})
      false
    end

    # What's written to Redis: the job as stored, plus the failure details.
    def stored(payload)
      Robin.pristine(payload).except("at", "enqueued_at").merge(payload.slice(*FAILURE_FIELDS))
    end

    # Would a retry at +at+ (ms) come more than +retry_for+ seconds after
    # the job first failed?
    def out_of_time?(payload, at)
      window = payload["retry_for"]
      window && at > Robin.ms_of(payload.fetch("failed_at")) + window * 1000
    end

    # Seconds until the retry, :discard or :kill: the class's
    # robin_retry_in answer (jittered), else the default backoff; or what
    # config.retry_backoff makes of either.
    def retry_delay(job_class, failures, exception, payload)
      hooks = hook_class(job_class, payload)
      block = hooks.respond_to?(:robin_retry_in_block) && hooks.robin_retry_in_block
      custom = custom_delay(block, failures, exception, payload) if block
      return custom if custom.instance_of?(Symbol)
      return config.retry_backoff.call(failures, exception, payload, custom) if config.retry_backoff
      return self.class.default_delay(failures) if custom.nil?

      self.class.jitter(custom)
    end

    # The class whose retry hooks apply: the one an ActiveJob job's
    # payload names in "wrapped", when it has them, else the job's own.
    def hook_class(job_class, payload)
      wrapped = payload["wrapped"]
      return job_class unless wrapped.instance_of?(String)

      klass = Object.const_get(wrapped)
      klass.respond_to?(:robin_retry_in_block) ? klass : job_class
    rescue NameError
      job_class
    end

    # The robin_retry_in block's answer: seconds, :discard or :kill. Nil
    # (use the default backoff) when it returns nil or false, raises, or
    # returns something else; the last two are reported.
    def custom_delay(block, failures, exception, payload)
      custom = block.call(failures, exception, payload)
      case custom
      when nil, false then nil
      when :discard, :kill, "discard", "kill" then custom.to_sym
      else
        return custom if custom.is_a?(Numeric) && custom.real? && custom.finite? && !custom.negative?

        raise ArgumentError, "robin_retry_in returned #{custom.inspect}; expected seconds (>= 0), :discard, :kill or nil"
      end
    rescue => e
      config.handle_exception(e, {context: "robin_retry_in block", job: payload})
      nil
    end

    # The first +lines+ backtrace lines (after Config#backtrace_cleaner)
    # as UTF-8; [] when there's no backtrace (the exception was never
    # raised) or it can't be read.
    def backtrace_of(exception, lines)
      # (No backtrace (nil) raises NoMethodError here, rescued below.)
      clean(exception.backtrace).first(lines).map { |line| Robin.utf8(line) } # steep:ignore NoMethod
    rescue
      []
    end

    # A cleaner that fails leaves the backtrace as it was.
    def clean(backtrace)
      cleaner = config.backtrace_cleaner
      return backtrace unless cleaner && backtrace

      cleaner.call(backtrace)
    rescue => e
      config.handle_exception(e, {context: "backtrace_cleaner"})
      backtrace
    end

    def backtrace_lines(payload)
      case (bt = payload["backtrace"])
      when true then config.backtrace_lines
      when Integer then bt
      end
    end

    def truncate(message)
      return message if message.bytesize <= MAX_MESSAGE_BYTES

      # (byteslice within the message's bytes never returns nil.)
      cut = message.byteslice(0, MAX_MESSAGE_BYTES) #: String
      # Drops the character the cut may have split.
      cut.scrub("") + "…"
    end
  end
end
