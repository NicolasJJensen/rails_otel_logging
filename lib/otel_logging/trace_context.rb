# frozen_string_literal: true

require 'opentelemetry-sdk'

module OtelLogging
  # Thin wrapper around OpenTelemetry for managing traces and spans.
  # Provides a simpler API while using OTel under the hood.
  class TraceContext
    class << self
      def current
        Thread.current[:otel_trace_context] ||= new
      end

      def reset!
        Thread.current[:otel_trace_context] = nil
      end

      def tracer
        provider = OtelLogging.tracer_provider
        raise 'OtelLogging has not been installed' unless provider

        # Resolve this on every call. Providers are application-owned and may
        # be replaced between isolated application boots; a process-global
        # cached tracer would silently keep using the old provider.
        provider.tracer('rails_otel_logging', OtelLogging.config.service_version)
      end
    end

    def initialize
      @span_stack = []
      @root_span = nil
    end

    # Start a new trace (root span)
    def start_trace(name, attributes: {})
      # Start root span
      span = self.class.tracer.start_span(
        name,
        attributes: attributes,
        kind: :server
      )

      @root_span = span
      @span_stack = [span]

      # Activate the span context
      @root_token = OpenTelemetry::Context.attach(
        OpenTelemetry::Trace.context_with_span(span)
      )

      span
    end

    # End the current trace (root span)
    def end_trace(error: nil)
      return nil unless @root_span

      if error
        @root_span.record_exception(error)
        @root_span.status = OpenTelemetry::Trace::Status.error(error.message)
      end

      @root_span.finish

      # Detach context
      OpenTelemetry::Context.detach(@root_token) if @root_token

      span = @root_span
      @root_span = nil
      @root_token = nil
      @span_stack = []

      span
    end

    # Start a child span
    def start_span(name, attributes: {})
      span = self.class.tracer.start_span(
        name,
        attributes: attributes,
        kind: :internal
      )

      @span_stack.push(span)
      token = nil

      begin
        # Activate this span's context
        token = OpenTelemetry::Context.attach(
          OpenTelemetry::Trace.context_with_span(span)
        )

        # Store token for later detachment
        span.instance_variable_set(:@_otel_context_token, token)
      rescue StandardError
        # If context attachment fails, detach and clean up
        OpenTelemetry::Context.detach(token) if token
        @span_stack.pop
        raise
      end

      span
    end

    # End the current span
    def end_span(error: nil)
      return nil if @span_stack.empty? || @span_stack.length == 1 # Don't pop root

      span = @span_stack.pop

      if error
        span.record_exception(error)
        span.status = OpenTelemetry::Trace::Status.error(error.message)
      end

      span.finish

      # Detach context
      token = span.instance_variable_get(:@_otel_context_token)
      OpenTelemetry::Context.detach(token) if token

      span
    end

    # Add an event to the current span
    def add_event(name, attributes: {})
      span = current_span
      return nil unless span

      span.add_event(name, attributes: attributes)
    end

    # Get current span
    def current_span
      @span_stack.last
    end

    # Get root span
    def root_span
      @root_span
    end

    # Is there an active trace?
    def active?
      !@root_span.nil?
    end

    # Get trace ID
    def trace_id
      @root_span&.context&.hex_trace_id
    end

    # Get current span ID
    def span_id
      current_span&.context&.hex_span_id
    end

    # Get the depth of the current span (for tree rendering)
    def depth
      @span_stack.length - 1
    end
  end
end
