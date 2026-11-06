# frozen_string_literal: true

require_relative 'formatting'
require_relative 'local_trees'

module OtelLogging
  module Exporters
    # Buffers each local tree until its root and already-started children finish.
    # Remote parents do not keep a local tree open.
    #
    # Options:
    #   only_on_error: If true, only output the tree when the trace has an error
    #
    # This gives us:
    #   - Accurate durations (spans are complete)
    #   - Proper └ for last siblings (we know the full tree structure)
    #   - Individual span outcomes remain visible even when a parent recovers
    class Buffered < OpenTelemetry::SDK::Trace::SpanProcessor
      include Formatting
      include LocalTrees

      TRACE_TTL_SECONDS = 300 # Clean up orphaned traces after 5 minutes
      MAX_BUFFERED_TRACES = 1000 # Maximum traces to buffer before forced cleanup

      def initialize(logger, only_on_error: false)
        raise ArgumentError, 'logger is required' if logger.nil?

        @output = OtelLogging::Output.for(logger)
        @only_on_error = only_on_error
        @traces = {}  # [trace_id, local_root_id] => { spans: [], root:, started_at: }
        @mutex = Mutex.new
        @last_cleanup = Time.now
      end

      def on_start(span, parent_context)
        @mutex.synchronize do
          cleanup_orphaned_traces if should_cleanup?
          tree = register_tree(span)
          @traces[tree] ||= { spans: [], root: span, started_at: Time.now }
        end
      end

      def on_finish(span)
        @mutex.synchronize do
          tree = tree_for(span)
          return unless tree && @traces[tree]

          @traces[tree][:spans] << span
          if tree_finished?(span)
            begin
              output_trace(tree)
            ensure
              @traces.delete(tree)
              remove_tree(tree)
            end
          end
        end
      end

      def force_flush(timeout: nil)
        @mutex.synchronize { cleanup_orphaned_traces }
        OpenTelemetry::SDK::Trace::Export::SUCCESS
      end

      def shutdown(timeout: nil)
        @mutex.synchronize { @traces.clear; clear_trees }
        OpenTelemetry::SDK::Trace::Export::SUCCESS
      end

      private

      def should_cleanup?
        @traces.size > MAX_BUFFERED_TRACES || (Time.now - @last_cleanup) > 60
      end

      def cleanup_orphaned_traces
        cutoff = Time.now - TRACE_TTL_SECONDS
        @traces.keys.each do |tree|
          next unless @traces[tree][:started_at] < cutoff

          @traces.delete(tree)
          remove_tree(tree)
        end
        @last_cleanup = Time.now
      end

      def output_trace(trace_id)
        trace_data = @traces[trace_id]
        return unless trace_data && trace_data[:root]

        root = trace_data[:root]

        spans = trace_data[:spans]
        return if @only_on_error && !trace_has_error?(spans)

        # Build tree structure
        tree = build_tree(spans, root)

        # Output trace header
        root_tags, root_progname = span_metadata(root)
        root_severity = node_output_severity(tree)
        emit "", severity: root_severity, tags: root_tags, progname: root_progname
        emit "#{c(:trace_label, 'trace')} #{c(:trace_id, root.context.hex_trace_id[0..15])}", severity: root_severity, tags: root_tags, progname: root_progname

        # Output root span inline (no tree prefix - root is special)
        output_root_node(tree)
      end

      def output_root_node(node)
        span = node[:span]
        children = node[:children].select { |child| node_visible?(child) }
        events = (span.events || []).select { |event| visible_event?(event) }
        root_severity = node_output_severity(node)
        root_tags, root_progname = span_metadata(span)

        # Combine events and child spans as "tree children"
        tree_children = []
        events.each { |e| tree_children << { type: :event, event: e } }
        children.each { |child| tree_children << { type: :span, node: child } }

        # Sort by timestamp
        tree_children.sort_by! do |child|
          if child[:type] == :event
            child[:event].timestamp
          else
            child[:node][:span].start_timestamp
          end
        end

        # Output root span line (no prefix)
        duration_ms = ((span.end_timestamp - span.start_timestamp) / 1_000_000.0).round(2)
        has_error = span.status&.code == OpenTelemetry::Trace::Status::ERROR
        span_id_short = span.context.hex_span_id[0..7]

        line = "#{c(:span_name, "#{SPAN_MARKER} #{span.name}")}"
        line += " #{c(:span_id, span_id_short)}"
        line += " #{c(:duration, "#{duration_ms}ms")}"
        line += " #{c(:error_badge, 'ERROR')}" if has_error
        emit line, severity: root_severity, tags: root_tags, progname: root_progname

        # Output root attributes (simple prefix: │ if has children, nothing otherwise)
        if @output.enabled?(span_severity(span)) && visible_attributes(span.attributes).any?
          content_prefix = tree_children.any? ? '│ ' : '  '
          output_attributes(span.attributes, content_prefix, severity: span_severity(span), tags: root_tags, progname: root_progname)
        end

        # Output tree children - they get [] for ancestor_continues (root doesn't count)
        tree_children.each_with_index do |child, index|
          child_is_last = (index == tree_children.length - 1)

          if child[:type] == :event
            output_event(child[:event], [], child_is_last)
          else
            output_node(child[:node], [], child_is_last)
          end
        end
      end

      def build_tree(spans, root)
        # Index spans by their span_id
        span_map = {}
        spans.each do |span|
          span_id = span.context.hex_span_id
          span_map[span_id] = { span: span, children: [] }
        end

        # Build parent-child relationships
        root_id = root.context.hex_span_id
        spans.each do |span|
          span_id = span.context.hex_span_id
          parent_id = span.parent_span_id.unpack1('H*')

          next if span_id == root_id
          next if parent_id == INVALID_SPAN_ID

          if span_map[parent_id]
            span_map[parent_id][:children] << span_map[span_id]
          end
        end

        # Sort children by start time
        span_map.each_value do |node|
          node[:children].sort_by! { |child| child[:span].start_timestamp }
        end

        span_map[root_id]
      end

      def visible_event?(event)
        @output.enabled?(event_severity(event))
      end

      def trace_has_error?(spans)
        spans.any? do |span|
          span_has_error_details?(span) ||
            (span.events || []).any? do |event|
              raw_exception_event?(event) || [Logger::ERROR, Logger::FATAL].include?(event_severity(event))
            end
        end
      end

      def node_output_severity(node)
        severities = []
        own = span_severity(node[:span])
        severities << own if @output.enabled?(own)
        (node[:span].events || []).each do |event|
          severity = event_severity(event)
          severities << severity if visible_event?(event)
        end
        node[:children].each do |child|
          severities << node_output_severity(child) if node_visible?(child)
        end
        severities.max || own
      end

      def node_visible?(node)
        @output.enabled?(span_severity(node[:span])) ||
          (node[:span].events || []).any? { |event| visible_event?(event) } ||
          node[:children].any? { |child| node_visible?(child) }
      end

      def output_node(node, ancestor_continues, is_last)
        span = node[:span]
        children = node[:children].select { |child| node_visible?(child) }
        events = (span.events || []).select { |event| visible_event?(event) }

        # Combine events and child spans as "tree children"
        tree_children = []
        events.each { |e| tree_children << { type: :event, event: e } }
        children.each { |child| tree_children << { type: :span, node: child } }

        # Sort by timestamp
        tree_children.sort_by! do |child|
          if child[:type] == :event
            child[:event].timestamp
          else
            child[:node][:span].start_timestamp
          end
        end

        has_children = tree_children.any?

        # Output span line
        prefix = build_branch_prefix(ancestor_continues, is_last)
        duration_ms = ((span.end_timestamp - span.start_timestamp) / 1_000_000.0).round(2)
        has_error = span.status&.code == OpenTelemetry::Trace::Status::ERROR
        span_id_short = span.context.hex_span_id[0..7]

        line = "#{c(:tree, prefix)}#{c(:span_name, "#{SPAN_MARKER} #{span.name}")}"
        line += " #{c(:span_id, span_id_short)}"
        line += " #{c(:duration, "#{duration_ms}ms")}"
        line += " #{c(:error_badge, 'ERROR')}" if has_error
        severity = node_output_severity(node)
        tags, progname = span_metadata(span)
        emit line, severity: severity, tags: tags, progname: progname

        # Output span attributes
        content_prefix = build_content_prefix(ancestor_continues, is_last, has_children)
        if @output.enabled?(span_severity(span)) && visible_attributes(span.attributes).any?
          output_attributes(span.attributes, content_prefix, severity: span_severity(span), tags: tags, progname: progname)
        end

        # Output tree children
        tree_children.each_with_index do |child, index|
          child_is_last = (index == tree_children.length - 1)
          child_ancestor_continues = ancestor_continues + [!is_last]

          if child[:type] == :event
            output_event(child[:event], child_ancestor_continues, child_is_last)
          else
            output_node(child[:node], child_ancestor_continues, child_is_last)
          end
        end
      end

      def output_event(event, ancestor_continues, is_last)
        prefix = build_branch_prefix(ancestor_continues, is_last)
        return unless visible_event?(event)

        severity = event_severity(event)
        event_color = event_color_for(event.name, severity: severity)
        tags, progname = event_metadata(event)

        line = "#{c(:tree, prefix)}#{c(event_color, "#{EVENT_MARKER} #{event_label(event.name, event.attributes, severity)}#{event.name}")}"
        emit line, severity: severity, tags: tags, progname: progname

        # Event attributes - align under the event name (past the + marker)
        if visible_attributes(event.attributes).any?
          content_prefix = ''
          ancestor_continues.each { |c| content_prefix += c ? '│ ' : '  ' }
          content_prefix += is_last ? '    ' : '│   ' # 4 chars to skip past "└ + " or "├ + "
          output_attributes(event.attributes, content_prefix, severity: severity, tags: tags, progname: progname)
        end
      end

      def output_attributes(attributes, prefix, severity:, tags:, progname:)
        return if visible_attributes(attributes).empty?

        visible_attributes(attributes).each do |key, value|
          formatted = format_value(value)
          emit "#{c(:tree, prefix)}#{c(:attribute_key, key)}#{c(:punctuation, ':')} #{c(:attribute_value, formatted)}", severity: severity, tags: tags, progname: progname
        end
        emit c(:tree, prefix), severity: severity, tags: tags, progname: progname
      end

      def build_branch_prefix(ancestor_continues, is_last)
        prefix = ''
        ancestor_continues.each do |continues|
          prefix += continues ? '│ ' : '  '
        end
        prefix += is_last ? '└ ' : '├ '
        prefix
      end

      def build_content_prefix(ancestor_continues, is_last, has_children)
        prefix = ''

        # Draw continuation lines for ancestors
        ancestor_continues.each do |continues|
          prefix += continues ? '│ ' : '  '
        end

        # Current node's continuation (based on whether it has more siblings)
        prefix += is_last ? '  ' : '│ '

        # Add column for children - includes both child spans AND events
        prefix += has_children ? '│ ' : '  '

        prefix
      end
    end
  end
end
