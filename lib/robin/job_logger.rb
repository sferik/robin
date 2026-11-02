# frozen_string_literal: true

require "time"

module Robin
  # Per-thread logging context (class, jid, bid...), included in every log
  # line written while a job runs.
  module Context
    KEY = :robin_context

    def self.current
      Thread.current[KEY] ||= {}
    end

    def self.with(hash)
      previous = current
      Thread.current[KEY] = previous.merge(hash)
      yield
    ensure
      Thread.current[KEY] = previous
    end
  end

  class JobLogger
    class Formatter < ::Logger::Formatter
      def call(severity, time, _progname, message)
        extra = Context.current.map { |k, v| " #{k}=#{v}" }.join
        "#{time.utc.iso8601(3)} pid=#{Process.pid} tid=#{JobLogger.tid}#{extra} #{severity}: #{message.is_a?(String) ? message : message.inspect}\n"
      end
    end

    # One-line JSON per log entry, for log aggregators. Strings that
    # aren't valid UTF-8 (binary error messages, say) are scrubbed rather
    # than making the log call raise.
    class JSONFormatter < ::Logger::Formatter
      def call(severity, time, _progname, message)
        entry = {ts: time.utc.iso8601(3), pid: Process.pid, tid: JobLogger.tid, lvl: severity,
                 msg: Robin.utf8(message.is_a?(String) ? message : message.inspect)}
        ctx = Context.current
        entry[:ctx] = clean(ctx) unless ctx.empty?
        Robin.dump_json(entry) << "\n"
      end

      private

      def clean(value)
        case value
        when String then Robin.utf8(value)
        when Array then value.map { |v| clean(v) }
        when Hash then value.transform_values { |v| clean(v) }
        else value
        end
      end
    end

    # The logging context of a job: its class, jid, and bid and tags when
    # it has them.
    def self.context_for(payload)
      ctx = {class: Robin.display_class(payload), jid: payload["jid"]}
      ctx[:bid] = payload.fetch("bid") if payload["bid"]
      ctx[:tags] = payload.fetch("tags").join(",") if payload["tags"].is_a?(Array) && !payload.fetch("tags").empty?
      ctx
    end

    def self.tid
      Thread.current[:robin_tid] ||= (Thread.current.object_id ^ Process.pid).to_s(36)
    end

    def initialize(config)
      @config = config
    end

    LEVELS = %w[debug info warn error].freeze
    ENABLED = LEVELS.to_h { |level| [level, :"#{level}?"] }.freeze

    # Logs "start", then "done" or "fail", around a job, with its context
    # on every line logged meanwhile. Jobs choose the level of those lines
    # with +log_level+ (e.g. robin_options log_level: :debug for chatty
    # jobs), or turn them off with +logging: false+.
    def call(payload)
      ctx = self.class.context_for(payload)
      level = level_for(payload)
      return Context.with(ctx) { yield } unless level

      Context.with(ctx) do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        log(level, "start")
        begin
          result = yield
          Context.current[:elapsed] = elapsed(start)
          log(level, "done")
          result
        rescue Exception # rubocop:disable Lint/RescueException
          Context.current[:elapsed] = elapsed(start)
          log(level, "fail")
          raise
        end
      end
    end

    private

    # The level of the job's lines; nil for none at all, including when
    # the logger would drop them (so their timing isn't even formatted).
    def level_for(payload)
      return if payload["logging"] == false

      level = payload["log_level"].to_s
      level = "info" unless LEVELS.include?(level)
      level if @config.logger.public_send(ENABLED.fetch(level))
    end

    def log(level, message)
      @config.logger.public_send(level, message)
    end

    def elapsed(start)
      format("%.3f", Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
    end
  end
end
