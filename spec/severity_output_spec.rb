# frozen_string_literal: true

require "spec_helper"

RSpec.describe "exporter severity output", uninstalled: true do
  let(:output) { StringIO.new }
  let(:logger) { Logger.new(output) }
  let(:provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }

  before do
    OtelLogging.config.output_mode = RSpec.current_example.metadata.fetch(:output_mode, :live_delayed_on_error)
    OtelLogging.install!(logger: logger, tracer_provider: provider)
  end

  after do
    provider.shutdown
    OtelLogging::TraceContext.reset!
  end

  it "replays an error event in the delayed-on-error tree" do
    logger.level = Logger::DEBUG
    OtelLogging.with_trace("request") { logger.error("failed") }

    expect(output.string.scan("failed").length).to eq(2)
  end

  it "keeps warning context while filtering informational events and attributes", output_mode: :delayed do
    logger.level = Logger::WARN

    OtelLogging.with_trace("request", attributes: { "root.info" => "hidden" }) do
      ActiveSupport.event_reporter.notify("info.event", detail: "hidden")
      OtelLogging.with_span("operation", attributes: { "span.info" => "hidden" }) do
        logger.warn("warning visible")
      end
    end

    text = output.string
    expect(text).to include("request", "operation", "WARN warning", "visible")
    expect(text).not_to include("info.event", "hidden")
  end

  it "promotes live root and child headings when a warning becomes visible", output_mode: :live do
    logger.level = Logger::WARN

    OtelLogging.with_trace("request", attributes: { "root.info" => "hidden" }) do
      OtelLogging.with_span("operation", attributes: { "span.info" => "hidden" }) do
        logger.warn("warning visible")
      end
    end

    text = output.string
    expect(text.scan("◆ request").length).to eq(1)
    expect(text.scan("◆ operation").length).to eq(1)
    expect(text).to include("WARN warning", "visible")
    expect(text).not_to include("root.info", "span.info")
  end

  it "promotes headings independently for broadcast destinations", output_mode: :live do
    skip "BroadcastLogger requires Rails 7.1+" unless defined?(ActiveSupport::BroadcastLogger)
    info_output = StringIO.new
    warn_output = StringIO.new
    info_logger = Logger.new(info_output)
    warn_logger = Logger.new(warn_output)
    warn_logger.level = Logger::WARN
    broadcast = ActiveSupport::BroadcastLogger.new(info_logger, warn_logger)
    broadcast.extend(OtelLogging::LoggerExtension)
    exporter = OtelLogging::Exporters::Live.new(broadcast)
    provider.add_span_processor(exporter)
    OtelLogging.live_exporter = exporter

    OtelLogging.with_trace("request") do
      broadcast.warn("warning visible")
    end

    expect(info_output.string.scan("◆ request").length).to eq(1)
    expect(warn_output.string.scan("◆ request").length).to eq(1)
  end

  it "keeps live ancestor context for a rescued SDK failure", output_mode: :live do
    logger.level = Logger::WARN
    tracer = provider.tracer("failure-spec")

    OtelLogging.with_trace("request", attributes: { "root.info" => "hidden" }) do
      child = tracer.start_span("failed.child")
      child.record_exception(RuntimeError.new("failure detail"))
      child.status = OpenTelemetry::Trace::Status.error("failure detail")
      child.finish
    end

    expect(output.string.scan("◆ request").length).to eq(1)
    expect(output.string.scan("◆ failed.child").length).to eq(1)
    expect(output.string).to include("trace", "failure detail", "ERROR")
    expect(output.string).not_to include("root.info", "hidden")
  end

  it "retains error and fatal events at a warning threshold", output_mode: :delayed do
    logger.level = Logger::WARN

    OtelLogging.with_trace("request") do
      logger.error("error event")
      logger.fatal("fatal event")
    end

    expect(output.string).to include("ERROR error event", "FATAL fatal event")
  end

  it "does not treat an informational event named exception as an SDK exception" do
    logger.level = Logger::DEBUG

    OtelLogging.with_trace("request") do
      ActiveSupport.event_reporter.notify("exception", detail: "ordinary")
    end

    expect(output.string.scan("INFO exception").length).to eq(1)
    expect(output.string).not_to include("ERROR exception")
  end

  it "uses the active SDK child span for live event depth", output_mode: :live do
    logger.level = Logger::DEBUG
    tracer = provider.tracer("severity-output-spec")

    OtelLogging.with_trace("request") do
      child = tracer.start_span("sdk.child")
      token = OpenTelemetry::Context.attach(OpenTelemetry::Trace.context_with_span(child))
      begin
        logger.info("child event")
      ensure
        OpenTelemetry::Context.detach(token)
        child.finish
      end
    end

    expect(output.string).to include("│ ├ + INFO child event")
  end
end
