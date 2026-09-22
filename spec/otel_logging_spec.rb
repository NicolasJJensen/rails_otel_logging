# spec/lib/otel_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OtelLogging do
  describe OtelLogging::Configuration do
    subject(:config) { described_class.new }

    describe '#rails_logs' do
      it 'replaces Rails logs by default' do
        expect(config.rails_logs).to eq(:replace)
      end

      it 'accepts preservation and rejects unknown modes' do
        config.rails_logs = :preserve
        expect(config.rails_logs).to eq(:preserve)
        expect { config.rails_logs = :silent }.to raise_error(ArgumentError, /Invalid rails_logs/)
      end

      it 'reads the environment and allows explicit configuration to override it' do
        allow(ENV).to receive(:fetch).with('OTEL_RAILS_LOGS', 'replace').and_return('preserve')
        expect(config.rails_logs).to eq(:preserve)
        config.rails_logs = :replace
        expect(config.rails_logs).to eq(:replace)
      end
    end

    describe '#output_mode' do
      it 'defaults to :live_delayed_on_error' do
        expect(config.output_mode).to eq(:live_delayed_on_error)
      end

      it 'accepts valid output modes' do
        %i[live delayed both live_delayed_on_error].each do |mode|
          config.output_mode = mode
          expect(config.output_mode).to eq(mode)
        end
      end

      it 'raises ArgumentError for invalid modes' do
        expect { config.output_mode = :invalid }.to raise_error(ArgumentError, /Invalid output_mode/)
      end
    end

    describe '#live?' do
      it 'returns true for live modes' do
        %i[live both live_delayed_on_error].each do |mode|
          config.output_mode = mode
          expect(config.live?).to be true
        end
      end

      it 'returns false for delayed mode' do
        config.output_mode = :delayed
        expect(config.live?).to be false
      end
    end

    describe '#delayed?' do
      it 'returns true for delayed and both modes' do
        %i[delayed both].each do |mode|
          config.output_mode = mode
          expect(config.delayed?).to be true
        end
      end

      it 'returns false for live and live_delayed_on_error modes' do
        %i[live live_delayed_on_error].each do |mode|
          config.output_mode = mode
          expect(config.delayed?).to be false
        end
      end
    end

    describe '#delayed_on_error?' do
      it 'returns true only for live_delayed_on_error mode' do
        config.output_mode = :live_delayed_on_error
        expect(config.delayed_on_error?).to be true

        config.output_mode = :delayed
        expect(config.delayed_on_error?).to be false
      end
    end
  end

  describe OtelLogging::TraceContext do
    before do
      described_class.reset!
    end

    after do
      described_class.reset!
    end

    describe '.current' do
      it 'returns a thread-local instance' do
        context1 = described_class.current
        context2 = described_class.current
        expect(context1).to be(context2)
      end

      it 'returns different instances for different threads' do
        context1 = described_class.current
        context2 = nil

        thread = Thread.new { context2 = described_class.current }
        thread.join

        expect(context1).not_to be(context2)
      end
    end

    describe '#start_trace and #end_trace' do
      it 'creates and ends a trace' do
        context = described_class.current

        expect(context.active?).to be false

        span = context.start_trace('test_trace', attributes: { 'test.key' => 'value' })

        expect(context.active?).to be true
        expect(span).not_to be_nil
        expect(span.name).to eq('test_trace')
        expect(context.trace_id).to be_a(String)
        expect(context.trace_id.length).to eq(32)

        context.end_trace

        expect(context.active?).to be false
      end
    end

    describe '#start_span and #end_span' do
      it 'creates nested spans within a trace' do
        context = described_class.current
        context.start_trace('root_trace')

        expect(context.depth).to eq(0)

        child_span = context.start_span('child_span', attributes: { 'child.key' => 'child_value' })

        expect(context.depth).to eq(1)
        expect(child_span.name).to eq('child_span')
        expect(context.current_span).to be(child_span)

        context.end_span
        expect(context.depth).to eq(0)

        context.end_trace
      end

      it 'handles deeply nested spans' do
        context = described_class.current
        context.start_trace('root')

        3.times do |i|
          context.start_span("level_#{i + 1}")
          expect(context.depth).to eq(i + 1)
        end

        3.times do |i|
          expect(context.depth).to eq(3 - i)
          context.end_span
        end

        expect(context.depth).to eq(0)
        context.end_trace
      end
    end

    describe '#add_event' do
      it 'adds an event to the current span' do
        context = described_class.current
        context.start_trace('trace_with_event')

        # Events are added to the OTel span, we just verify no errors
        expect { context.add_event('test.event', attributes: { 'event.key' => 'event_value' }) }.not_to raise_error

        context.end_trace
      end

      it 'returns nil when no active trace' do
        context = described_class.current
        result = context.add_event('orphan_event')
        expect(result).to be_nil
      end
    end
  end

  describe OtelLogging::LoggerExtension do
    let(:logger) { ActiveSupport::Logger.new(nil) }

    before do
      logger.extend(described_class)
      OtelLogging::TraceContext.reset!
    end

    after do
      OtelLogging::TraceContext.reset!
    end

    describe '#with_trace' do
      it 'creates a trace and yields the span' do
        yielded_span = nil

        logger.with_trace('test_trace') do |span|
          yielded_span = span
          expect(OtelLogging::TraceContext.current.active?).to be true
        end

        expect(yielded_span).not_to be_nil
        expect(OtelLogging::TraceContext.current.active?).to be false
      end

      it 'returns the block result' do
        result = logger.with_trace('test') { 42 }
        expect(result).to eq(42)
      end

      it 'records exceptions and re-raises them' do
        expect {
          logger.with_trace('failing_trace') do
            raise StandardError, 'test error'
          end
        }.to raise_error(StandardError, 'test error')

        expect(OtelLogging::TraceContext.current.active?).to be false
      end
    end

    describe '#with_span' do
      it 'creates a child span within a trace' do
        logger.with_trace('parent') do
          logger.with_span('child') do |child_span|
            expect(child_span).not_to be_nil
            expect(OtelLogging::TraceContext.current.depth).to eq(1)
          end
        end
      end

      it 'runs block without tracing when no active trace' do
        result = logger.with_span('orphan') do |span|
          expect(span).to be_nil
          'executed'
        end

        expect(result).to eq('executed')
      end
    end

    describe '#event' do
      it 'adds an event to the current span' do
        logger.with_trace('trace') do
          expect { logger.event('test.event', key: 'value') }.not_to raise_error
        end
      end

      it 'accepts an event when no trace is active' do
        expect { logger.event('orphan.event') }.not_to raise_error
      end
    end

    describe '#current_trace_id and #current_span_id' do
      it 'returns trace and span IDs when active' do
        logger.with_trace('test') do
          expect(logger.current_trace_id).to be_a(String)
          expect(logger.current_trace_id.length).to eq(32)
          expect(logger.current_span_id).to be_a(String)
          expect(logger.current_span_id.length).to eq(16)
        end
      end

      it 'returns nil when no active trace' do
        expect(logger.current_trace_id).to be_nil
        expect(logger.current_span_id).to be_nil
      end
    end
  end

  describe OtelLogging::Subscribers::ActiveRecord do
    describe '#handle_sql_event' do
      let(:subscriber) { described_class.new }
      let(:mock_connection) { double('Connection', adapter_name: 'PostgreSQL') }

      def create_event(sql:, name: 'User Load', cached: false)
        payload = {
          sql: sql,
          name: name,
          connection: mock_connection,
          cached: cached
        }
        ActiveSupport::Notifications::Event.new(
          'sql.active_record',
          Time.now,
          Time.now + 0.001,
          SecureRandom.hex(8),
          payload
        )
      end

      it 'ignores schema queries' do
        event = create_event(sql: 'SELECT * FROM users', name: 'SCHEMA')
        expect(otel_logger).not_to receive(:event)
        subscriber.handle_sql_event(event)
      end

      it 'ignores transaction queries' do
        %w[BEGIN COMMIT ROLLBACK].each do |sql|
          event = create_event(sql: sql)
          expect(otel_logger).not_to receive(:event)
          subscriber.handle_sql_event(event)
        end
      end

      it 'ignores schema_migrations queries' do
        event = create_event(sql: 'SELECT * FROM schema_migrations')
        expect(otel_logger).not_to receive(:event)
        subscriber.handle_sql_event(event)
      end

      it 'processes SELECT queries' do
        # Need an active trace for events to work
        otel_logger.extend(OtelLogging::LoggerExtension) unless otel_logger.respond_to?(:with_trace)

        otel_logger.with_trace('test') do
          event = create_event(sql: 'SELECT * FROM users WHERE id = 1')
          # Just verify it doesn't raise - the event will be logged
          expect { subscriber.handle_sql_event(event) }.not_to raise_error
        end
      end
    end

    describe 'SQL parsing' do
      let(:subscriber) { described_class.new }

      it 'extracts operations correctly' do
        operations = {
          'SELECT * FROM users' => 'select',
          'INSERT INTO users (name) VALUES (?)' => 'insert',
          'UPDATE users SET name = ?' => 'update',
          'DELETE FROM users WHERE id = ?' => 'delete',
          'WITH cte AS (SELECT 1) SELECT * FROM cte' => 'query'
        }

        operations.each do |sql, expected_op|
          result = subscriber.send(:extract_operation, sql)
          expect(result).to eq(expected_op), "Expected #{sql.inspect} to have operation #{expected_op.inspect}, got #{result.inspect}"
        end
      end

      it 'extracts table names correctly' do
        tables = {
          'SELECT * FROM users WHERE id = 1' => 'users',
          'INSERT INTO posts (title) VALUES (?)' => 'posts',
          'UPDATE comments SET body = ?' => 'comments',
          'SELECT * FROM "quoted_table"' => 'quoted_table'
        }

        tables.each do |sql, expected_table|
          result = subscriber.send(:extract_table, sql)
          expect(result).to eq(expected_table), "Expected #{sql.inspect} to have table #{expected_table.inspect}, got #{result.inspect}"
        end
      end
    end
  end

  describe 'Integration' do
    it 'otel_logger has tracing methods' do
      expect(otel_logger).to respond_to(:with_trace)
      expect(otel_logger).to respond_to(:with_span)
      expect(otel_logger).to respond_to(:event)
      expect(otel_logger).to respond_to(:current_trace_id)
      expect(otel_logger).to respond_to(:current_span_id)
    end

    it 'creates a complete trace with nested spans and events' do
      otel_logger.with_trace('integration_test', attributes: { 'test.type' => 'integration' }) do |root|
        expect(root).not_to be_nil

        otel_logger.with_span('database_operation') do |db_span|
          expect(db_span).not_to be_nil
          otel_logger.event('db.query', table: 'users', operation: 'select')
        end

        otel_logger.with_span('external_api_call') do |api_span|
          expect(api_span).not_to be_nil
          api_span.set_attribute('api.endpoint', '/external/resource')
          otel_logger.event('api.response', status: 200)
        end
      end

      # Trace should be complete
      expect(OtelLogging::TraceContext.current.active?).to be false
    end
  end
end
