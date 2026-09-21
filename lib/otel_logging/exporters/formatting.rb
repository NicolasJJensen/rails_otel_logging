# frozen_string_literal: true

module OtelLogging
  module Exporters
    # Shared formatting utilities for trace output exporters
    module Formatting
      SPAN_MARKER = "◆"
      EVENT_MARKER = "+"
      INVALID_SPAN_ID = '0' * 16
      MAX_VALUE_LENGTH = 80

      private

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

      def event_color_for(name)
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
