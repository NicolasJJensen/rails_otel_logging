# frozen_string_literal: true

module OtelLogging
  module LoggerExtension
    [:debug, :info, :warn, :error, :fatal, :unknown].each do |name|
      define_method(name) do |progname = nil, &block|
        add(::Logger::Severity.const_get(name.to_s.upcase), nil, progname, &block)
      end
    end

    def add(severity, message = nil, progname = nil, &block)
      severity = Output.severity(severity)
      output = Output.for(self)
      return output.add(severity, message, progname, &block) unless TraceContext.current.active?
      return true unless output.enabled?(severity)

      if message.nil?
        if block
          message = block.call
        else
          message = progname || self.progname
          progname = nil
        end
      end
      return true if message.equal?(Output::SUPPRESSED)

      capture_log(severity, message, progname: progname)
    end
    alias_method :log, :add

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
      span = context.start_trace(name, attributes: attributes.merge('log.tags' => Output.for(self).tags))
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

      span = context.start_span(name, attributes: attributes.merge('log.tags' => Output.for(self).tags))
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
    def event(name, severity: :info, **attributes)
      capture_log(Output.severity(severity), name, attributes: attributes)
    end

    # Get current trace ID (useful for logging correlation)
    def current_trace_id
      TraceContext.current.trace_id
    end

    # Get current span ID
    def current_span_id
      TraceContext.current.span_id
    end

    private

    def capture_log(severity, message, attributes: {}, progname: nil)
      output = Output.for(self)
      return true unless output.enabled?(severity)

      name = case message
             when String then message.dup
             when Exception then "#{message.message} (#{message.class})\n#{Array(message.backtrace).join("\n")}"
             else message.inspect
             end
      tags = output.tags
      context = TraceContext.current
      span = OpenTelemetry::Trace.current_span
      unless context.active? && span.recording?
        details = attributes.empty? ? name : "#{name} #{attributes.inspect}"
        return output.write(details, severity: severity, tags: tags, progname: progname)
      end

      metadata = attributes.transform_keys(&:to_s).merge('log.severity' => severity, 'log.tags' => tags)
      metadata['log.progname'] = progname.to_s.dup if progname
      span.add_event(name, attributes: metadata)
      OtelLogging.notify_event(name, metadata, context)
      true
    end
  end

  module BroadcastTags
    def tagged(*tags, &block)
      return super if defined?(ActiveSupport::TaggedLogging) && singleton_class.ancestors.include?(ActiveSupport::TaggedLogging)

      if block
        Output.for(self).tagged(*tags) { block.call(self) }
      else
        copy = clone
        copy.broadcasts.replace(broadcasts.map do |sink|
          sink.respond_to?(:tagged) ? sink.tagged(*tags) : sink.clone
        end)
        copy
      end
    end
  end
end
