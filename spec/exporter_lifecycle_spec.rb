# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'installed output processors', uninstalled: true do
  def install_mode(mode)
    OtelLogging.configure { |config| config.output_mode = mode }
    OtelLogging.install!(logger: otel_logger, tracer_provider: otel_provider)
  end

  it 'buffers a complete tree until the root finishes' do
    install_mode(:delayed)
    otel_logger.with_trace('request.root') do
      otel_logger.with_span('child.work') do
        otel_logger.event('work.done', count: 2)
      end
      expect(otel_output.string).to be_empty
    end

    expect(otel_output.string).to include('request.root', 'child.work', 'work.done', 'count', '2')
    expect(OtelLogging::TraceContext.current.active?).to be false
  end

  it 'uses only the supplied logger for live spans and events' do
    install_mode(:live)
    otel_logger.with_trace('live.root') do
      expect(otel_output.string).to include('live.root')
      otel_logger.event('live.event', state: 'ready')
      expect(otel_output.string).to include('live.event', 'ready')
    end
  end

  it 'prints a delayed error tree for a failed trace in hybrid mode' do
    install_mode(:live_delayed_on_error)
    expect do
      otel_logger.with_trace('failed.root') do
        otel_logger.with_span('failed.child') { raise 'operation failed' }
      end
    end.to raise_error('operation failed')

    expect(otel_output.string).to include('failed.root', 'failed.child', 'operation failed')
    expect(OtelLogging::TraceContext.current.active?).to be false
    expect(OpenTelemetry::Trace.current_span.context.valid?).to be false
  end
end
