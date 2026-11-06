# frozen_string_literal: true

require 'spec_helper'
require 'otel_logging/framework_instrumentation'
require 'active_support/structured_event_subscriber'
require 'opentelemetry/sdk/trace/export/in_memory_span_exporter'

RSpec.describe 'framework notification mappings', uninstalled: true do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  def install(&block)
    OtelLogging.config.instrumentation(&block)
    OtelLogging.config.instrumentation.enable_framework!
    OtelLogging::FrameworkInstrumentation.install_event_origin!
    otel_provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    OtelLogging.install!(logger: otel_logger, tracer_provider: otel_provider)
  end

  it 'maps controllers, SQL and views once and preserves nesting' do
    install
    ActiveSupport::Notifications.instrument('process_action.action_controller', controller: 'OrdersController', action: 'show') do
      ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT * FROM orders', name: 'Order Load') {}
      ActiveSupport::Notifications.instrument('render_template.action_view', identifier: 'app/views/orders/show.html.erb') {}
    end
    controller = exporter.finished_spans.find { |span| span.name == 'orders#show' }
    children = exporter.finished_spans.reject { |span| span.equal?(controller) }
    expect(children.map(&:name)).to contain_exactly('db.select.orders', 'render orders/show.html.erb')
    expect(children.map(&:parent_span_id).uniq).to eq([controller.span_id])
  end

  it 'uses application mappings ahead of framework defaults' do
    install { subscribe(/.*/) }
    ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT * FROM widgets') {}
    expect(exporter.finished_spans.map(&:name)).to eq(['sql.active_record'])
    expect(exporter.finished_spans.first.attributes['sql']).to eq('SELECT * FROM widgets')
  end

  it 'honors view filtering and partial depth while allowing explicit overrides' do
    OtelLogging.config.view_denylist = ['hidden']
    OtelLogging.config.partial_max_depth = 1
    install
    ActiveSupport::Notifications.instrument('render_partial.action_view', identifier: 'app/views/visible.html.erb') do
      ActiveSupport::Notifications.instrument('render_partial.action_view', identifier: 'app/views/inner.html.erb') {}
    end
    ActiveSupport::Notifications.instrument('render_template.action_view', identifier: 'app/views/hidden.html.erb') {}
    expect(exporter.finished_spans.map(&:name)).to eq(['render partial visible.html.erb'])
  end

  it 'omits schema and transaction queries from built-in spans' do
    install
    %w[BEGIN COMMIT ROLLBACK].each do |sql|
      ActiveSupport::Notifications.instrument('sql.active_record', sql: sql) {}
    end
    ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT * FROM users', name: 'SCHEMA') {}
    expect(exporter.finished_spans).to be_empty
  end

  it 'handles collections without an identifier and selects Cable metadata' do
    install
    ActiveSupport::Notifications.instrument('render_collection.action_view', count: 0) {}
    ActiveSupport::Notifications.instrument('perform_action.action_cable',
      channel_class: 'InventoryChannel', action: 'refresh', data: { message: 'private content' }) {}
    spans = exporter.finished_spans
    expect(spans.map(&:name)).to contain_exactly('render partial templates', 'websocket.perform_action.InventoryChannel.refresh')
    expect(spans.last.attributes).to include('websocket.channel' => 'InventoryChannel', 'websocket.action' => 'refresh')
    expect(otel_output.string).not_to include('private content')
  end

  it 'retains native layout events when only the containing template is instrumented' do
    OtelLogging.config.enable_layouts = false
    install
    ActiveSupport::Notifications.instrument('render_template.action_view', identifier: 'app/views/orders/show.html.erb') do
      event = { name: 'action_view.render_start', payload: { is_layout: true },
                source_location: { filepath: '/action_view/structured_event_subscriber.rb' } }
      expect(OtelLogging::FrameworkInstrumentation.duplicate_event?(event)).to be(false)
    end
  end

  it 'retains native view events when sampling disables recording' do
    @otel_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF)
    install
    payload = { identifier: 'app/views/orders/show.html.erb' }
    ActiveSupport::Notifications.instrument('render_template.action_view', payload) do
      event = { name: 'action_view.render_start', payload: { is_layout: false },
                source_location: { filepath: '/action_view/structured_event_subscriber.rb' } }
      expect(OtelLogging::FrameworkInstrumentation.duplicate_event?(event)).to be(false)
      expect(OtelLogging::Instrumentation.represented?('render_template.action_view', payload)).to be(false)
    end
    expect(exporter.finished_spans).to be_empty
  end

  [true, false].each do |native_first|
    it "suppresses only the native duplicate with native-first=#{native_first}" do
      native = Class.new(ActiveSupport::StructuredEventSubscriber) do
        def sql(event)
          emit_event('active_record.sql', sql: event.payload[:sql])
        end
      end.new
      other_events = []
      observer = Object.new
      observer.define_singleton_method(:emit) { |event| other_events << event }
      ActiveSupport.event_reporter.subscribe(observer)
      subscription = ActiveSupport::Notifications.subscribe('sql.active_record', native) if native_first
      install
      subscription ||= ActiveSupport::Notifications.subscribe('sql.active_record', native)
      ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT * FROM widgets') {}
      expect(otel_output.string).to include('◆ db.select.widgets')
      expect(otel_output.string).not_to include('active_record.sql')
      expect(other_events.map { |event| event[:name] }).to include('active_record.sql')
      ActiveSupport.event_reporter.notify('active_record.sql', sql: 'application event')
      expect(otel_output.string.scan('active_record.sql').size).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      ActiveSupport.event_reporter.unsubscribe(observer) if observer
    end
  end
end
