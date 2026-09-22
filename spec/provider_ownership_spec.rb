# frozen_string_literal: true

require 'spec_helper'
require 'opentelemetry/sdk/trace/export/in_memory_span_exporter'
require 'otel_logging/rails'

RSpec.describe 'provider ownership', uninstalled: true do
  it 'does not configure the SDK or install processors when configuring settings' do
    original = OpenTelemetry.tracer_provider
    expect(OpenTelemetry::SDK).not_to receive(:configure)
    expect(otel_provider).not_to receive(:add_span_processor)

    OtelLogging.configure { |settings| settings.service_name = 'configured-only' }

    expect(OpenTelemetry.tracer_provider).to be(original)
    expect(OtelLogging.tracer_provider).to be_nil
  end

  it 'preserves the caller provider and its existing processor' do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    otel_provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    OtelLogging.install!(logger: otel_logger, tracer_provider: otel_provider)
    OtelLogging.install!(logger: otel_logger, tracer_provider: otel_provider)

    otel_logger.with_trace('owned.request') { otel_logger.event('owned.event') }

    expect(exporter.finished_spans.map(&:name)).to eq(['owned.request'])
    expect(exporter.finished_spans.first.events.map(&:name)).to include('owned.event')
    external_span = otel_provider.tracer('external-caller').start_span('still-active')
    expect(external_span.recording?).to be true
    external_span.finish
  end

  it 'keeps provider lifecycle under caller control' do
    expect(otel_provider).not_to receive(:shutdown)
    OtelLogging.install!(logger: otel_logger, tracer_provider: otel_provider)
    otel_logger.with_trace('request') { :ok }
  end

  it 'rejects a provider callback that returns nil instead of silently creating a provider' do
    OtelLogging.config.tracer_provider = -> { nil }

    expect {
      OtelLogging::RailsIntegration.install!(application: double('application'), logger: otel_logger)
    }.to raise_error(ArgumentError, /SDK tracer provider/)
    expect(OtelLogging.tracer_provider).to be_nil
  end

  it 'rejects the API no-op provider for Rails logging' do
    OtelLogging.config.tracer_provider = OpenTelemetry::Trace::TracerProvider.new

    expect {
      OtelLogging::RailsIntegration.install!(application: double('application'), logger: otel_logger)
    }.to raise_error(ArgumentError, /SDK tracer provider/)
    expect(OtelLogging.tracer_provider).to be_nil
  end
end
