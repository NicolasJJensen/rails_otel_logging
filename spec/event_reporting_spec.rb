# frozen_string_literal: true

require 'spec_helper'
require 'opentelemetry/sdk/trace/export/in_memory_span_exporter'

RSpec.describe 'structured event reporting' do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  before do
    allow(Rails).to receive(:application).and_return(nil) if defined?(Rails) && Rails.respond_to?(:application)
    otel_provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
  end

  after { ActiveSupport.event_reporter.clear_context }

  it 'retains event payload, tags, context, source, and original timestamp' do
    events = []
    observer = Object.new
    observer.define_singleton_method(:emit) { |event| events << event }
    ActiveSupport.event_reporter.subscribe(observer)
    ActiveSupport.event_reporter.set_context(tenant_id: 7)
    OtelLogging.with_span('request') do
      ActiveSupport.event_reporter.tagged('checkout', region: 'east') do
        ActiveSupport.event_reporter.notify('order.created', order_id: 123)
      end
    end
    event = exporter.finished_spans.first.events.first
    expect(event.name).to eq('order.created')
    expect(event.attributes).to include('order_id' => 123, 'rails.event.tags.checkout' => true,
      'rails.event.tags.region' => 'east', 'rails.event.context.tenant_id' => 7)
    expect(event.attributes['code.filepath']).to end_with('event_reporting_spec.rb')
    expect(event.timestamp).to be_within(1000).of(events.first[:timestamp])
    expect(events.size).to eq(1)
  ensure
    ActiveSupport.event_reporter.unsubscribe(observer) if observer
  end

  it 'handles empty payloads and event objects, filtering serialized fields' do
    event_class = Class.new do
      def self.name = 'CredentialsChecked'
      def serialize = { password: 'private-value', user_id: 5 }
    end
    OtelLogging.with_span('request') do
      ActiveSupport.event_reporter.notify('empty')
      ActiveSupport.event_reporter.notify(event_class.new)
    end
    expect(otel_output.string).to include('empty', 'CredentialsChecked', 'user_id: 5', '[FILTERED]')
    expect(otel_output.string).not_to include('private-value')
  end

  it 'filters serialized tag objects before recording their attributes' do
    tag_class = Class.new do
      def self.name = 'AccountTag'
      def serialize = { account_id: 42, token: 'private-token' }
    end
    OtelLogging.with_span('request') do
      ActiveSupport.event_reporter.tagged(tag_class.new) { ActiveSupport.event_reporter.notify('tagged') }
    end
    tags = exporter.finished_spans.first.events.first.attributes.fetch('rails.event.tags.AccountTag')
    expect(JSON.parse(tags)).to eq('account_id' => 42, 'token' => '[FILTERED]')
    expect(otel_output.string).not_to include('private-token')
  end

  it 'normalizes nested and unsupported payload values without mutating the payload' do
    object = Object.new
    def object.inspect = raise 'must not inspect arbitrary objects'
    payload = { nested: { password: 'private', items: [1, 'two'] },
                mixed: [1, nil, object, { password: 'private', value: 'two' }], object: object, missing: nil }
    OtelLogging.with_span('request', attributes: payload) {}
    attributes = exporter.finished_spans.first.attributes
    expect(JSON.parse(attributes['nested'])).to eq('password' => '[FILTERED]', 'items' => [1, 'two'])
    expect(JSON.parse(attributes['mixed'])).to eq([1, nil, nil, { 'password' => '[FILTERED]', 'value' => 'two' }])
    expect(attributes).not_to have_key('object')
    expect(attributes).not_to have_key('missing')
    expect(payload[:nested][:password]).to eq('private')
  end

  it 'reports serialization failures without losing the surrounding trace' do
    broken = Object.new
    def broken.serialize = raise 'cannot serialize'
    OtelLogging.with_span('request') do
      expect { ActiveSupport.event_reporter.notify(broken) }.not_to raise_error
      otel_logger.info('continued')
    end
    expect(otel_output.string).to include('cannot serialize', 'continued')
    expect(OtelLogging.current_span_id).to be_nil
  end

  it 'uses the Rails application parameter filters when an application is present' do
    stub_const('Rails', double(application: double(config: double(filter_parameters: [:customer_key]))))
    OtelLogging.with_span('request', attributes: { customer_key: 'private', password: 'configured-by-app' }) {}
    expect(exporter.finished_spans.first.attributes).to include('customer_key' => '[FILTERED]', 'password' => 'configured-by-app')
    expect(otel_output.string).not_to include('private')
  end

  it 'does not infer errors from names or treat payload severity as a logger option' do
    OtelLogging.with_span('request') do
      ActiveSupport.event_reporter.notify('payment.failed', severity: 'error')
    end
    span = exporter.finished_spans.first
    expect(span.events.first.attributes).to include('severity' => 'error', 'log.severity' => Logger::INFO)
    expect(span.status.code).not_to eq(OpenTelemetry::Trace::Status::ERROR)
  end

  it 'honors reporter debug gating without inventing a DEBUG severity' do
    reporter = ActiveSupport::EventReporter.new
    subscriber = OtelLogging::EventSubscriber.new
    reporter.subscribe(subscriber)
    OtelLogging.with_span('request') do
      reporter.debug('hidden')
      reporter.with_debug { reporter.debug('visible') }
    end
    events = exporter.finished_spans.first.events
    expect(events.map(&:name)).to eq(['visible'])
    expect(events.first.attributes['log.severity']).to eq(Logger::INFO)
  end
end
