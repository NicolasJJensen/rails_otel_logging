# frozen_string_literal: true

module OtelLogging
  module Silencers
    module ActionControllerMethods
      def start_processing(event)
        return if OtelLogging::Silencers.replace_logs?(:action_controller)

        super
      end

      def process_action(event)
        return if OtelLogging::Silencers.replace_logs?(:action_controller)

        super
      end

      def redirect_to(event)
        return if OtelLogging::Silencers.replace_logs?(:action_controller)

        super
      end

      def halted_callback(event)
        return if OtelLogging::Silencers.replace_logs?(:action_controller)

        super
      end
    end

    module ActionViewMethods
      def render_template(event)
        return if OtelLogging::Silencers.replace_view_logs?(:template, event)

        super
      end

      def render_partial(event)
        return if OtelLogging::Silencers.replace_view_logs?(:partial, event)

        super
      end

      def render_collection(event)
        return if OtelLogging::Silencers.replace_view_logs?(:partial, event)

        super
      end

      def render_layout(event)
        return if OtelLogging::Silencers.replace_view_logs?(:layout, event)

        super
      end
    end

    module ActionViewStartMethods
      def start(name, id, payload)
        return if OtelLogging::Silencers.replace_view_start_logs?(name)

        super
      end
    end

    module ActiveRecordMethods
      def sql(event)
        return if OtelLogging::Silencers.replace_logs?(:active_record)

        super
      end
    end

    module RackLoggerMethods
      private

      def started_request_message(request)
        return nil if OtelLogging::Silencers.replace_logs?(:rack)

        super
      end
    end

    class << self
      def silence_defaults!(config: OtelLogging.config)
        silence_action_controller! if config.enable_action_controller
        silence_action_view! if config.enable_action_view?
        silence_active_record! if config.enable_active_record
        silence_rack_logger!
      end

      def replace_logs?(component)
        return false unless OtelLogging::TraceContext.current.active?

        config = OtelLogging.config
        config.rails_logs == :replace && replacement_enabled?(config, component)
      end

      def replace_view_logs?(kind, _event)
        return false unless replace_logs?(:action_view)

        config = OtelLogging.config
        case kind
        when :template
          config.enable_templates
        when :partial
          config.enable_partials
        when :layout
          config.enable_layouts
        else
          false
        end
      end

      def replace_view_start_logs?(name)
        return false unless replace_logs?(:action_view)

        case name
        when 'render_template.action_view'
          OtelLogging.config.enable_templates
        when 'render_layout.action_view'
          OtelLogging.config.enable_layouts
        else
          false
        end
      end

      private

      def replacement_enabled?(config, component)
        case component
        when :action_controller then config.enable_action_controller
        when :action_view then config.enable_action_view?
        when :active_record then config.enable_active_record
        when :rack then true
        else false
        end
      end

      def silence_action_controller!
        return unless defined?(ActionController::LogSubscriber)

        prepend_once(ActionController::LogSubscriber, ActionControllerMethods)
      end

      def silence_action_view!
        return unless defined?(ActionView::LogSubscriber)

        prepend_once(ActionView::LogSubscriber, ActionViewMethods)
        if defined?(ActionView::LogSubscriber::Start)
          prepend_once(ActionView::LogSubscriber::Start, ActionViewStartMethods)
        end
      end

      def silence_active_record!
        return unless defined?(ActiveRecord::LogSubscriber)

        prepend_once(ActiveRecord::LogSubscriber, ActiveRecordMethods)
      end

      def silence_rack_logger!
        return unless defined?(Rails::Rack::Logger)

        prepend_once(Rails::Rack::Logger, RackLoggerMethods)
      end

      def prepend_once(klass, mod)
        klass.prepend(mod) unless klass.ancestors.include?(mod)
      end
    end
  end
end
