# frozen_string_literal: true

require_relative 'formatting'
require_relative 'local_trees'

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
      include LocalTrees

      TRACE_TTL_SECONDS = 300 # Clean up orphaned trace depth tracking after 5 minutes

      def initialize(logger)
        raise ArgumentError, 'logger is required' if logger.nil?

        @output = OtelLogging::Output.for(logger)
        @span_depth = {}  # [trace_id, local_root_id] => { span_id => depth }
        @spans = {} # [trace_id, local_root_id] => { span_id => { span:, heading_severity: } }
        @roots = {}
        @trace_heading_severity = {}
        @trace_timestamps = {} # [trace_id, local_root_id] => started_at
        @mutex = Mutex.new
        @last_cleanup = Time.now
      end

      # Called when a span starts
      def on_start(span, parent_context)
        trace_id = span.context.hex_trace_id
        span_id = span.context.hex_span_id
        parent_span_id_hex = span.parent_span_id.unpack1('H*')

        severity = span_severity(span)
        tags, progname = span_metadata(span)
        depth = @mutex.synchronize do
          cleanup_orphaned_traces if should_cleanup?

          trace_id = register_tree(span)
          if trace_id == span_key(span)
            # Root span
            @span_depth[trace_id] = { span_id => 0 }
            @spans[trace_id] = { span_id => { span: span, heading_severity: severity } }
            @roots[trace_id] = span
            @trace_heading_severity[trace_id] = severity
            @trace_timestamps[trace_id] = Time.now
            0
          else
            # Child span
            parent_depth = @span_depth.dig(trace_id, parent_span_id_hex) || 0
            child_depth = parent_depth + 1
            @span_depth[trace_id] ||= {}
            @span_depth[trace_id][span_id] = child_depth
            @spans[trace_id] ||= {}
            @spans[trace_id][span_id] = { span: span, heading_severity: severity }
            child_depth
          end
        end

        # Print trace header for root spans
        if depth == 0
          emit "", severity: severity, tags: tags, progname: progname
          emit "#{c(:trace_label, 'trace')} #{c(:trace_id, span.context.hex_trace_id[0..15])}", severity: severity, tags: tags, progname: progname
        end

        output_span(span, depth, severity: severity, tags: tags, progname: progname)
      end

      # Called when a span ends
      def on_finish(span)
        output_error_details(span) if span_has_error_details?(span)

        @mutex.synchronize do
          tree = tree_for(span)
          delete_tree(tree) if tree && tree_finished?(span)
        end
      end

      # Called when an event is added (via OtelLogging.notify_event)
      def on_event(name, attributes, context)
        span = OpenTelemetry::Trace.current_span
        depth = if span
          @mutex.synchronize { @span_depth.dig(tree_for(span), span.context.hex_span_id) }
        end
        depth ||= context.depth
        severity = severity_for(name, attributes)
        promote_context(span, severity) if span
        output_event(name, attributes, depth + 1)
      end

      def force_flush(timeout: nil)
        @mutex.synchronize { cleanup_orphaned_traces }
        OpenTelemetry::SDK::Trace::Export::SUCCESS
      end

      def shutdown(timeout: nil)
        @mutex.synchronize do
          clear_trees
          @span_depth.clear
          @spans.clear
          @roots.clear
          @trace_heading_severity.clear
          @trace_timestamps.clear
        end
        OpenTelemetry::SDK::Trace::Export::SUCCESS
      end

      private

      def output_error_details(span)
        depth = @mutex.synchronize do
          @span_depth.dig(tree_for(span), span.context.hex_span_id) || 0
        end
        badge = span_error?(span) ? 'ERROR' : 'EXCEPTION'
        duration_ms = ((span.end_timestamp - span.start_timestamp) / 1_000_000.0).round(2)
        tags, progname = span_metadata(span)
        severity = Logger::ERROR
        promote_context(span, severity, include_current: false)
        emit "#{c(:tree, build_prefix(depth))}#{c(:span_name, "#{SPAN_MARKER} #{span.name}")} " \
              "#{c(:span_id, span.context.hex_span_id[0..7])} #{c(:duration, "#{duration_ms}ms")} " \
              "#{c(:error_badge, badge)}", severity: severity, tags: tags, progname: progname

        exceptions = (span.events || []).select { |event| raw_exception_event?(event) }
        exceptions.each { |event| output_event(event.name, event.attributes, depth + 1) }
        if span_error?(span) && exceptions.empty? && !span.status.description.to_s.empty?
          output_attributes({ 'error.message' => span.status.description }, depth, severity: severity, tags: tags, progname: progname)
        end
      end

      def should_cleanup?
        (Time.now - @last_cleanup) > 60
      end

      def delete_tree(tree)
        @span_depth.delete(tree)
        @spans.delete(tree)
        @roots.delete(tree)
        @trace_heading_severity.delete(tree)
        @trace_timestamps.delete(tree)
        remove_tree(tree)
      end

      def cleanup_orphaned_traces
        cutoff = Time.now - TRACE_TTL_SECONDS
        @trace_timestamps.keys.each do |tree|
          delete_tree(tree) if @trace_timestamps[tree] < cutoff
        end
        @last_cleanup = Time.now
      end

      def output_span(span, depth, severity:, tags:, progname:)
        output_span_line(span, depth, severity: severity, tags: tags, progname: progname)

        # Output initial attributes
        output_attributes(span.attributes, depth, severity: severity, tags: tags, progname: progname) if visible_attributes(span.attributes).any?
      end

      def output_span_line(span, depth, severity:, tags:, progname:, above: nil)
        prefix = build_prefix(depth)
        span_id_short = span.context.hex_span_id[0..7]

        line = "#{c(:tree, prefix)}#{c(:span_name, "#{SPAN_MARKER} #{span.name}")}"
        line += " #{c(:span_id, span_id_short)}"
        # No duration - not known yet
        emit line, severity: severity, tags: tags, progname: progname, above: above
      end

      def promote_context(span, severity, include_current: true)
        return unless severity >= Logger::WARN

        promotions = @mutex.synchronize do
          trace_id = tree_for(span)
          current = span
          result = []
          while current
            info = @spans.dig(trace_id, current.context.hex_span_id)
            break unless info

            previous = info[:heading_severity]
            if severity > previous
              info[:heading_severity] = severity
              result << [current, previous] if include_current || current.context.hex_span_id != span.context.hex_span_id
            end
            parent_id = current.parent_span_id.unpack1('H*')
            break if parent_id == INVALID_SPAN_ID

            current = @spans.dig(trace_id, parent_id)&.fetch(:span)
          end
          header_previous = @trace_heading_severity[trace_id]
          if header_previous && severity > header_previous
            @trace_heading_severity[trace_id] = severity
            result << [:header, header_previous]
          end
          result
        end

        promotions.reverse_each do |target, previous|
          if target == :header
            root = @mutex.synchronize { @roots[tree_for(span)] }
            next unless root

            tags, progname = span_metadata(root)
            trace_id = root.context.hex_trace_id
            emit "", severity: severity, tags: tags, progname: progname, above: previous
            emit "#{c(:trace_label, 'trace')} #{c(:trace_id, trace_id[0..15])}", severity: severity, tags: tags, progname: progname, above: previous
          else
            tags, progname = span_metadata(target)
            depth = @mutex.synchronize { @span_depth.dig(tree_for(target), target.context.hex_span_id) || 0 }
            output_span_line(target, depth, severity: severity, tags: tags, progname: progname, above: previous)
          end
        end
      end

      def output_attributes(attributes, depth, severity:, tags:, progname:)
        content_prefix = build_content_prefix(depth)

        visible_attributes(attributes).each do |key, value|
          formatted = format_value(value)
          emit "#{c(:tree, content_prefix)}#{c(:attribute, key)}#{c(:punctuation, ':')} #{c(:value, formatted)}", severity: severity, tags: tags, progname: progname
        end
        emit c(:tree, content_prefix), severity: severity, tags: tags, progname: progname
      end

      def output_event(name, attributes, depth)
        prefix = build_prefix(depth)
        severity = severity_for(name, attributes)
        event_color = event_color_for(name, severity: severity)
        tags, progname = attribute(attributes, 'log.tags'), attribute(attributes, 'log.progname')
        emit "#{c(:tree, prefix)}#{c(event_color, "#{EVENT_MARKER} #{event_label(name, attributes, severity)}#{name}")}", severity: severity, tags: tags, progname: progname

        # Output event attributes with extra indent
        # Event attrs use ancestor continuation (| ) * depth + 2 space indent
        if visible_attributes(attributes).any?
          content_prefix = ('│ ' * depth) + "  "
          visible_attributes(attributes).each do |key, value|
            formatted = format_value(value)
            emit "#{c(:tree, content_prefix)}#{c(:attribute, key)}#{c(:punctuation, ':')} #{c(:value, formatted)}", severity: severity, tags: tags, progname: progname
          end
          emit c(:tree, content_prefix), severity: severity, tags: tags, progname: progname
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
