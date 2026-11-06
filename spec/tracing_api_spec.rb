# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'module tracing API' do
  it 'creates a root from with_span and always yields a span' do
    expect(OtelLogging.with_span('root') { |span| expect(span).to be_recording; 42 }).to eq(42)
    expect(otel_output.string).to include('◆ root')
    expect(OtelLogging.current_span_id).to be_nil
    expect(OtelLogging.current_trace_id).to be_nil
  end

  it 'starts independent traces and restores the enclosing span' do
    OtelLogging.with_span('parent') do |parent|
      OtelLogging.with_trace do |root|
        expect(root.name).to eq('trace')
        expect(root.context.trace_id).not_to eq(parent.context.trace_id)
        expect(root.parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
      end
      expect(OpenTelemetry::Trace.current_span).to equal(parent)
    end
  end

  it 'exports serializable context and continues it without opening an extra span' do
    parent = nil
    context = OtelLogging.with_span('request') do |span|
      parent = span
      OtelLogging.trace_context
    end
    carrier = JSON.parse(JSON.generate(context))
    otel_output.truncate(0)
    otel_output.rewind
    OtelLogging.with_trace(context: carrier) do
      expect(OtelLogging.current_trace_id).to eq(parent.context.hex_trace_id)
      expect(OpenTelemetry::Trace.current_span).not_to be_recording
      OtelLogging.with_span('job') do |job|
        expect(job.parent_span_id).to eq(parent.context.span_id)
        expect(job.context.trace_id).to eq(parent.context.trace_id)
        otel_logger.info('job message')
        expect(otel_output.string).to be_empty
      end
      expect(otel_output.string.scan('◆ job').size).to eq(1)
      expect(otel_output.string.scan('job message').size).to eq(1)
    end
    expect(OtelLogging.current_trace_id).to be_nil
  end

  it 'keeps explicitly supplied local parents in one output tree' do
    OtelLogging.with_span('parent') do |parent|
      OtelLogging.with_span('child', context: OtelLogging.trace_context) do |child|
        expect(child.parent_span_id).to eq(parent.context.span_id)
      end
      expect(otel_output.string).to be_empty
    end
    expect(otel_output.string.lines.grep(/trace /).size).to eq(1)
    expect(otel_output.string).to include('└ ◆ child')
  end

  it 'prints independent local trees for the same remote parent' do
    context = OtelLogging.with_span('request') { OtelLogging.trace_context }
    otel_output.truncate(0)
    otel_output.rewind
    first = OtelLogging::TraceContext.current.start_span('first', parent_context: OtelLogging.send(:extract_context, context))
    second = OtelLogging::TraceContext.current.start_span('second', parent_context: OtelLogging.send(:extract_context, context))
    second.finish
    expect(otel_output.string).to include('◆ second')
    expect(otel_output.string).not_to include('◆ first')
    first.finish
    expect(otel_output.string.lines.grep(/trace /).size).to eq(2)
  end

  it 'restores context and records an escaping exception' do
    expect do
      OtelLogging.with_span('failure') { raise 'broken' }
    end.to raise_error('broken')
    expect(otel_output.string).to include('broken', 'ERROR')
    expect(OtelLogging.current_span_id).to be_nil
    expect(OtelLogging::TraceContext.current.handles).to be_empty
  end

  it 'keeps tracing methods off the logger' do
    %i[with_trace with_span event current_span_id current_trace_id].each do |method|
      expect(otel_logger).not_to respond_to(method)
    end
  end

  it 'sets filtered attributes on the active span and is safe outside one' do
    OtelLogging.set_span_attribute('no.span', true)
    OtelLogging.with_span('attributes') do |span|
      OtelLogging.set_span_attribute('order.id', 123)
      expect(span.attributes['order.id']).to eq(123)
    end
  end
  it 'keeps contexts isolated between interleaved fibers' do
    fibers = 2.times.map do |id|
      Fiber.new do
        OtelLogging.with_span("fiber.#{id}") do |span|
          Fiber.yield span.context.hex_trace_id
          expect(OtelLogging.current_trace_id).to eq(span.context.hex_trace_id)
          otel_logger.info("fiber message #{id}")
        end
      end
    end
    ids = fibers.map(&:resume)
    expect(ids.uniq.size).to eq(2)
    fibers.reverse_each(&:resume)
    expect(OtelLogging.current_trace_id).to be_nil
    expect(otel_output.string.scan('◆ fiber.').size).to eq(2)
  end

  it 'retains already-started local children that finish after the local root' do
    child = nil
    OtelLogging.with_span('root') do
      child = otel_provider.tracer('async').start_span('late.child')
    end
    expect(otel_output.string).to be_empty
    child.finish
    expect(otel_output.string).to include('◆ root', '└ ◆ late.child')
  end

  it 'restores imported context on exceptions without creating a span' do
    carrier = OtelLogging.with_span('previous') { OtelLogging.trace_context }
    otel_output.truncate(0)
    otel_output.rewind
    expect do
      OtelLogging.with_trace(context: carrier) { raise 'context only' }
    end.to raise_error('context only')
    expect(otel_output.string).to be_empty
    expect(OtelLogging.current_trace_id).to be_nil
  end

end
