# frozen_string_literal: true

module Robin
  # Measures GVL contention: how much of the time a process's threads could
  # have spent waiting for the GVL they did spend waiting. Only one thread
  # runs Ruby code at a time, so over t seconds n threads can wait at most
  # (n - 1) * t seconds between them. Contention is the share of that they
  # waited, as a percentage: 0 when no thread ever waited, near 100 when
  # every thread wanted to run all the time, so more threads wouldn't run
  # more Ruby code (more processes would).
  #
  # Threads that sleep or wait on I/O don't wait for the GVL, so a mostly
  # idle process stays near 0 however many threads it has.
  #
  # Needs the C extension (Robin::NativeGVL);
  # elsewhere (JRuby, which has no GVL) it measures nothing.
  class GVL
    def self.native = (NativeGVL if Robin.const_defined?(:NativeGVL))

    def initialize(native = GVL.native, threads: -> { Thread.list.size })
      @native = native
      @threads = threads
    end

    def available? = !@native.nil?

    # Starts measuring; #sample then reports from here.
    def start
      # @type ivar @native: Object & _Native
      return unless @native

      @native.start
      @last = reading
    end

    def stop = @native&.stop

    # The contention since the last sample (or #start), as a percentage
    # rounded to 0.1, or nil when it isn't measuring.
    def sample
      return unless @last

      now = reading
      waited = now.first - @last.first
      elapsed = now.last - @last.last
      @last = now
      possible = (@threads.call - 1) * elapsed
      return 0.0 unless possible.positive?

      [100.0 * waited / possible, 100.0].min.round(1) #: Float
    end

    private

    # Nanoseconds waited so far, and now (monotonic nanoseconds).
    def reading
      # (Only called once #start found the extension.)
      # @type ivar @native: Object & _Native
      [@native.wait_ns, Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)]
    end
  end
end
