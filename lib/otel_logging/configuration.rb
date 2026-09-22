# frozen_string_literal: true

module OtelLogging
  class Configuration
    VALID_OUTPUT_MODES = [:live, :delayed, :both, :live_delayed_on_error].freeze
    VALID_RAILS_LOG_MODES = [:replace, :preserve].freeze

    attr_accessor :service_name, :service_version, :enable_active_record,
                  :tracer_provider
    attr_writer :colorize
    attr_reader :theme

    # ActionController settings
    attr_accessor :enable_action_controller,  # Log controller processing events
                  :include_params_in_views    # Include request params in view render spans

    # ActionCable settings
    attr_accessor :enable_action_cable        # Log WebSocket events

    # ActionView settings
    attr_accessor :enable_templates,    # Log template renders (main views)
                  :enable_layouts,      # Log layout renders
                  :enable_partials,     # Log partial renders
                  :partial_max_depth,   # Max nesting depth for partials (nil = unlimited)
                  :view_allowlist,      # Array of patterns - only log matching paths
                  :view_denylist        # Array of patterns - skip matching paths

    attr_reader :output_mode, :rails_logs

    def initialize
      @output_mode = :live_delayed_on_error
      @service_name = 'rails_app'
      @service_version = '1.0.0'
      @enable_active_record = env_bool('OTEL_ACTIVE_RECORD', true)
      self.rails_logs = ENV.fetch('OTEL_RAILS_LOGS', 'replace').to_sym
      @colorize = detect_color_support
      @theme = Theme.new

      # ActionController defaults
      @enable_action_controller = env_bool('OTEL_ACTION_CONTROLLER', true)
      @include_params_in_views = env_bool('OTEL_VIEW_PARAMS', true)

      # ActionCable defaults
      @enable_action_cable = env_bool('OTEL_ACTION_CABLE', true)

      # ActionView defaults
      @enable_templates = env_bool('OTEL_VIEW_TEMPLATES', true)
      @enable_layouts = env_bool('OTEL_VIEW_LAYOUTS', true)
      @enable_partials = env_bool('OTEL_VIEW_PARTIALS', true)
      @partial_max_depth = env_int('OTEL_VIEW_PARTIAL_DEPTH', nil)
      @view_allowlist = nil
      @view_denylist = nil
    end

    def colorize
      return @colorize unless @colorize.nil?

      # Resolve lazily so loading the core before Rails preserves Rails defaults.
      !!(defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.development?)
    end

    # Convenience method to check if any ActionView logging is enabled
    def enable_action_view?
      @enable_templates || @enable_layouts || @enable_partials
    end

    # For backwards compatibility
    def enable_action_view
      enable_action_view?
    end

    def enable_action_view=(value)
      @enable_templates = value
      @enable_layouts = value
      @enable_partials = value
    end

    def output_mode=(mode)
      unless VALID_OUTPUT_MODES.include?(mode)
        raise ArgumentError, "Invalid output_mode: #{mode}. Must be one of: #{VALID_OUTPUT_MODES.join(', ')}"
      end
      @output_mode = mode
    end

    def rails_logs=(mode)
      unless VALID_RAILS_LOG_MODES.include?(mode)
        raise ArgumentError, "Invalid rails_logs: #{mode}. Must be one of: #{VALID_RAILS_LOG_MODES.join(', ')}"
      end
      @rails_logs = mode
    end

    def live?
      [:live, :both, :live_delayed_on_error].include?(@output_mode)
    end

    def delayed?
      [:delayed, :both].include?(@output_mode)
    end

    def delayed_on_error?
      @output_mode == :live_delayed_on_error
    end

    # Check if a view path should be logged based on allowlist/denylist
    def view_allowed?(path)
      return false if path.nil?

      # If denylist is set and path matches any pattern, deny
      if @view_denylist&.any?
        return false if matches_any_pattern?(path, @view_denylist)
      end

      # If allowlist is set, path must match at least one pattern
      if @view_allowlist&.any?
        return matches_any_pattern?(path, @view_allowlist)
      end

      true
    end

    private

    def matches_any_pattern?(path, patterns)
      patterns.any? do |pattern|
        case pattern
        when Regexp
          path.match?(pattern)
        when String
          # Support glob-style patterns with * and **
          if pattern.include?('*')
            regex = Regexp.escape(pattern)
            # **/ matches zero or more directories
            regex = regex.gsub('\*\*/', '(.*/)?')
            # ** alone matches anything
            regex = regex.gsub('\*\*', '.*')
            # * matches single path segment
            regex = regex.gsub('\*', '[^/]*')
            path.match?(/^#{regex}/)
          else
            # Simple substring/prefix match
            path.start_with?(pattern) || path.include?(pattern)
          end
        else
          false
        end
      end
    end

    def env_bool(key, default)
      val = ENV[key]
      return default if val.nil?
      %w[true 1 yes on].include?(val.downcase)
    end

    def env_int(key, default)
      val = ENV[key]
      return default if val.nil?
      val.to_i
    end

    def detect_color_support
      # Check explicit env var first
      return env_bool('OTEL_COLORIZE', true) if ENV['OTEL_COLORIZE']

      # No colors if NO_COLOR is set (standard)
      return false if ENV['NO_COLOR']

      nil
    end
  end

  class << self
    attr_accessor :live_exporter

    def config
      @config ||= Configuration.new
    end

    # Configuration is deliberately separate from SDK installation. This
    # makes the gem safe to embed in applications that own their provider.
    def configure
      yield config if block_given?
      config
    end

    # Notify the live exporter about an event (for real-time output)
    def notify_event(name, attributes, context)
      return unless @live_exporter
      @live_exporter.on_event(name, attributes, context)
    end
  end
end
