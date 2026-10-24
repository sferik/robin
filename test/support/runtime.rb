# frozen_string_literal: true

require "stringio"

# Helpers shared by the server-runtime unit tests.
module RuntimeTestHelpers
  # Records log lines as "LEVEL: message" while the block runs (or for the
  # rest of the test when no block is given). Returns the StringIO.
  def capture_logs
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = ->(severity, _time, _prog, msg) { "#{severity}: #{msg}\n" }
    config.logger = logger
    return io unless block_given?

    yield
    io.string
  end

  # The raw HTTP response to a GET on a local port.
  def http_get(port)
    Socket.tcp("127.0.0.1", port) do |s|
      s.write("GET / HTTP/1.0\r\n\r\n")
      s.read
    end
  end

  # Temporarily replaces +obj+'s singleton method +name+ with +impl+.
  def stub_method(obj, name, impl)
    sc = obj.singleton_class
    had = sc.method_defined?(name, false) || sc.private_method_defined?(name, false)
    backup = :"__robin_stubbed_#{name}"
    sc.alias_method(backup, name) if had
    sc.define_method(name, &impl)
    yield
  ensure
    sc.remove_method(name)
    if had
      sc.alias_method(name, backup)
      sc.remove_method(backup)
    end
  end

  # Collects (exception, context) pairs passed to config.error_handlers.
  def capture_errors
    errors = []
    config.error_handlers.replace([->(ex, ctx, _cfg) { errors << [ex, ctx] }])
    errors
  end

  # Collects [name, payload] pairs passed to +cfg+'s event_handlers.
  def capture_events(cfg = config)
    events = []
    cfg.event_handlers << ->(name, payload) { events << [name, payload] }
    events
  end

  # A connection wrapper that records every command (and optionally answers
  # some of them itself) while forwarding the rest to a real connection.
  class RecordingConnection
    attr_reader :calls

    def initialize(real = nil, &responder)
      @real = real
      @responder = responder
      @calls = []
    end

    def call(*args) = respond(:call, args) { @real.call(*args) }

    def blocking_call(timeout, *args) = respond(:blocking_call, [timeout, *args]) { @real.blocking_call(timeout, *args) }

    def evalsha(script, keys = [], argv = []) = respond(:evalsha, [script, keys, argv]) { @real.evalsha(script, keys, argv) }

    def pipelined(**opts, &blk) = respond(:pipelined, []) { @real.pipelined(**opts) { |p| blk.call(Batch.new(p, @calls, :pipe)) } }

    def multi(&blk) = respond(:multi, []) { @real.multi { |tx| blk.call(Batch.new(tx, @calls, :tx)) } }

    # Records the commands queued inside pipelined/multi blocks as
    # [:pipe, *args] / [:tx, *args].
    class Batch
      def initialize(real, calls, tag)
        @real = real
        @calls = calls
        @tag = tag
      end

      def call(*args)
        @calls << [@tag].concat(args)
        @real.call(*args)
      end

      def evalsha(script, keys = [], argv = [])
        @calls << [@tag, :evalsha, script, keys, argv]
        @real.evalsha(script, keys, argv)
      end

      def commands = @real.commands
    end

    def commands = @calls.map(&:first)

    private

    def respond(kind, args)
      @calls << [kind, *args]
      if @responder
        answer = @responder.call(kind, args)
        return answer unless answer == :forward
      end
      yield
    end
  end

  # A stand-in for Robin::Redis::Pool whose connections record commands.
  class RecordingPool
    attr_reader :recorders

    def initialize(pool, responder)
      @pool = pool
      @responder = responder
      @recorders = []
    end

    def with
      @pool.with do |real|
        rec = RecordingConnection.new(real, &@responder)
        @recorders << rec
        yield rec
      end
    end

    def calls = @recorders.flat_map(&:calls)

    def shutdown = @pool.shutdown
  end

  # Routes every config.redis call through recording connections for the
  # duration of the block; returns the RecordingPool.
  def recording_pool(responder = nil)
    real = config.redis_pool
    pool = RecordingPool.new(real, responder)
    config.redis_pool = pool
    yield pool
    pool
  ensure
    config.redis_pool = real
  end

  # Runs the block with a RecordingConnection wrapped around a pooled one.
  # +responder+ (a callable taking kind and args) may answer commands itself;
  # returning :forward passes them through to Redis.
  def recording(responder = nil)
    config.redis do |real|
      rec = RecordingConnection.new(real, &responder)
      yield rec
      rec
    end
  end

  # The jobs in a process's in-flight keys (+set+ is its in-flight set),
  # sorted.
  def in_flight(set) = redis("SMEMBERS", set).flat_map { |key| redis("LRANGE", key, 0, -1) }.sort

  # Puts +raw+ in flight for +fetcher+, as a fetch does: in an in-flight
  # key of its own, registered in the fetcher's in-flight set. Returns its
  # UnitOfWork.
  def unit_in_flight(fetcher, raw, queue = "default")
    key = "#{fetcher.inflight_key}:#{Robin::Fetcher.mint}"
    redis("SADD", fetcher.inflight_key, key)
    redis("RPUSH", key, raw)
    Robin::Fetcher::UnitOfWork.new(queue, raw, fetcher, key)
  end
end
