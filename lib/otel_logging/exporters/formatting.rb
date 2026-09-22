# frozen_string_literal: true

module OtelLogging
  module Exporters
    # Shared formatting utilities for trace output exporters
    module Formatting
      SPAN_MARKER = "◆"
      EVENT_MARKER = "+"
      INVALID_SPAN_ID = '0' * 16
      MAX_VALUE_LENGTH = 80
      SEVERITY_NAMES = {
        0 => 'DEBUG',
        1 => 'INFO',
        2 => 'WARN',
        3 => 'ERROR',
        4 => 'FATAL',
        5 => 'UNKNOWN'
      }.freeze
      INTERNAL_ATTRIBUTES = %w[log.severity log.tags log.progname].freeze

      private

      def span_error?(span)
        span.status&.code == OpenTelemetry::Trace::Status::ERROR
      end

      def span_has_error_details?(span)
        span_error?(span) || span.events&.any? { |event| raw_exception_event?(event) }
      end

      def span_severity(span)
        value = attribute(span.attributes, 'log.severity')
        return normalize_severity(value) unless value.nil?
        return Logger::ERROR if span_error?(span) || span.events&.any? { |event| raw_exception_event?(event) }

        Logger::INFO
      end

      def event_severity(event)
        severity_for(event.name, event.attributes)
      end

      def severity_for(name, attributes)
        value = attribute(attributes, 'log.severity')
        return normalize_severity(value) unless value.nil?
        return Logger::ERROR if name.to_s == 'exception' && attribute(attributes, 'log.severity').nil?

        Logger::INFO
      end

      def normalize_severity(value)
        Integer(value)
      rescue ArgumentError, TypeError
        Logger::INFO
      end

      def severity_name(severity)
        SEVERITY_NAMES.fetch(normalize_severity(severity), 'INFO')
      end

      def event_label(name, attributes, severity)
        return "#{severity_name(severity)} " if attribute(attributes, 'log.severity') || raw_exception?(name, attributes)

        ''
      end

      def raw_exception_event?(event)
        raw_exception?(event.name, event.attributes)
      end

      def raw_exception?(name, attributes)
        name.to_s == 'exception' && attribute(attributes, 'log.severity').nil?
      end

      def visible_attributes(attributes)
        (attributes || {}).reject { |key, _| INTERNAL_ATTRIBUTES.include?(key.to_s) }
      end

      def attribute(attributes, key)
        return unless attributes

        attributes[key] || attributes[key.to_sym]
      end

      def span_metadata(span)
        attributes = span.attributes || {}
        [attribute(attributes, 'log.tags'), attribute(attributes, 'log.progname')]
      end

      def event_metadata(event)
        attributes = event.attributes || {}
        [attribute(attributes, 'log.tags'), attribute(attributes, 'log.progname')]
      end

      def emit(message, severity: Logger::INFO, tags: nil, progname: nil, above: nil)
        severity = normalize_severity(severity)
        return unless @output.enabled?(severity)

        @output.write(message, severity: severity, tags: tags, progname: progname, above: above)
      end

      def theme
        OtelLogging.config.theme
      end

      def colorize_enabled?
        OtelLogging.config.colorize
      end

      # Apply theme style to text
      def c(element, text)
        return text unless colorize_enabled?
        theme.apply(element, text)
      rescue StandardError
        text
      end

      def event_color_for(name, severity: nil)
        if severity
          return :event_error if [Logger::ERROR, Logger::FATAL].include?(normalize_severity(severity))
          return :event_warn if normalize_severity(severity) == Logger::WARN
          return :event_info
        end

        name_lower = name.to_s.downcase
        return :event_error if name_lower.match?(/error|exception|fail|fatal/)
        return :event_warn if name_lower.match?(/warn|warning/)
        :event_info
      end

      def format_value(value)
        case value
        when Array
          "[#{value.map { |v| format_value(v) }.join(', ')}]"
        when String
          value.length > MAX_VALUE_LENGTH ? "#{value[0..(MAX_VALUE_LENGTH - 3)]}..." : value
        else
          value.to_s
        end
      end
    end
  end
end
