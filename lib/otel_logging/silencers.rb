# frozen_string_literal: true

module OtelLogging
  module Silencers
    class << self
      # Silence default Rails log subscribers to avoid duplicate logging
      # when OTEL is handling the same events
      def silence_defaults!(config: OtelLogging.config)
        silence_action_controller! if config.enable_action_controller
        silence_action_cable! if config.enable_action_cable
        silence_action_view! if config.enable_action_view?
        silence_active_record! if config.enable_active_record
        silence_rack_logger!
      end

      # Silence ActionController's default "Processing by..." and "Completed..." logs
      def silence_action_controller!
        return unless defined?(ActionController::LogSubscriber)

        # Detach the default subscriber
        ActiveSupport::LogSubscriber.log_subscribers.each do |subscriber|
          if subscriber.is_a?(ActionController::LogSubscriber)
            unsubscribe_patterns(subscriber, [
              'start_processing.action_controller',
              'process_action.action_controller',
              'redirect_to.action_controller',
              'halted_callback.action_controller',
              'send_file.action_controller',
              'send_data.action_controller'
            ])
          end
        end
      end

      # Silence ActionCable's default WebSocket logs
      def silence_action_cable!
        return unless defined?(ActionCable)

        # Action Cable's connection logger is application-owned. Do not replace
        # or mute it globally; only detach a Rails log subscriber when one is
        # registered.
        return unless defined?(ActiveSupport::LogSubscriber)

        ActiveSupport::LogSubscriber.log_subscribers.each do |subscriber|
          next unless subscriber.class.name.to_s.start_with?("ActionCable::")

          unsubscribe_patterns(subscriber, subscriber.respond_to?(:patterns) ? subscriber.patterns : [])
        end
      end

      # Silence ActionView's default render logs
      def silence_action_view!
        return unless defined?(ActionView::LogSubscriber)

        ActiveSupport::LogSubscriber.log_subscribers.each do |subscriber|
          if subscriber.is_a?(ActionView::LogSubscriber)
            unsubscribe_patterns(subscriber, [
              'render_template.action_view',
              'render_partial.action_view',
              'render_collection.action_view',
              'render_layout.action_view'
            ])
          end
        end
      end

      # Silence ActiveRecord's default SQL logs
      def silence_active_record!
        return unless defined?(ActiveRecord::LogSubscriber)

        ActiveSupport::LogSubscriber.log_subscribers.each do |subscriber|
          if subscriber.is_a?(ActiveRecord::LogSubscriber)
            unsubscribe_patterns(subscriber, [
              'sql.active_record'
            ])
          end
        end
      end

      # Silence the Rack::Logger "Started GET" messages
      def silence_rack_logger!
        return unless defined?(Rails::Rack::Logger)

        Rails::Rack::Logger.class_eval do
          def started_request_message(*)
            nil
          end if instance_methods.include?(:started_request_message) || private_instance_methods.include?(:started_request_message)
        end
      end

      private

      def unsubscribe_patterns(subscriber, patterns)
        patterns.each do |pattern|
          ActiveSupport::Notifications.notifier.listeners_for(pattern).each do |listener|
            if listener.instance_variable_get(:@delegate) == subscriber
              ActiveSupport::Notifications.unsubscribe(listener)
            end
          end
        end
      end
    end
  end
end
