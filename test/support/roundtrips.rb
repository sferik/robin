# frozen_string_literal: true

# Counts Redis round trips, so tests can pin how many a piece of Robin
# makes and a change that adds one fails:
#
#   assert_roundtrips 1 do
#     Robin.push(...)
#   end
#
# A round trip is one exchange with the server: a #call, a #pipelined
# block or a #multi block (however many commands it holds). Connecting
# (AUTH, SELECT, CLIENT SETNAME) isn't counted, so it doesn't matter
# whether the pool already had a connection; nor is loading a Lua script
# the server didn't have (Connection#evalsha's SCRIPT LOAD after a
# NOSCRIPT), so it doesn't matter whether another test (or process) ran
# it first, or flushed the scripts.
module RoundTrips
  # One round trip: the thread that made it and the commands it sent.
  Trip = Data.define(:thread, :commands) do
    # Loading a script the server didn't have, and running it again, after
    # +before+ (the trip before it) tried to run it alone. (A pipeline that
    # loads a script as it goes is a round trip like any other.)
    def reload?(before)
      return false unless before && commands.size == 2 && before.commands.size == 1

      load, run = commands
      load.first(2).map { |part| part.to_s.upcase } == %w[SCRIPT LOAD] &&
        run.first(2) == before.commands.first.first(2)
    end

    def to_s
      commands.reject { |c| %w[MULTI EXEC].include?(c.first.to_s.upcase) }.map { |c| RoundTrips.describe(c) }.join(" + ")
    end
  end

  # Records the trips the block's thread (or, with +all_threads+, every
  # thread) makes while it runs.
  class Recorder
    attr_reader :trips

    def initialize(thread)
      @thread = thread
      @trips = []
    end

    def add(trip) = (@trips << trip if @thread.nil? || @thread == trip.thread)
  end

  @mutex = Mutex.new
  @recorders = []

  class << self
    # Runs the block and returns [its value, the trips it made].
    def record(all_threads: false)
      recorder = Recorder.new(all_threads ? nil : Thread.current)
      @mutex.synchronize { @recorders << recorder }
      begin
        value = yield
      ensure
        @mutex.synchronize { @recorders.delete(recorder) }
      end
      [value, recorder.trips]
    end

    def seen(commands)
      return if @recorders.empty?

      trip = Trip.new(Thread.current, commands)
      @mutex.synchronize { @recorders.each { |r| r.add(trip) } }
    end

    # A command as a failure message shows it: its name, and the name of
    # the script for EVAL and EVALSHA (as Robin's constants call it).
    def describe(command)
      name = command.first.to_s.upcase
      case name
      when "EVAL" then "EVAL #{script_name(Digest::SHA1.hexdigest(command[1].to_s))}"
      when "EVALSHA" then "EVALSHA #{script_name(command[1])}"
      else [name, *command.drop(1).first(2)].join(" ")
      end
    end

    # Looks again when it doesn't know +sha+: the script may have been
    # loaded since.
    def script_name(sha) = scripts.fetch(sha) { (@scripts = nil) || scripts.fetch(sha) { sha[0, 8] } }

    # Robin's Lua scripts by SHA, found on first use.
    def scripts
      @scripts ||= ObjectSpace.each_object(Module).each_with_object({}) do |mod, found|
        next unless mod.name&.start_with?("Robin", "Sidekiq")

        mod.constants(false).each do |const|
          value = mod.const_get(const, false) if mod.const_defined?(const, false) && !mod.autoload?(const)
          found[value.sha] = "#{mod.name}::#{const}" if value.is_a?(Robin::Redis::Script)
        end
      end
    end
  end

  # Prepended to Robin::Redis::Connection.
  module Counting
    private

    def roundtrip(commands, read_timeout)
      RoundTrips.seen(commands)
      super
    end
  end

  module Assertions
    # Asserts the block makes +expected+ Redis round trips (an Integer, or
    # a Range when it varies) and returns its value. Counts the calling
    # thread's trips, or every thread's with +all_threads+.
    def assert_roundtrips(expected, all_threads: false, &)
      value, trips = RoundTrips.record(all_threads: all_threads, &)
      trips = trips.reject.with_index { |trip, i| trip.reload?(i.positive? && trips[i - 1]) }
      self.assertions += 1
      return value if expected === trips.size # rubocop:disable Style/CaseEquality -- an Integer or a Range

      listing = trips.each_with_index.map { |trip, i| "  #{i + 1}. #{trip}" }.join("\n")
      noun = (expected == 1) ? "round trip" : "round trips"

      flunk "Expected #{expected} Redis #{noun}, got #{trips.size}#{":\n#{listing}" unless trips.empty?}"
    end
  end
end

Robin::Redis::Connection.prepend(RoundTrips::Counting)
