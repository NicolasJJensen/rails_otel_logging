# frozen_string_literal: true

require "active_support"
require "active_support/notifications"
require "action_controller"
require "action_dispatch"

require "otel_logging/logger_extension"
require "otel_logging/controller_helpers"
require "otel_logging/middleware/trace"
require "otel_logging/silencers"
require "otel_logging/subscribers/action_controller"
require "otel_logging/subscribers/action_view"
require "otel_logging/subscribers/active_record"
require "otel_logging/subscribers/action_cable"

module OtelLogging
  module RailsIntegration
    SUBSCRIBERS = [
      ["OtelLogging::Subscribers::ActionController", :enable_action_controller],
      ["OtelLogging::Subscribers::ActionView", :enable_action_view?],
      ["OtelLogging::Subscribers::ActiveRecord", :enable_active_record],
      ["OtelLogging::Subscribers::ActionCable", :enable_action_cable]
    ].freeze

    class << self
      def install!(application:, logger:, tracer_provider:)
        OtelLogging.install!(logger: logger, tracer_provider: tracer_provider)
        inject_logger!(logger)
        install_middleware!(application)
        install_subscribers!
        silence_defaults! if OtelLogging.config.silence_default_logs
        application
      end

      private

      def inject_logger!(logger)
        logger.extend(OtelLogging::LoggerExtension) unless logger.respond_to?(:with_trace)
      end

      def install_middleware!(application)
        @middleware_applications ||= []
        return if @middleware_applications.any? { |installed| installed.equal?(application) }

        application.middleware.insert_before(0, OtelLogging::Middleware::Trace)
        @middleware_applications << application
      end

      def install_subscribers!
        SUBSCRIBERS.each do |name, setting|
          next unless subscriber_available?(name)
          next if subscriber_installed?(name)
          next if setting && !setting_enabled?(setting)

          subscriber = Object.const_get(name)
          subscriber.subscribe!
          @installed_subscribers ||= {}
          @installed_subscribers[name] = true
        end
      end

      def subscriber_available?(name)
        name.split("::").reject(&:empty?).reduce(Object) { |scope, part| scope.const_get(part) }
        true
      rescue NameError
        false
      end

      def subscriber_installed?(name)
        @installed_subscribers && @installed_subscribers[name]
      end

      def setting_enabled?(setting)
        value = OtelLogging.config.public_send(setting)
        value.respond_to?(:call) ? value.call : value
      end

      def silence_defaults!
        OtelLogging::Silencers.silence_defaults!
      end
    end
  end
end
