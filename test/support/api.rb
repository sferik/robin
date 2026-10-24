# frozen_string_literal: true

# Helpers shared by the data API, metrics and CLI tests.
module ApiTestSupport
  # Wraps a connection pool and records every command sent through #call,
  # so tests can assert how many round-trips an operation makes.
  class SpyPool
    class Spy
      def initialize(conn, log)
        @conn = conn
        @log = log
      end

      def call(*args)
        @log << args
        @conn.call(*args)
      end

      def pipelined(...) = @conn.pipelined(...)

      def multi(...) = @conn.multi(...)

      def evalsha(...) = @conn.evalsha(...)
    end

    attr_reader :commands

    def initialize(pool)
      @pool = pool
      @commands = []
    end

    def with
      @pool.with { |conn| yield Spy.new(conn, @commands) }
    end

    def shutdown = @pool.shutdown
  end

  # A second config with its own prefix: passing it explicitly proves the
  # code under test honors +config:+ instead of falling back to Robin.config.
  def alt_config
    @alt_config ||= Robin::Config.new.tap do |c|
      c.redis = {url: REDIS_URL}
      c.key_prefix = "#{key_prefix_for_test}alt:"
      c.logger = Logger.new(nil)
    end
  end

  def teardown
    @alt_config&.redis_pool&.shutdown
    super
  end

  def alt(*args) = alt_config.redis { |c| c.call(*args) }

  def alt_key(*parts) = alt_config.key(*parts)

  def job(jid, **extra)
    {"class" => "SomeJob", "args" => [jid], "jid" => jid, "queue" => "default"}.merge(extra.transform_keys(&:to_s))
  end

  # Pushes payloads like the client does (newest at the head of the list).
  def push(queue, *items, config: alt_config)
    config.redis do |c|
      c.call("SADD", config.key("queues"), queue)
      items.each { |i| c.call("LPUSH", config.key("queue", queue), Robin.dump_json(i)) }
    end
  end

  # Temporarily replaces a singleton method.
  def with_singleton(obj, name, impl)
    had_own = obj.singleton_class.method_defined?(name, false) ||
      obj.singleton_class.private_method_defined?(name, false)
    original = obj.method(name) if had_own
    obj.define_singleton_method(name, &impl)
    yield
  ensure
    obj.singleton_class.send(:remove_method, name)
    obj.define_singleton_method(name, original) if had_own
  end
end
