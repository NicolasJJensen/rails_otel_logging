# frozen_string_literal: true

require 'spec_helper'
require 'active_support/tagged_logging'

RSpec.describe 'logger destinations', uninstalled: true do
  it 'preserves distinct destination tags through delayed output and tagged clones' do
    skip 'BroadcastLogger requires Rails 7.1+' unless defined?(ActiveSupport::BroadcastLogger)

    first_output = StringIO.new
    second_output = StringIO.new
    first = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(first_output))
    second = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(second_output))
    first.push_tags('file')
    second.push_tags('console')
    first.progname = 'file-program'
    second.progname = 'console-program'
    first.formatter.define_singleton_method(:call) do |severity, time, progname, message|
      "#{tags_text}#{progname}: #{message}\n"
    end
    second.formatter.define_singleton_method(:call) do |severity, time, progname, message|
      "#{tags_text}#{progname}: #{message}\n"
    end
    logger = ActiveSupport::BroadcastLogger.new(first, second)
    OtelLogging.install!(logger: logger, tracer_provider: otel_provider)

    OtelLogging.with_trace('request') do
      logger.tagged('scoped') { |tagged| tagged.info('scoped message') }
      logger.tagged('chained').info('chained message')
      expect(first_output.string).to be_empty
      expect(second_output.string).to be_empty
    end
    logger.info('after trace')

    expect(first_output.string).to include('[file] [scoped] file-program:', '[file] [chained]', '[file] file-program: after trace')
    expect(first_output.string).not_to include('[console]')
    expect(second_output.string).to include('[console] [scoped] console-program:', '[console] [chained]', '[console] console-program: after trace')
    expect(second_output.string).not_to include('[file]')
    expect(first_output.string.scan('chained message').size).to eq(1)
    expect(second_output.string.scan('chained message').size).to eq(1)
    expect(first.formatter.current_tags).to eq(['file'])
    expect(second.formatter.current_tags).to eq(['console'])
  end

  it 'writes normal logs when sampling disables recording' do
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
      sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF
    )
    logger = ActiveSupport::TaggedLogging.new(otel_logger)
    OtelLogging.install!(logger: logger, tracer_provider: provider)

    logger.tagged('request') do
      OtelLogging.with_trace('unsampled') do |span|
        expect(span).not_to be_nil
        expect(span.recording?).to be(false)
        expect(span.context).to be_valid
        logger.info('still visible')
        ActiveSupport.event_reporter.notify('structured', detail: 'retained')
      end
    end

    expect(otel_output.string).to include('[request] still visible', '[request] structured', 'retained')
    expect(otel_output.string).not_to include('◆')
  ensure
    provider&.shutdown
  end

  it 'does not evaluate blocks for a logger without an output device' do
    logger = Logger.new(nil)
    OtelLogging.install!(logger: logger, tracer_provider: otel_provider)

    OtelLogging.with_trace('discarded') do
      expect { logger.info { raise 'must not evaluate' } }.not_to raise_error
    end
    expect(logger).not_to respond_to(:tagged)
  end
end
