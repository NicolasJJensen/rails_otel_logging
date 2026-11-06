# frozen_string_literal: true

require "active_support"
require "active_support/notifications"

require "otel_logging/logger_extension"
require "otel_logging/middleware/trace"
require "otel_logging/silencers"
require "otel_logging/framework_instrumentation"

module OtelLogging
  module RailsIntegration
    class << self
      def install!(application:, logger: Rails.logger, tracer_provider: nil)
        FrameworkInstrumentation.install_event_origin!
        OtelLogging.config.instrumentation.enable_framework!
        provider = tracer_provider || configured_provider
        unless provider.respond_to?(:add_span_processor) && provider.respond_to?(:tracer)
          raise ArgumentError, 'tracer_provider must resolve to an SDK tracer provider'
        end
        OtelLogging.install!(logger: logger, tracer_provider: provider)
        install_middleware!(application)
        install_load_hooks!
        Silencers.silence_defaults!
        application
      end

      private

      def configured_provider
        provider = OtelLogging.config.tracer_provider
        return provider.call if provider.respond_to?(:call)
        return provider unless provider.nil?

        @managed_provider ||= begin
          resource = OpenTelemetry::SDK::Resources::Resource.create(
            'service.name' => OtelLogging.config.service_name,
            'service.version' => OtelLogging.config.service_version
          )
          owned_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(resource: resource)
          at_exit do
            begin
              owned_provider.force_flush
            ensure
              owned_provider.shutdown
            end
          end
          owned_provider
        end
      end

      def install_middleware!(application)
        @middleware_applications ||= []
        return if @middleware_applications.any? { |installed| installed.equal?(application) }

        application.middleware.insert_before(0, OtelLogging::Middleware::Trace)
        @middleware_applications << application
      end

      def install_load_hooks!
        return if @load_hooks_installed

        [:action_controller_base, :action_controller_api, :action_view, :active_record, :action_cable].each do |hook|
          ActiveSupport.on_load(hook) do
            OtelLogging::FrameworkInstrumentation.install_view_start! if hook == :action_view
            OtelLogging::Silencers.silence_defaults!
          end
        end
        @load_hooks_installed = true
      end
    end
  end
end
