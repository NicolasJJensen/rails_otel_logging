# frozen_string_literal: true

module OtelLogging
  class Theme
    # Named colors mapped to ANSI codes
    NAMED_COLORS = {
      black: 0,
      red: 1,
      green: 2,
      yellow: 3,
      blue: 4,
      magenta: 5,
      cyan: 6,
      white: 7,
      gray: 8,
      bright_red: 9,
      bright_green: 10,
      bright_yellow: 11,
      bright_blue: 12,
      bright_magenta: 13,
      bright_cyan: 14,
      bright_white: 15,
    }.freeze

    DEFAULT_THEME = {
      # Trace header (neutral gray - metadata)
      trace_label: { fg: :gray },
      trace_id: { fg: :gray },

      # Span elements (purple)
      span_marker: { fg: "#aa75ff", bold: true },
      span_name: { fg: "#aa75ff", bold: true },
      span_id: { fg: :gray },
      duration: { fg: :yellow },

      # Attributes
      attribute_key: { fg: 108 },      # 256-color: muted green
      attribute_value: { fg: 249 },    # 256-color: light gray

      # Tree drawing characters
      tree: { fg: :gray },

      # Events (purple with pink shift)
      event_marker: { fg: "#e075ff" },
      event_info: { fg: "#e075ff" },
      event_warn: { fg: :yellow, bold: true },
      event_error: { fg: :red, bold: true },

      # Punctuation (colons, etc.)
      punctuation: { fg: :gray },

      # Error status on spans
      error_badge: { fg: :red, bold: true },
    }.freeze

    attr_reader :styles

    def initialize(custom_styles = {})
      @styles = DEFAULT_THEME.merge(custom_styles)
    end

    # Get ANSI escape sequence for a style
    def ansi(element)
      style = @styles[element]
      return '' unless style

      codes = []

      # Bold
      codes << 1 if style[:bold]

      # Foreground color
      if style[:fg]
        codes.concat(fg_codes(style[:fg]))
      end

      return '' if codes.empty?

      "\e[#{codes.join(';')}m"
    end

    # Get reset sequence
    def reset
      "\e[0m"
    end

    # Apply style to text
    def apply(element, text)
      "#{ansi(element)}#{text}#{reset}"
    end

    # Update a single style
    def set(element, **options)
      @styles[element] = (@styles[element] || {}).merge(options)
    end

    # Bulk update styles
    def update(styles_hash)
      styles_hash.each do |element, options|
        @styles[element] = (@styles[element] || {}).merge(options)
      end
    end

    private

    def fg_codes(color)
      case color
      when Symbol
        # Named color (0-15)
        code = NAMED_COLORS[color]
        return [] unless code
        if code < 8
          [30 + code]
        else
          [90 + (code - 8)]
        end
      when Integer
        # 256-color mode
        [38, 5, color]
      when String
        # Hex color -> convert to nearest 256 color (simplified)
        if color.start_with?('#') && color.length == 7
          r = color[1..2].to_i(16)
          g = color[3..4].to_i(16)
          b = color[5..6].to_i(16)
          [38, 2, r, g, b]  # True color
        else
          []
        end
      else
        []
      end
    end
  end
end
