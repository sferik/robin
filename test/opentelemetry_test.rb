# frozen_string_literal: true

require_relative "test_helper"
require "opentelemetry/sdk"
require "robin/opentelemetry"

class OpenTelemetryTest < RobinTest
  cover "Robin::OpenTelemetry*"

  EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
  PROVIDER = OpenTelemetry::SDK::Trace::TracerProvider.new.tap do |provider|
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER))
  end
  TRACE_CONTEXT = OpenTelemetry::Trace::Propagation::TraceContext.text_map_propagator

  class Job
    include Robin::Job

    def perform(*) = nil
  end

  def setup
    super
    EXPORTER.reset
    @propagation = OpenTelemetry.propagation
    OpenTelemetry.propagation = TRACE_CONTEXT
  end

  def teardown
    OpenTelemetry.propagation = @propagation
    super
  end

  def install(**) = Robin::OpenTelemetry.install(config, tracer_provider: PROVIDER, **)

  def spans = EXPORTER.finished_spans

  def tracer = PROVIDER.tracer("test")

  def pushed_payload
    Robin.load_json(redis("LRANGE", config.key("queue", "default"), 0, -1).last)
  end

  # Runs the server chain for +payload+ around +block+.
  def run_job(payload, queue = "default", &block)
    block ||= -> {}
    config.server_middleware.invoke(Job.new, payload, queue, &block)
  end

  def test_install
    assert_same config, install
    assert_equal Robin::OpenTelemetry::ClientMiddleware, config.client_middleware.entries.first.klass
    assert_equal Robin::OpenTelemetry::ServerMiddleware, config.server_middleware.entries.first.klass
    error = assert_raises(ArgumentError) { install(parent: :sibling) }
    assert_equal "parent: must be :child or :link", error.message
    install(parent: :link)
    middleware = config.server_middleware.entries.first.build

    assert_equal :link, middleware.instance_variable_get(:@parent)
    assert_equal 1, config.server_middleware.count { |e| e.klass == Robin::OpenTelemetry::ServerMiddleware }
  end

  def test_install_defaults_to_the_global_tracer_provider
    previous = OpenTelemetry.tracer_provider
    OpenTelemetry.tracer_provider = PROVIDER
    Robin::OpenTelemetry.install(config)
    Job.perform_async

    assert_equal ["publish default"], spans.map(&:name)
    assert_equal :child, config.server_middleware.entries.first.build.instance_variable_get(:@parent)
  ensure
    OpenTelemetry.tracer_provider = previous
  end

  def test_push_opens_a_producer_span_and_carries_the_context
    install
    jid = nil
    tracer.in_span("request") { jid = Job.set(queue: "mail").perform_async(1) }
    publish, request = spans
    payload = Robin.load_json(redis("LRANGE", config.key("queue", "mail"), 0, -1).last)

    assert_equal ["publish mail", :producer], [publish.name, publish.kind]
    assert_equal ["robin", Robin::VERSION], [publish.instrumentation_scope.name, publish.instrumentation_scope.version]
    assert_equal request.span_id, publish.parent_span_id
    assert_equal({"messaging.system" => "robin", "messaging.operation.type" => "publish", "messaging.destination.name" => "mail",
                  "messaging.message.id" => jid, "robin.job.class" => "OpenTelemetryTest::Job"}, publish.attributes)
    assert_equal "00-#{publish.hex_trace_id}-#{publish.hex_span_id}-01", payload.fetch("otel").fetch("traceparent")
  end

  def test_no_context_without_a_propagator
    OpenTelemetry.propagation = OpenTelemetry::Context::Propagation::NoopTextMapPropagator.new
    install
    Job.perform_async

    refute pushed_payload.key?("otel")
    assert_equal 1, spans.size
  end

  def test_process_span_is_a_child_of_the_push
    install
    Job.perform_async(1)
    payload = pushed_payload.merge("retry_count" => 2)
    inside = nil
    run_job(payload, "default") { inside = OpenTelemetry::Trace.current_span }
    publish, process = spans

    assert_equal ["process default", :consumer], [process.name, process.kind]
    assert_equal [publish.trace_id, publish.span_id], [process.trace_id, process.parent_span_id]
    assert_equal process.span_id, inside.context.span_id
    assert_equal "process", process.attributes.fetch("messaging.operation.type")
    assert_equal "default", process.attributes.fetch("messaging.destination.name")
    assert_equal 2, process.attributes.fetch("robin.job.retry_count")
    assert_equal payload.fetch("jid"), process.attributes.fetch("messaging.message.id")
  end

  def test_process_span_without_a_pushed_context_is_a_root
    install
    run_job({"jid" => "j", "class" => "C"})

    assert_equal [OpenTelemetry::Trace::INVALID_SPAN_ID], spans.map(&:parent_span_id)
  end

  def test_failures_are_recorded_and_raised
    install
    error = assert_raises(RuntimeError) { run_job({"jid" => "j", "class" => "C"}) { raise "boom" } }
    span = spans.first

    assert_equal "boom", error.message
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
    assert_equal ["exception"], span.events.map(&:name)
  end

  def test_returns_what_the_job_returned
    install

    assert_equal :done, run_job({"jid" => "j", "class" => "C"}) { :done }
  end

  def test_link_mode_starts_a_new_trace
    install(parent: :link)
    Job.perform_async
    publish = spans.first
    inside = nil
    tracer.in_span("unrelated") do
      run_job(pushed_payload) { inside = OpenTelemetry::Trace.current_span }
    end
    process = spans.find { |s| s.name == "process default" }

    refute_equal publish.trace_id, process.trace_id
    assert_equal OpenTelemetry::Trace::INVALID_SPAN_ID, process.parent_span_id
    assert_equal [[publish.trace_id, publish.span_id]], process.links.map { |l| [l.span_context.trace_id, l.span_context.span_id] }
    assert_equal process.span_id, inside.context.span_id
    assert_equal "process", process.attributes.fetch("messaging.operation.type")
  end

  def test_link_mode_without_a_pushed_context
    install(parent: :link)
    run_job({"jid" => "j", "class" => "C"})

    assert_nil spans.first.links
    assert_equal :consumer, spans.first.kind
  end
end
