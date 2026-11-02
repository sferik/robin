# frozen_string_literal: true

require "robin"
require "opentelemetry"

module Robin
  # OpenTelemetry tracing for pushing and running jobs. Needs the
  # opentelemetry-api gem (and an SDK to export spans somewhere):
  #
  #   require "robin/opentelemetry"
  #
  #   Robin.configure do |config|
  #     Robin::OpenTelemetry.install(config)
  #   end
  #
  # Pushing a job opens a "publish <queue>" producer span and stores the
  # trace context in the job ("otel"). Running it opens a "process <queue>"
  # consumer span, a child of the push, so a request and the jobs it pushed
  # share one trace. With +parent: :link+ each run starts its own trace
  # instead, linked to the push (better for jobs that run long after they
  # were pushed). Spans follow the messaging semantic conventions, plus
  # robin.job.class and robin.job.retry_count.
  module OpenTelemetry
    def self.install(config, tracer_provider: ::OpenTelemetry.tracer_provider, parent: :child)
      raise ArgumentError, "parent: must be :child or :link" unless %i[child link].include?(parent)

      tracer = tracer_provider.tracer("robin", VERSION)
      config.client_middleware { |chain| chain.prepend(ClientMiddleware, tracer) }
      config.server_middleware { |chain| chain.prepend(ServerMiddleware, tracer, parent) }
      config
    end

    def self.attributes(payload, queue, operation)
      attrs = {
        "messaging.system" => "robin",
        "messaging.operation.type" => operation,
        "messaging.destination.name" => queue,
        "messaging.message.id" => payload.fetch("jid"),
        "robin.job.class" => payload.fetch("class")
      }
      attrs["robin.job.retry_count"] = payload.fetch("retry_count") if payload.key?("retry_count")
      attrs
    end

    class ClientMiddleware
      include Middleware::Stateless

      def initialize(tracer)
        @tracer = tracer
      end

      def call(_job_class, payload, queue, _redis)
        @tracer.in_span("publish #{queue}", kind: :producer, attributes: OpenTelemetry.attributes(payload, queue, "publish")) do
          carrier = {} #: Hash[String, String]
          ::OpenTelemetry.propagation.inject(carrier)
          payload["otel"] = carrier unless carrier.empty?
          yield
        end
      end
    end

    class ServerMiddleware
      include Middleware::Stateless

      def initialize(tracer, parent)
        @tracer = tracer
        @parent = parent
      end

      def call(_job, payload, queue, &)
        pushed = ::OpenTelemetry.propagation.extract(payload.fetch("otel", {}))
        attributes = OpenTelemetry.attributes(payload, queue, "process")
        name = "process #{queue}"
        return ::OpenTelemetry::Context.with_current(pushed) { @tracer.in_span(name, kind: :consumer, attributes: attributes, &) } if @parent == :child

        push = ::OpenTelemetry::Trace.current_span(pushed).context
        links = [::OpenTelemetry::Trace::Link.new(push)] if push.valid?
        detached { @tracer.in_span(name, kind: :consumer, attributes: attributes, links: links, &) }
      end

      private

      # mutant:disable -- Context.current reads an attached nil as the
      # empty context, so passing nil instead is the same.
      def detached(&) = ::OpenTelemetry::Context.with_current(::OpenTelemetry::Context.empty, &)
    end
  end
end
