# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'OtelLogging installation', uninstalled: true do
  let(:output) { StringIO.new }
  let(:logger) { ActiveSupport::Logger.new(output) }
  let(:provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }

  before do
    OtelLogging.configure { |config| config.output_mode = :live }
  end

  it 'keeps the SDK global provider unchanged' do
    global_provider = OpenTelemetry.tracer_provider

    OtelLogging.install!(logger: logger, tracer_provider: provider)

    expect(OpenTelemetry.tracer_provider).to be(global_provider)
    expect(OtelLogging.tracer_provider).to be(provider)
    expect(OtelLogging.logger).to be(logger)
  end

  it 'is idempotent for the same logger and provider' do
    expect(provider).to receive(:add_span_processor).once

    OtelLogging.install!(logger: logger, tracer_provider: provider)
    OtelLogging.install!(logger: logger, tracer_provider: provider)
  end

  it 'attaches processors once when installation races across threads' do
    calls = 0
    calls_mutex = Mutex.new
    allow(provider).to receive(:add_span_processor) do
      calls_mutex.synchronize { calls += 1 }
    end

    threads = 2.times.map do
      Thread.new { OtelLogging.install!(logger: logger, tracer_provider: provider) }
    end
    threads.each(&:join)

    expect(calls).to eq(1)
  end

  it 'rejects a conflicting repeat installation' do
    OtelLogging.install!(logger: logger, tracer_provider: provider)

    expect {
      OtelLogging.install!(logger: ActiveSupport::Logger.new(StringIO.new), tracer_provider: provider)
    }.to raise_error(ArgumentError, /already installed/i)
  end
end
