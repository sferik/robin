# frozen_string_literal: true

module Robin
  module Redis
    # A small, thread-safe connection pool. Nested #with calls from the same
    # fiber reuse the connection that's already checked out.
    class Pool
      class TimeoutError < Robin::Redis::TimeoutError; end

      # The pool's bookkeeping: how many more connections may be checked out,
      # and the idle ones, most recently returned last. The extension's
      # NativeSlots does the same without a lock (JRuby, where threads run
      # in parallel and a shared lock would make every checkout wait).
      class Slots
        def initialize(size)
          @mutex = Mutex.new
          @cond = ConditionVariable.new
          @free = size
          @idle = [] # [connection, idle since], least recently used first
        end

        # An idle connection, :create (a slot to fill with a new one), or
        # nil after waiting +timeout+ seconds for either.
        def take(timeout)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          @mutex.synchronize do
            until @free.positive?
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              return unless remaining.positive?

              @cond.wait(@mutex, remaining)
            end
            @free -= 1
            @idle.pop&.first || :create #: Connection | :create
          end
        end

        # Returns a connection, idle since +since+ (monotonic seconds).
        def put(conn, since)
          @mutex.synchronize do
            @idle.push([conn, since])
            @free += 1
            @cond.signal
          end
        end

        # Frees a slot taken with :create but never filled.
        def release
          @mutex.synchronize do
            @free += 1
            @cond.signal
          end
        end

        # Makes +count+ more connections available.
        def add(count)
          @mutex.synchronize do
            @free += count
            @cond.broadcast
          end
        end

        # Removes and returns the connections idle since before +cutoff+.
        def reap(cutoff)
          @mutex.synchronize do
            stale = @idle.take_while { |_conn, since| since < cutoff }
            @idle.shift(stale.size).map(&:first)
          end
        end

        # Removes and returns every idle connection.
        def drain
          @mutex.synchronize do
            conns = @idle.map(&:first)
            @idle.clear
            conns
          end
        end
      end

      # The extension's slots where there are some (JRuby), else Slots.
      def self.slots_class(redis = Redis) = redis.const_defined?(:NativeSlots) ? redis::NativeSlots : Slots

      SLOTS = slots_class

      attr_reader :size, :timeout, :idle_timeout

      # +idle_timeout+ (seconds) closes connections nobody has used for that
      # long, the next time one is checked out, so a mostly idle process
      # doesn't hold on to Redis connections. (Redis's own `timeout`
      # setting does the same from the server side; Robin reconnects
      # transparently either way.)
      def initialize(size: 5, timeout: 3.0, idle_timeout: nil, &factory)
        raise ArgumentError, "a connection factory block is required" unless factory

        @size = size
        @timeout = timeout
        @idle_timeout = idle_timeout
        @factory = factory
        @slots = SLOTS.new(size)
        @key = :"robin_pool_#{object_id}"
        @pid = Process.pid
      end

      def with
        if (conn = Thread.current[@key])
          return yield(conn)
        end

        conn = checkout
        Thread.current[@key] = conn
        begin
          yield conn
        ensure
          Thread.current[@key] = nil
          checkin(conn)
        end
      end

      # Convenience pass-through so a pool can be used like a connection for
      # single commands.
      def call(*args) = with { |c| c.call(*args) }

      def pipelined(&) = with { |c| c.pipelined(&) }

      def multi(&) = with { |c| c.multi(&) }

      def evalsha(script, keys = [], argv = []) = with { |c| c.evalsha(script, keys, argv) }

      def blocking_call(timeout, *args) = with { |c| c.blocking_call(timeout, *args) }

      def shutdown
        reset_after_fork
        @slots.drain.each(&:close)
      end

      # Grows the pool to +size+ connections; a smaller size changes
      # nothing. Returns the pool's size.
      def grow(size)
        return @size if size <= @size

        @slots.add(size - @size)
        @size = size
      end

      private

      def checkout
        # @type ivar @idle_timeout: seconds
        reset_after_fork
        @slots.reap(monotonic - @idle_timeout).each(&:close) if @idle_timeout
        conn = @slots.take(@timeout)
        raise TimeoutError, "waited #{@timeout}s for a Redis connection (pool size #{@size})" unless conn
        # Or :create, a slot to fill with a new connection.
        return conn unless conn.instance_of?(Symbol)

        begin
          @factory.call
        rescue Exception # rubocop:disable Lint/RescueException
          @slots.release
          raise
        end
      end

      # Idle times only matter with an idle timeout; 0 stands in otherwise.
      def checkin(conn) = @slots.put(conn, @idle_timeout ? monotonic : 0)

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Sockets must never be shared between a parent and a forked child,
      # and locks held by the parent's other threads would never be freed.
      # The child abandons what it inherited (see Connection#abandon).
      def reset_after_fork
        return if @pid == Process.pid

        @slots.drain.each(&:abandon)
        @slots = SLOTS.new(@size)
        @pid = Process.pid
      end
    end
  end
end
