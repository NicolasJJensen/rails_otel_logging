# frozen_string_literal: true

module OtelLogging
  module LoggerExtension
    # Start a trace (root span) - typically used in middleware
    #
    # @param name [String] The trace/root span name (e.g., "GET /users/42")
    # @param attributes [Hash] Optional attributes
    # @yield [span] Block to execute within the trace
    # @return The result of the block
    #
    # @example
    #   Rails.logger.with_trace('GET /users/42', attributes: { 'http.method' => 'GET' }) do |span|
    #     # ... handle request ...
    #   end
    #
    def with_trace(name, attributes: {}, &block)
      context = TraceContext.current
      span = context.start_trace(name, attributes: attributes)
      error = nil

      begin
        yield span
      rescue StandardError => e
        error = e
        raise
      ensure
        context.end_trace(error: error)
        TraceContext.reset!
      end
    end

    # Create a child span within the current trace
    #
    # @param name [String] The span name (e.g., "users#show", "payment.process")
    # @param attributes [Hash] Optional attributes
    # @yield [span] Block to execute within the span
    # @return The result of the block
    #
    # @example
    #   Rails.logger.with_span('process_payment', attributes: { 'order.id' => 42 }) do |span|
    #     span.set_attribute('payment.status', 'success')
    #     # ... process payment ...
    #   end
    #
    def with_span(name, attributes: {}, &block)
      context = TraceContext.current

      unless context.active?
        # No active trace - just run the block without tracing
        return yield nil
      end

      span = context.start_span(name, attributes: attributes)
      error = nil

      begin
        yield span
      rescue StandardError => e
        error = e
        raise
      ensure
        context.end_span(error: error)
      end
    end

    # Add an event to the current span
    #
    # @param name [String] The event name (e.g., "db.select.users", "cache.hit")
    # @param attributes [Hash] Event attributes
    #
    # @example
    #   Rails.logger.event('db.select.users',
    #     db_system: 'postgresql',
    #     db_statement: 'SELECT * FROM users WHERE id = $1'
    #   )
    #
    def event(name, **attributes)
      context = TraceContext.current
      return unless context.active?

      span = context.current_span
      return unless span

      # Convert symbol keys to strings (OTel requires string keys)
      string_attributes = attributes.transform_keys(&:to_s)

      # Add event to OTel span
      span.add_event(name, attributes: string_attributes)

      # Notify live exporter (if configured)
      # Wrapped in rescue to prevent logging errors from affecting application flow
      begin
        OtelLogging.notify_event(name, string_attributes, context)
      rescue StandardError => e
        # Silently ignore - logging should never break the application
        debug { "OtelLogging event notification failed: #{e.message}" } rescue nil
      end
    end

    # Get current trace ID (useful for logging correlation)
    def current_trace_id
      TraceContext.current.trace_id
    end

    # Get current span ID
    def current_span_id
      TraceContext.current.span_id
    end
  end
end
