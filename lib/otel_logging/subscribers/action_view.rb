# frozen_string_literal: true

require 'active_support/notifications'

module OtelLogging
  module Subscribers
    class ActionView
      PARTIAL_DEPTH_KEY = :otel_action_view_partial_depth

      class << self
        def subscribe!
          subscriber = SpanSubscriber.new

          ActiveSupport::Notifications.subscribe('render_template.action_view', subscriber)
          ActiveSupport::Notifications.subscribe('render_partial.action_view', subscriber)
          ActiveSupport::Notifications.subscribe('render_collection.action_view', subscriber)
        end
      end

      # Subscriber that wraps rendering in spans using OTel's manual span API
      class SpanSubscriber
        def start(name, id, payload)
          template_name = extract_template_name(payload[:identifier])
          return unless template_name

          # Check if this render type should be logged
          return unless should_log?(name, payload, template_name)

          # Track partial depth
          if partial?(name)
            increment_partial_depth
            payload[:__otel_depth] = current_partial_depth
          end

          span_name = build_span_name(name, template_name)
          attributes = build_attributes(name, payload)

          # Start span using OTel's manual API
          span = tracer.start_span(span_name, attributes: attributes)

          # Activate span context
          token = OpenTelemetry::Context.attach(
            OpenTelemetry::Trace.context_with_span(span)
          )

          # Store span and token in payload for finish() to access
          payload[:__otel_span] = span
          payload[:__otel_token] = token
        end

        def finish(name, id, payload)
          # Decrement partial depth even if span wasn't created
          if partial?(name) && payload[:__otel_depth]
            decrement_partial_depth
          end

          span = payload[:__otel_span]
          token = payload[:__otel_token]

          # Log exception with full backtrace in standard format
          if payload[:exception_object]
            e = payload[:exception_object]
            template = extract_template_name(payload[:identifier])
            OtelLogging.logger.error("\n#{e.class} (#{e.message}):")
            OtelLogging.logger.error("  Template: #{template}") if template
            OtelLogging.logger.error(e.backtrace&.join("\n"))
          end

          return unless span

          # Add any additional attributes from the completed render
          if payload[:count]
            span.set_attribute('view.count', payload[:count])
          end

          span.finish
          OpenTelemetry::Context.detach(token) if token
        end

        private

        def config
          OtelLogging.config
        end

        def tracer
          @tracer ||= OpenTelemetry.tracer_provider.tracer('rails_otel_logging-actionview')
        end

        def should_log?(notification_name, payload, template_name)
          # Check allowlist/denylist first
          return false unless config.view_allowed?(template_name)

          case notification_name
          when 'render_template.action_view'
            # Check if it's a layout render
            if payload[:layout]
              config.enable_layouts
            else
              config.enable_templates
            end
          when 'render_partial.action_view', 'render_collection.action_view'
            return false unless config.enable_partials

            # Check depth limit
            max_depth = config.partial_max_depth
            return true if max_depth.nil? # No limit

            # Depth is 1-based: first partial is depth 1
            next_depth = current_partial_depth + 1
            next_depth <= max_depth
          else
            true
          end
        end

        def partial?(notification_name)
          notification_name == 'render_partial.action_view' ||
            notification_name == 'render_collection.action_view'
        end

        def current_partial_depth
          Thread.current[PARTIAL_DEPTH_KEY] || 0
        end

        def increment_partial_depth
          Thread.current[PARTIAL_DEPTH_KEY] = current_partial_depth + 1
        end

        def decrement_partial_depth
          depth = current_partial_depth - 1
          Thread.current[PARTIAL_DEPTH_KEY] = depth >= 0 ? depth : 0
        end

        def build_span_name(notification_name, template_name)
          case notification_name
          when 'render_template.action_view'
            "render #{template_name}"
          when 'render_partial.action_view'
            "render partial #{template_name}"
          when 'render_collection.action_view'
            "render collection #{template_name}"
          else
            "render #{template_name}"
          end
        end

        def build_attributes(notification_name, payload)
          attrs = {}

          if payload[:layout]
            attrs['view.layout'] = extract_template_name(payload[:layout])
          end

          # Add request params if available (only for templates, not partials)
          if notification_name == 'render_template.action_view' && config.include_params_in_views
            params = ActionController.current_params
            if params&.any?
              params.each do |key, value|
                next if %w[controller action format].include?(key.to_s)
                attrs["params.#{key}"] = format_param_value(value)
              end
            end
          end

          attrs
        end

        def format_param_value(value)
          case value
          when Hash
            value.to_json
          when Array
            value.map { |v| format_param_value(v) }.join(', ')
          else
            value.to_s.truncate(100)
          end
        rescue StandardError
          value.to_s
        end

        def extract_template_name(identifier)
          return nil unless identifier.is_a?(String)

          if defined?(Rails.root) && Rails.root
            identifier = identifier.sub(Rails.root.to_s + '/', '')
          end

          identifier
            .sub(%r{^app/views/}, '')
            .sub(%r{^app/}, '')
        end
      end
    end
  end
end
