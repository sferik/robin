# frozen_string_literal: true

require "active_job"
require "active_job/base" # what ActiveJob::Arguments needs

module Robin
  module Rails
    # Carries ActiveSupport::CurrentAttributes from where a job is pushed
    # into the job, so that e.g. Current.user and Current.tenant are set
    # while it runs:
    #
    #   config.robin.current_attributes = ["Current"] # class names
    #
    # Pushing saves each class's attributes in the job, the first listed
    # class's under "cattr", the next under "cattr_1" and so on, serialized
    # the way ActiveJob serializes arguments, so records travel as
    # GlobalIDs. Running sets them around the job, inside the Rails
    # executor (which resets them afterwards). Classes are looked up by
    # name on every push and run, so code reloading keeps working.
    #
    # The attributes are stored in Redis as they are: unlike encrypted
    # arguments, they're readable there and in the dashboard.
    module CurrentAttributes
      # The job field holding the attributes of the class at +index+ in
      # the configured list.
      def self.key_at(index) = index.zero? ? "cattr" : "cattr_#{index}"

      # [field, class name] for each configured class.
      def self.fields(names) = Array(names).each_with_index.map { |name, i| [key_at(i), name.to_s] }

      # Saves the attributes into jobs being pushed.
      class Save
        include Robin::Middleware::Stateless

        def initialize(names)
          @fields = CurrentAttributes.fields(names)
        end

        def call(_job_class, payload, _queue, _redis)
          @fields.each do |key, name|
            next if payload.key?(key)

            attributes = name.constantize.attributes
            payload[key] = ::ActiveJob::Arguments.serialize(attributes) unless attributes.empty?
          end
          yield
        end
      end

      # Sets the saved attributes while a job runs.
      class Load
        include Robin::Middleware::Stateless

        def initialize(names)
          @fields = CurrentAttributes.fields(names)
        end

        def call(_job, payload, _queue, &) = set(@fields.select { |key, _| payload.key?(key) }, payload, &)

        private

        # Nests one CurrentAttributes.set per class around the job. A class
        # that no longer exists (renamed since the push) is skipped.
        def set(fields, payload, &job)
          return yield if fields.empty?

          key, name = fields.fetch(0)
          rest = fields.drop(1)
          klass = name.safe_constantize
          return set(rest, payload, &job) unless klass

          # An attribute removed since the push is left out.
          attributes = ::ActiveJob::Arguments.deserialize(payload.fetch(key)).to_h
          attributes = attributes.select { |name, _| klass.method_defined?(:"#{name}=") }
          klass.set(attributes) { set(rest, payload, &job) }
        end
      end

      def self.install(config, names)
        names = Array(names)
        return if names.empty?

        config.client_middleware { |chain| chain.add(Save, names) }
        config.server_middleware { |chain| chain.prepend(Load, names) }
      end
    end
  end
end
