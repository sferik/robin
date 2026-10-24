# frozen_string_literal: true

module Robin
  # Middleware wraps job pushes (client side) and job execution (server
  # side), Rack style.
  #
  # Client middleware:
  #
  #   class AddTenant
  #     def call(job_class, payload, queue, redis)
  #       payload["tenant"] ||= Current.tenant
  #       yield # return nil instead of yielding to stop the push
  #     end
  #   end
  #
  # Server middleware:
  #
  #   class TimeIt
  #     def call(job, payload, queue)
  #       t = Time.now
  #       yield
  #     ensure
  #       puts "took #{Time.now - t}s"
  #     end
  #   end
  #
  # Middleware classes may define +initialize(*args)+ to receive arguments
  # passed to Chain#add. If they include Robin::Middleware::ConfigAware
  # they also get access to the Robin config.
  #
  # A middleware is built anew for every job, unless it includes
  # Robin::Middleware::Stateless: then one instance serves every job, on
  # every thread, so it must not keep per-job state in instance variables.
  #
  # A middleware that only matters to some jobs can say which with a class
  # method +applies?+, taking +call+'s arguments: the chain skips it (and
  # doesn't build it) when that's false.
  #
  #   class Audit
  #     def self.applies?(_job, payload, _queue) = payload.key?("audit")
  #     ...
  #   end
  module Middleware
    module ConfigAware
      attr_accessor :config

      def redis(&) = config.redis(&)

      def logger = config.logger
    end

    module Stateless; end

    class Entry
      attr_reader :klass

      def initialize(config, klass, args)
        @config = config
        @klass = klass
        @args = args
        @stateless = klass.include?(Stateless)
        @filtered = klass.respond_to?(:applies?)
      end

      def applies?(args) = !@filtered || @klass.applies?(*args)

      # The instance to call. A stateless middleware's is built once (two
      # threads racing to build it first is harmless).
      def build
        return @instance ||= instantiate if @stateless

        instantiate
      end

      private

      def instantiate
        instance = @klass.new(*@args)
        instance.config = @config if instance.respond_to?(:config=)
        instance
      end
    end

    class Chain
      include Enumerable

      def initialize(config)
        @config = config
        @entries = [] #: Array[Entry]
          .freeze
      end

      # Frozen: change the chain with its methods.
      attr_reader :entries

      def each(&) = @entries.each(&)

      # The chain is replaced on every change, never changed in place, so a
      # job being invoked keeps the middleware it started with (and a dup'd
      # chain changes independently).
      def add(klass, *args)
        @entries = (without(klass) << Entry.new(@config, klass, args)).freeze
        self
      end

      def prepend(klass, *args)
        @entries = without(klass).unshift(Entry.new(@config, klass, args)).freeze
        self
      end

      def insert_before(target, klass, *args)
        entries = without(klass)
        index = entries.index { |e| e.klass.equal?(target) } || 0
        @entries = entries.insert(index, Entry.new(@config, klass, args)).freeze
        self
      end

      def insert_after(target, klass, *args)
        entries = without(klass)
        index = entries.index { |e| e.klass.equal?(target) } || (entries.size - 1)
        @entries = entries.insert(index + 1, Entry.new(@config, klass, args)).freeze
        self
      end

      def remove(klass)
        @entries = without(klass).freeze
        self
      end

      def exists?(klass)
        any? { |e| e.klass.equal?(klass) }
      end

      def empty? = @entries.empty?

      def clear
        @entries = [] #: Array[Entry]
          .freeze
        self
      end

      # Invokes the chain around the block, outermost middleware first.
      # Each middleware is instantiated as the chain reaches it. Returns the
      # block's value, or whatever a middleware that halted the chain
      # returned instead of yielding.
      def invoke(*args, &block)
        call_from(@entries, 0, args, block)
      end

      private

      # Calls the first middleware from +index+ on that applies; yielding
      # calls the next one. (No closures are built per job, so a long chain
      # costs little.)
      def call_from(entries, index, args, block)
        index += 1 while (entry = entries.at(index)) && !entry.applies?(args)
        return block.call unless entry

        entry.build.call(*args) { call_from(entries, index + 1, args, block) }
      end

      def without(klass) = reject { |e| e.klass.equal?(klass) }
    end
  end
end
