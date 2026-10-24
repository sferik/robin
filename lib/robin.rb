# frozen_string_literal: true

require "json"
require "securerandom"
require "logger"
require "socket"

require_relative "robin/version"
require_relative "robin/redis/connection"
require_relative "robin/redis/pool"

# Robin: fast, reliable background jobs for Ruby.
#
#   class SendReceipt
#     include Robin::Job
#     robin_options queue: "mailers", retry: 5
#
#     def perform(order_id)
#       ...
#     end
#   end
#
#   SendReceipt.perform_async(42)
module Robin
  NAME = "Robin"

  # Job ids generated per read of random bytes (see Robin.generate_jid).
  JID_BATCH = 64

  # A thread's random hex digits for job ids, and how far it has used them.
  JidBatch = Struct.new(:hex, :offset, :pid)

  class Error < StandardError; end

  # Raised by a job to stop immediately without retrying.
  class Discard < Error; end

  # Raised inside worker threads when the server's shutdown timeout
  # elapses. It descends from Interrupt so that application code's
  # `rescue => e` doesn't swallow it.
  class Shutdown < Interrupt; end

  autoload :Config, "robin/config"
  autoload :Capsule, "robin/config"
  autoload :Middleware, "robin/middleware"
  autoload :Job, "robin/job"
  autoload :Client, "robin/client"
  autoload :Scripts, "robin/scripts"
  autoload :Fetcher, "robin/fetcher"
  autoload :Processor, "robin/processor"
  autoload :Manager, "robin/manager"
  autoload :Launcher, "robin/launcher"
  autoload :HealthServer, "robin/health"
  autoload :Systemd, "robin/systemd"
  autoload :Scheduler, "robin/scheduler"
  autoload :Warmup, "robin/warmup"
  autoload :Retrier, "robin/retrier"
  autoload :JobLogger, "robin/job_logger"
  autoload :Context, "robin/job_logger"
  autoload :Stats, "robin/api"
  autoload :Queue, "robin/api"
  autoload :JobRecord, "robin/api"
  autoload :SortedEntry, "robin/api"
  autoload :JobSet, "robin/api"
  autoload :ScheduledSet, "robin/api"
  autoload :RetrySet, "robin/api"
  autoload :DeadSet, "robin/api"
  autoload :ProcessSet, "robin/api"
  autoload :ProcessRecord, "robin/api"
  autoload :WorkSet, "robin/api"
  autoload :JobLocator, "robin/api"
  autoload :Metrics, "robin/metrics"
  autoload :Deploy, "robin/deploy"
  autoload :Recovery, "robin/recovery"
  autoload :Leader, "robin/leader"
  autoload :Batch, "robin/batch"
  autoload :Limiter, "robin/limiter"
  autoload :Periodic, "robin/periodic"
  autoload :Cron, "robin/cron"
  autoload :Unique, "robin/unique"
  autoload :Events, "robin/events"
  autoload :GVL, "robin/gvl"
  autoload :Encryption, "robin/encryption"
  autoload :Expiry, "robin/expiry"
  autoload :Debounce, "robin/debounce"
  autoload :Cancellation, "robin/cancellation"
  autoload :Progress, "robin/progress"
  autoload :Profiler, "robin/profiler"
  autoload :IterableJob, "robin/iterable_job"
  autoload :ReliablePush, "robin/reliable_push"
  autoload :Swarm, "robin/swarm"
  autoload :Statsd, "robin/statsd"
  autoload :Embedded, "robin/embedded"
  autoload :CLI, "robin/cli"
  autoload :Top, "robin/top"
  autoload :Testing, "robin/testing"

  class << self
    def config
      @config ||= Config.new
    end

    # Loads every autoloaded part of Robin up front, e.g. before forking so
    # children share the code via copy-on-write. Robin::Testing is skipped:
    # loading it switches pushes to test mode.
    def eager_load!
      constants.each { |name| const_get(name) unless name.equal?(:Testing) }
    end

    attr_writer :config

    # Configure Robin for every process (client and server).
    def configure
      yield config
    end

    # Configure Robin only inside a job-processing server.
    def configure_server
      yield config if server?
    end

    # Configure Robin only inside non-server processes (web, console, rake).
    def configure_client
      yield config unless server?
    end

    def server?
      !!@server
    end

    def server!
      @server = true
    end

    # Run a Robin server inside the current process (e.g. alongside Puma).
    def configure_embed(&)
      Embedded.new(config).configure(&)
    end

    def redis(&)
      config.redis(&)
    end

    # This machine's name for process identities and the web UI: Heroku's
    # dyno name (e.g. "worker.1") when there is one, which means more than
    # its random hostnames.
    def hostname(env: ENV)
      env["DYNO"] || Socket.gethostname
    end

    def logger
      config.logger
    end

    def dump_json(obj)
      JSON.generate(obj)
    end

    def load_json(str)
      JSON.parse(str)
    end

    # The job as it was stored in Redis, before middleware or the job itself
    # changed anything (encrypted arguments are still encrypted). Use it to
    # write a running job back to Redis. Payloads that didn't come from
    # Redis are returned unchanged.
    def pristine(payload)
      raw = payload.instance_variable_get(:@robin_raw)
      raw ? load_json(raw) : payload
    end

    # Whether +exception+ is Robin::Shutdown or was caused by it (a job that
    # rescued the shutdown interrupt and raised its own error instead).
    def shutdown?(exception)
      # @type var exception: Exception?
      seen = Set[]
      while exception && seen.add?(exception)
        return true if exception.is_a?(Shutdown)

        exception = exception.cause
      end
      false
    end

    # Marks +payload+ as parsed from +raw+ (see #pristine).
    def remember_raw(payload, raw)
      payload.instance_variable_set(:@robin_raw, raw)
      payload
    end

    # Returns +string+ as valid UTF-8, ready for JSON: text in other
    # encodings is transcoded; bytes that aren't valid UTF-8 (including
    # binary data) become U+FFFD.
    def utf8(string)
      # Binary data is read as UTF-8; encoding to UTF-8 then replaces
      # invalid bytes (it validates even when nothing needs converting).
      string = String.new(string, encoding: Encoding::UTF_8) if string.encoding == Encoding::BINARY
      string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    rescue Encoding::ConverterNotFoundError
      String.new(string, encoding: Encoding::UTF_8).scrub
    end

    def now_ms
      Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    end

    # When a job runs ("at") and the scores of the schedule, retry and dead
    # sets are epoch seconds, as Floats to the millisecond; every other
    # timestamp is epoch milliseconds. These convert between the two.
    def epoch_seconds(ms) = ms / 1000.0

    def epoch_ms(seconds) = (Float(seconds) * 1000).round

    # The class a job shows as: its display_class, the class it wraps (an
    # ActiveJob job's, named in "wrapped"), or its class.
    def display_class(payload)
      wrapped = payload["wrapped"]
      payload["display_class"] || (wrapped if wrapped.instance_of?(String)) || payload["class"]
    end

    # A job's epoch-ms timestamp (created_at, enqueued_at...) as epoch ms,
    # also when it's from a job pushed by an older client that wrote epoch
    # seconds as a Float.
    def ms_of(time) = (time.instance_of?(Float) && time < 100_000_000_000) ? epoch_ms(time) : time

    # A job id: 24 random hex digits. Random bytes are read JID_BATCH ids
    # at a time (a syscall each read), per thread; a forked child reads its
    # own rather than reusing its parent's.
    def generate_jid
      batch = Thread.current[:robin_jids]
      unless batch && batch.offset < batch.hex.bytesize && batch.pid == Process.pid
        batch = Thread.current[:robin_jids] = JidBatch.new(SecureRandom.hex(12 * JID_BATCH), 0, Process.pid)
      end
      offset = batch.offset
      batch.offset = offset + 24
      batch.hex.byteslice(offset, 24)
    end

    # Is this process currently holding cluster leadership?
    def leader?
      Leader.leader?
    end

    # Requests cancellation of jobs (one or more jids); running jobs
    # observe it through #cancelled?, and pending jobs are skipped when
    # fetched.
    def cancel!(*jids, ttl: 86_400)
      Cancellation.cancel!(jids, ttl: ttl)
    end
  end
end

require_relative "robin/config"
require_relative "robin/job"

# In a Rails app, which loads Rails before Bundler.require loads its gems,
# the Rails integration (see Robin::Rails) joins the app's boot. Elsewhere
# it stays off; `require "robin/rails"` turns it on, e.g. when robin is
# required before Rails.
require_relative "robin/rails" if defined?(Rails::Railtie)
