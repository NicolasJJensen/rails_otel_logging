# frozen_string_literal: true

require_relative 'formatting'

module OtelLogging
  module Exporters
    # SpanProcessor that outputs spans immediately when they start.
    #
    # In OpenTelemetry, SpanProcessor has two callbacks:
    #   - on_start(span, parent_context) - called when span begins
    #   - on_finish(span) - called when span ends
    #
    # Live mode uses on_start to print spans as they open.
    # This gives real-time visibility but no durations (not known yet).
    class Live < OpenTelemetry::SDK::Trace::SpanProcessor
      include Formatting

      TRACE_TTL_SECONDS = 300 # Clean up orphaned trace depth tracking after 5 minutes

      def initialize(logger)
        raise ArgumentError, 'logger is required' if logger.nil?

        @logger = logger
        @span_depth = {}  # trace_id => { span_id => depth, ... }
        @trace_timestamps = {} # trace_id => started_at
        @mutex = Mutex.new
        @last_cleanup = Time.now
      end

      # Called when a span starts
      def on_start(span, parent_context)
        trace_id = span.context.hex_trace_id
        span_id = span.context.hex_span_id
        parent_span_id_hex = span.parent_span_id.unpack1('H*')

        depth = @mutex.synchronize do
          cleanup_orphaned_traces if should_cleanup?

          # Calculate depth - check if this is a root span (no parent)
          if parent_span_id_hex == INVALID_SPAN_ID
            # Root span
            @span_depth[trace_id] = { span_id => 0 }
            @trace_timestamps[trace_id] = Time.now
            0
          else
            # Child span
            parent_depth = @span_depth.dig(trace_id, parent_span_id_hex) || 0
            child_depth = parent_depth + 1
            @span_depth[trace_id] ||= {}
            @span_depth[trace_id][span_id] = child_depth
            child_depth
          end
        end

        # Print trace header for root spans
        if parent_span_id_hex == INVALID_SPAN_ID
          @logger.info ""
          @logger.info "#{c(:trace_label, 'trace')} #{c(:trace_id, trace_id[0..15])}"
        end

        output_span(span, depth)
      end

      # Called when a span ends
      def on_finish(span)
        # Live mode already printed on start, nothing to do
        # Could optionally print duration here, but that gets noisy

        # Clean up depth tracking if root span
        parent_span_id_hex = span.parent_span_id.unpack1('H*')
        if parent_span_id_hex == INVALID_SPAN_ID
          trace_id = span.context.hex_trace_id
          @mutex.synchronize do
            @span_depth.delete(trace_id)
            @trace_timestamps.delete(trace_id)
          end
        end
      end

      # Called when an event is added (via OtelLogging.notify_event)
      def on_event(name, attributes, context)
        depth = context.depth + 1  # Events are children of current span
        output_event(name, attributes, depth)
      end

      def force_flush(timeout: nil)
        @mutex.synchronize { cleanup_orphaned_traces }
        OpenTelemetry::SDK::Trace::Export::SUCCESS
      end

      def shutdown(timeout: nil)
        @mutex.synchronize do
          @span_depth.clear
          @trace_timestamps.clear
        end
        OpenTelemetry::SDK::Trace::Export::SUCCESS
      end

      private

      def should_cleanup?
        (Time.now - @last_cleanup) > 60
      end

      def cleanup_orphaned_traces
        cutoff = Time.now - TRACE_TTL_SECONDS
        @trace_timestamps.each do |trace_id, started_at|
          if started_at < cutoff
            @span_depth.delete(trace_id)
            @trace_timestamps.delete(trace_id)
          end
        end
        @last_cleanup = Time.now
      end

      def output_span(span, depth)
        prefix = build_prefix(depth)
        span_id_short = span.context.hex_span_id[0..7]

        line = "#{c(:tree, prefix)}#{c(:span_name, "#{SPAN_MARKER} #{span.name}")}"
        line += " #{c(:span_id, span_id_short)}"
        # No duration - not known yet
        @logger.info line

        # Output initial attributes
        output_attributes(span.attributes, depth) if span.attributes&.any?
      end

      def output_attributes(attributes, depth)
        content_prefix = build_content_prefix(depth)

        attributes.each do |key, value|
          formatted = format_value(value)
          @logger.info "#{c(:tree, content_prefix)}#{c(:attribute, key)}#{c(:punctuation, ':')} #{c(:value, formatted)}"
        end
        @logger.info c(:tree, content_prefix)
      end

      def output_event(name, attributes, depth)
        prefix = build_prefix(depth)
        event_color = event_color_for(name)

        @logger.info "#{c(:tree, prefix)}#{c(event_color, "#{EVENT_MARKER} #{name}")}"

        # Output event attributes with extra indent
        # Event attrs use ancestor continuation (| ) * depth + 2 space indent
        if attributes && !attributes.empty?
          content_prefix = ('│ ' * depth) + "  "
          attributes.each do |key, value|
            formatted = format_value(value)
            @logger.info "#{c(:tree, content_prefix)}#{c(:attribute, key)}#{c(:punctuation, ':')} #{c(:value, formatted)}"
          end
          @logger.info c(:tree, content_prefix)
        end
      end

      def build_prefix(depth)
        return '' if depth == 0
        ('│ ' * (depth - 1)) + '├ '
      end

      def build_content_prefix(depth)
        ('│ ' * depth) + '│ '
      end
    end
  end
end
