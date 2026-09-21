# spec/lib/otel_output_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'OtelLogging Log Output', type: :integration do
  let(:log_output) { StringIO.new }
  let(:test_logger) { ActiveSupport::Logger.new(log_output) }

  before do
    test_logger.extend(OtelLogging::LoggerExtension)
    OtelLogging::TraceContext.reset!
  end

  after do
    OtelLogging::TraceContext.reset!
  end

  describe 'Live exporter' do
    let(:exporter) { OtelLogging::Exporters::Live.new(test_logger) }

    it 'outputs trace header for root span' do
      test_logger.with_trace('GET /users/42', attributes: { 'http.method' => 'GET' }) do |root_span|
        exporter.on_start(root_span, OpenTelemetry::Context.current)
      end

      output = log_output.string

      expect(output).to include('trace')
      expect(output).to include('GET /users/42')
      expect(output).to include('http.method')
      expect(output).to include('GET')
    end

    it 'outputs nested spans with tree structure' do
      test_logger.with_trace('GET /users/42') do |root_span|
        exporter.on_start(root_span, OpenTelemetry::Context.current)

        test_logger.with_span('users#show', attributes: { 'rails.controller' => 'users' }) do |child_span|
          exporter.on_start(child_span, OpenTelemetry::Context.current)

          test_logger.with_span('render users/show.html.erb') do |view_span|
            exporter.on_start(view_span, OpenTelemetry::Context.current)
          end
        end
      end

      output = log_output.string

      expect(output).to include('trace')
      expect(output).to include('GET /users/42')
      expect(output).to include('users#show')
      expect(output).to include('render users/show.html.erb')
      expect(output).to include('├') # Tree branch marker for nested spans
    end

    it 'outputs events within spans' do
      test_logger.with_trace('GET /users') do |root_span|
        exporter.on_start(root_span, OpenTelemetry::Context.current)

        test_logger.with_span('users#index') do |action_span|
          exporter.on_start(action_span, OpenTelemetry::Context.current)

          # Event output via live exporter
          exporter.on_event('db.select.users', { 'db.duration_ms' => 2.34 }, OtelLogging::TraceContext.current)
        end
      end

      output = log_output.string

      expect(output).to include('db.select.users')
      expect(output).to include('db.duration_ms')
    end
  end

  describe 'Buffered exporter output format' do
    # The buffered exporter is tested via integration with OTel's span lifecycle.
    # Since span timestamps are only available after spans finish (handled by OTel),
    # we test the buffered exporter's tree building and formatting indirectly
    # through live exporter tests which share the same formatting logic.

    it 'uses same tree formatting as live exporter' do
      # Verify the buffered exporter has the same formatting constants (shared via Formatting module)
      expect(OtelLogging::Exporters::Buffered::SPAN_MARKER).to eq(OtelLogging::Exporters::Live::SPAN_MARKER)
      expect(OtelLogging::Exporters::Buffered::EVENT_MARKER).to eq(OtelLogging::Exporters::Live::EVENT_MARKER)
      # Colors are now configured via OtelLogging.config.theme (shared by both exporters)
    end
  end

  describe 'Complete trace visualization' do
    let(:exporter) { OtelLogging::Exporters::Live.new(test_logger) }

    it 'shows a realistic request trace structure' do
      test_logger.with_trace('GET /users/42', attributes: {
        'http.method' => 'GET',
        'http.host' => 'localhost:3000',
        'http.target' => '/users/42'
      }) do |root_span|
        exporter.on_start(root_span, OpenTelemetry::Context.current)

        test_logger.with_span('users#show', attributes: {
          'rails.controller' => 'users',
          'rails.action' => 'show',
          'rails.format' => 'text/html'
        }) do |action_span|
          exporter.on_start(action_span, OpenTelemetry::Context.current)

          # Database query events
          exporter.on_event('db.select.users', {
            'db.duration_ms' => 1.23,
            'db.system' => 'postgresql',
            'db.statement' => 'SELECT * FROM users WHERE id = $1'
          }, OtelLogging::TraceContext.current)

          exporter.on_event('db.select.posts', {
            'db.duration_ms' => 3.45,
            'db.system' => 'postgresql',
            'db.statement' => 'SELECT * FROM posts WHERE user_id = $1'
          }, OtelLogging::TraceContext.current)

          # View rendering
          test_logger.with_span('render users/show.html.erb', attributes: {
            'view.type' => 'template'
          }) do |view_span|
            exporter.on_start(view_span, OpenTelemetry::Context.current)

            test_logger.with_span('render partial users/_header.html.erb', attributes: {
              'view.type' => 'partial'
            }) do |partial_span|
              exporter.on_start(partial_span, OpenTelemetry::Context.current)
            end
          end
        end
      end

      output = log_output.string

      # Verify all components are present
      expect(output).to include('trace')
      expect(output).to include('GET /users/42')
      expect(output).to include('users#show')
      expect(output).to include('db.select.users')
      expect(output).to include('db.select.posts')
      expect(output).to include('render users/show.html.erb')
      expect(output).to include('render partial users/_header.html.erb')

      # Verify tree structure markers
      expect(output).to include('◆') # Span marker
      expect(output).to include('+') # Event marker
      expect(output).to include('├') # Tree branch
      expect(output).to include('│') # Tree continuation
    end
  end

  describe 'Error event formatting' do
    let(:exporter) { OtelLogging::Exporters::Live.new(test_logger) }

    it 'highlights error events' do
      test_logger.with_trace('POST /payments') do |root_span|
        exporter.on_start(root_span, OpenTelemetry::Context.current)

        test_logger.with_span('payment.process') do |process_span|
          exporter.on_start(process_span, OpenTelemetry::Context.current)

          # Error event
          exporter.on_event('exception', {
            'exception.type' => 'PaymentDeclinedError',
            'exception.message' => 'Card declined'
          }, OtelLogging::TraceContext.current)
        end
      end

      output = log_output.string

      expect(output).to include('exception')
      expect(output).to include('PaymentDeclinedError')
    end
  end
end
