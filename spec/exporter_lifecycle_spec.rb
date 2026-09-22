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

  [:live, :delayed, :both, :live_delayed_on_error].each do |mode|
    context "in #{mode} mode" do
      it 'shows a rescued child failure without marking its ancestors as failed' do
        install_mode(mode)
        root = child = nil
        otel_logger.with_trace('successful.root') do |span|
          root = span
          otel_logger.with_span('successful.parent') do
            begin
              otel_logger.with_span('failed.child') do |failed_span|
                child = failed_span
                raise 'pricing unavailable'
              end
            rescue RuntimeError
              otel_logger.event('prices.fallback_to_cache')
            end
          end
        end

        output = otel_output.string
        expect(output).to include('pricing unavailable', 'prices.fallback_to_cache')
        expect(output.lines.grep(/◆ failed.child/).last).to include('ERROR', 'ms')
        expect(output.lines.grep(/◆ successful\./).join).not_to include('ERROR', 'RESCUED')
        expect(child.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
        expect(root.status.code).not_to eq(OpenTelemetry::Trace::Status::ERROR)
        if mode == :live_delayed_on_error
          expect(output.lines.grep(/^trace /).size).to eq(2)
          expect(output.lines.grep(/◆ successful.root/).last).to include('ms')
        end
        expect(OtelLogging::TraceContext.current.active?).to be false
        expect(OpenTelemetry::Trace.current_span.context.valid?).to be false
      end

      it 'shows an explicitly recorded exception on a successful span' do
        install_mode(mode)
        child = nil
        otel_logger.with_trace('successful.root') do
          otel_logger.with_span('recovered.child') do |span|
            child = span
            begin
              raise 'temporary failure'
            rescue RuntimeError => error
              span.record_exception(error)
            end
            span.status = OpenTelemetry::Trace::Status.ok
          end
        end

        expect(otel_output.string).to include('exception', 'temporary failure')
        expect(otel_output.string.lines.grep(/◆ /).join).not_to include('ERROR', 'RESCUED')
        expect(child.status.code).to eq(OpenTelemetry::Trace::Status::OK)
        if mode == :live_delayed_on_error
          expect(otel_output.string.lines.grep(/^trace /).size).to eq(2)
        end
      end

      it 'shows an error status without an exception' do
        install_mode(mode)
        otel_logger.with_trace('successful.root') do
          otel_logger.with_span('failed.child') do |span|
            span.status = OpenTelemetry::Trace::Status.error('upstream rejected request')
          end
        end

        expect(otel_output.string.lines.grep(/◆ failed.child/).last).to include('ERROR')
        expect(otel_output.string.lines.grep(/◆ successful.root/).join).not_to include('ERROR')
      end
    end
  end

  it 'does not repeat a successful trace in hybrid mode' do
    install_mode(:live_delayed_on_error)
    otel_logger.with_trace('successful.root') do
      otel_logger.with_span('successful.child') { otel_logger.event('work.done') }
    end

    expect(otel_output.string.lines.grep(/^trace /).size).to eq(1)
    expect(otel_output.string).not_to include('ms', 'ERROR', 'EXCEPTION')
  end
end
