# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"
begin
  require "active_support/broadcast_logger"
rescue LoadError
  # ActiveSupport::BroadcastLogger is unavailable on older supported Rails.
end
require "opentelemetry/sdk/trace/export/in_memory_span_exporter"

RSpec.describe "Logger capture", uninstalled: true do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:output) { StringIO.new }
  let(:secondary_output) { StringIO.new }
  let(:logger) do
    if defined?(ActiveSupport::BroadcastLogger)
      ActiveSupport::BroadcastLogger.new(
        ActiveSupport::TaggedLogging.new(Logger.new(output)),
        ActiveSupport::TaggedLogging.new(Logger.new(secondary_output))
      )
    else
      ActiveSupport::TaggedLogging.new(Logger.new(output))
    end
  end
  let(:output_mode) { :delayed }

  before do
    @global_provider = OpenTelemetry.tracer_provider
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    OtelLogging.configure do |config|
      config.output_mode = RSpec.current_example.metadata[:hybrid] ? :live_delayed_on_error : output_mode
      config.colorize = false
    end
    OtelLogging.install!(logger: logger, tracer_provider: provider)
  end

  after do
    provider.shutdown
    OtelLogging::TraceContext.reset!
  end

  def finished_trace
    exporter.finished_spans.find { |span| span.name == "capture" }
  end

  def captured_events
    finished_trace.events.select { |event| event.attributes.key?("log.severity") }
  end

  it "captures standard Logger methods and preserves lazy block and progname semantics" do
    evaluated = false
    logger.level = Logger::INFO

    OtelLogging.with_trace("capture") do
      logger.debug { evaluated = true; "debugged" }
      logger.info("info message")
      logger.warn("warn message")
      logger.error("error message")
      logger.fatal("fatal message")
      logger.add(Logger::INFO, "added message", "added-prog")
      logger.log(Logger::WARN, "logged message", "logged-prog")
    end

    expect(evaluated).to be(false)
    expect(captured_events.map { |event| event.attributes["log.severity"] }).to eq(
      [Logger::INFO, Logger::WARN, Logger::ERROR, Logger::FATAL, Logger::INFO, Logger::WARN]
    )
    expect(captured_events.map { |event| event.attributes["log.progname"] }).to include("added-prog", "logged-prog")
  end

  it "writes event and add calls normally outside a trace" do
    expect(logger.add(Logger::INFO, "outside add", "outside-prog")).to be(true)
    ActiveSupport.event_reporter.notify("outside.event", answer: 42)

    expect(output.string).to include("outside add", "outside.event")
    expect(exporter.finished_spans).to be_empty
  end

  it "keeps block-form progname and message semantics" do
    OtelLogging.with_trace("capture") { logger.info("component") { "block message" } }

    event = captured_events.find { |candidate| candidate.name == "block message" }
    expect(event.attributes["log.progname"]).to eq("component")
  end

  it "adds structured event attributes to the current span" do
    OtelLogging.with_trace("capture") do
      ActiveSupport.event_reporter.notify("custom.event", answer: 42)
    end

    event = finished_trace.events.find { |candidate| candidate.name == "custom.event" }
    expect(event.attributes).to include("log.severity" => Logger::INFO, "answer" => 42)
  end

  it "associates logs with a manually activated OpenTelemetry child span" do
    OtelLogging.with_trace("capture") do
      manual = provider.tracer("manual").start_span("manual.child")
      token = OpenTelemetry::Context.attach(OpenTelemetry::Trace.context_with_span(manual))
      logger.info("manual message")
      OpenTelemetry::Context.detach(token)
      manual.finish
    end

    manual_span = exporter.finished_spans.find { |span| span.name == "manual.child" }
    expect(manual_span.events.map(&:name)).to include("manual message")
    expect((exporter.finished_spans.find { |span| span.name == "capture" }.events || []).map(&:name)).not_to include("manual message")
  end

  it "does not replace the SDK global provider" do
    expect(OpenTelemetry.tracer_provider).to be(@global_provider)
    expect(OtelLogging.tracer_provider).to be(provider)
  end

  it "does not route raw stdout or stderr writes through the logger" do
    stdout = StringIO.new
    stderr = StringIO.new
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = stdout
    $stderr = stderr
    OtelLogging.with_trace("capture") do
      puts "raw stdout"
      warn "raw stderr"
    end
  ensure
    $stdout = original_stdout
    $stderr = original_stderr

    expect(stdout.string).to include("raw stdout")
    expect(stderr.string).to include("raw stderr")
    expect(output.string).not_to include("raw stdout", "raw stderr")
  end

  it "captures a tag snapshot for nested tagged logger clones" do
    mutable = String.new("before")
    OtelLogging.with_trace("capture") do
      logger.tagged("outer") do
        logger.tagged(mutable) do
          logger.info("nested message")
          mutable.replace("after")
        end
      end
    end

    event = captured_events.find { |candidate| candidate.name == "nested message" }
    expect(event.attributes["log.tags"]).to eq(["outer", "before"])
  end

  it "supports a single TaggedLogging instance and chained non-block clones" do
    single = ActiveSupport::TaggedLogging.new(Logger.new(StringIO.new))
    single.extend(OtelLogging::LoggerExtension)

    OtelLogging.with_trace("capture") do
      clone = single.tagged("one").tagged("two")
      clone.info("chained tags")
    end

    event = captured_events.find { |candidate| candidate.name == "chained tags" }
    expect(event.attributes["log.tags"]).to eq(["one", "two"])
  end

  it "keeps tags isolated across threads" do
    OtelLogging.with_trace("capture") do
      logger.tagged("main") { logger.info("main message") }
      thread = Thread.new do
        OtelLogging.with_trace("worker.trace") { logger.tagged("worker") { logger.info("worker message") } }
      end
      thread.join
    end

    events = exporter.finished_spans.flat_map(&:events).to_h do |event|
      [event.name, event.attributes["log.tags"]]
    end
    expect(events["main message"]).to eq(["main"])
    expect(events["worker message"]).to eq(["worker"])
  end

  it "outputs a captured event once in delayed mode" do
    OtelLogging.with_trace("capture") { logger.info("once only") }

    expect(output.string.scan("once only").length).to eq(1)
  end

  it "replays the complete successful root in hybrid mode for error logs", hybrid: true do
    OtelLogging.with_trace("capture") do
      logger.info("before error")
      logger.error("recoverable error")
      logger.info("after error")
    end

    expect(output.string).to include("capture", "before error", "recoverable error", "after error")
    expect(output.string.scan("recoverable error").length).to eq(2)
  end

  it "broadcasts one captured event to each destination" do
    skip "ActiveSupport::BroadcastLogger is unavailable" unless defined?(ActiveSupport::BroadcastLogger)

    OtelLogging.with_trace("capture") { logger.info("broadcast once") }

    expect(output.string.scan("broadcast once").length).to eq(1)
    expect(secondary_output.string.scan("broadcast once").length).to eq(1)
  end

  it "respects each broadcast sink's severity threshold" do
    skip "ActiveSupport::BroadcastLogger is unavailable" unless defined?(ActiveSupport::BroadcastLogger)

    logger.broadcasts[1].level = Logger::ERROR
    logger.info("secondary filtered")
    logger.error("secondary accepted")

    expect(output.string).to include("secondary filtered", "secondary accepted")
    expect(secondary_output.string).not_to include("secondary filtered")
    expect(secondary_output.string).to include("secondary accepted")
  end
end
