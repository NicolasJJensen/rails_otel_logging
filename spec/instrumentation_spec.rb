# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'notification instrumentation', uninstalled: true do
  def install(&rules)
    OtelLogging.config.instrumentation(&rules)
    OtelLogging.install!(logger: otel_logger, tracer_provider: otel_provider)
  end

  it 'defaults to the notification name and completed payload' do
    install { subscribe 'inventory.check' }
    ActiveSupport::Notifications.instrument('inventory.check', product_id: 123) do |payload|
      expect(OtelLogging.current_span_id).not_to be_nil
      payload[:available] = true
      otel_logger.info('checking')
    end
    expect(otel_output.string).to include('◆ inventory.check', 'product_id: 123', 'available: true', 'INFO checking')
    expect(OtelLogging.current_span_id).to be_nil
  end

  it 'does not interpret arbitrary application status attributes as HTTP errors' do
    install { subscribe 'check' }
    ActiveSupport::Notifications.instrument('check', status: 700) {}
    expect(otel_output.string).to include('status: 700')
    expect(otel_output.string).not_to include('ERROR')
  end

  it 'uses the first match and evaluates transformations at start and finish only' do
    observed = []
    install do
      subscribe ->(name, payload) { name == 'check.store' && payload[:selected] } do |name, payload|
        observed << payload[:complete]
        name name.delete_suffix('.store')
        attributes('done' => !!payload[:complete])
      end
      subscribe(/.*/)
    end
    ActiveSupport::Notifications.instrument('check.store', selected: true) { |payload| payload[:complete] = true }
    expect(observed).to eq([nil, true])
    expect(otel_output.string.scan('◆ check').size).to eq(1)
    expect(otel_output.string).to include('done: true')
    expect(otel_output.string).not_to include('selected:')
  end

  it 'selects using the start payload and does not select a new rule at finish' do
    install do
      subscribe ->(_name, payload) { payload[:ready] }
    end
    ActiveSupport::Notifications.instrument('check', ready: false) { |payload| payload[:ready] = true }
    expect(otel_output.string).to be_empty
  end

  it 'handles nested identical names, direct spans, and exceptions' do
    install { subscribe 'check' }
    expect do
      ActiveSupport::Notifications.instrument('check', depth: 1) do
        OtelLogging.with_span('direct') do
          ActiveSupport::Notifications.instrument('check', depth: 2) { raise 'failed operation' }
        end
      end
    end.to raise_error('failed operation')
    expect(otel_output.string.scan('◆ check').size).to eq(2)
    expect(otel_output.string).to include('◆ direct', 'failed operation', 'ERROR')
    expect(OtelLogging.current_span_id).to be_nil
    expect(OtelLogging::Instrumentation.frames).to be_empty
  end

  it 'isolates simultaneous transformation evaluations' do
    install do
      subscribe 'check' do |_name, payload|
        name "check.#{payload[:id]}"
        attributes(payload)
      end
    end
    entered = Queue.new
    release = Queue.new
    threads = 2.times.map do |id|
      Thread.new do
        ActiveSupport::Notifications.instrument('check', id: id) do
          entered << true
          release.pop
          otel_logger.info("message #{id}")
        end
      end
    end
    2.times { entered.pop }
    2.times { release << true }
    threads.each(&:value)
    expect(otel_output.string.scan('◆ check.0').size).to eq(1)
    expect(otel_output.string.scan('◆ check.1').size).to eq(1)
  end

  it 'reports invalid transformations without disrupting application work or cleanup' do
    install do
      subscribe 'check' do |_name, payload|
        raise 'mapping failed' if payload[:complete]
      end
    end
    result = ActiveSupport::Notifications.instrument('check') { |payload| payload[:complete] = true; 42 }
    expect(result).to eq(42)
    expect(otel_output.string).to include('mapping failed', '◆ check')
    expect(OtelLogging.current_span_id).to be_nil
  end

  it 'allows empty attributes and rejects invalid configuration early' do
    expect { OtelLogging.config.instrumentation { subscribe 123 } }.to raise_error(ArgumentError)
    install { subscribe('check') { attributes({}) } }
    ActiveSupport::Notifications.instrument('check', hidden: 'secret') {}
    expect(otel_output.string).not_to include('hidden:')
    expect { OtelLogging.config.instrumentation { subscribe 'late' } }.to raise_error(ArgumentError, /before installation/)
  end

  it 'does not capture notifications emitted by an output formatter' do
    otel_logger.formatter = proc do |_severity, _time, _program, message|
      ActiveSupport::Notifications.instrument('formatter.operation') { "#{message}\n" }
    end
    install { subscribe(/.*/) }
    ActiveSupport::Notifications.instrument('application.operation') { otel_logger.info('once') }
    expect(otel_output.string).to include('application.operation', 'once')
    expect(otel_output.string).not_to include('formatter.operation')
    expect(OtelLogging::Instrumentation.frames).to be_empty
  end
end
