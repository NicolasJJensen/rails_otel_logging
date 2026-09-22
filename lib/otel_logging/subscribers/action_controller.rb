# frozen_string_literal: true

require 'active_support/notifications'

module OtelLogging
  module Subscribers
    class ActionController
      REQUEST_PARAMS_KEY = :otel_request_params

      # Params to always filter out
      DEFAULT_FILTERED_PARAMS = %w[
        password password_confirmation
        secret token api_key
        credit_card card_number cvv
        authenticity_token
      ].freeze

      class << self
        def subscribe!
          subscriber = new

          # Fired at the start of processing (the "Processing by..." log line)
          ActiveSupport::Notifications.subscribe('start_processing.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            subscriber.handle_start_processing(event)
          end

          # Fired when processing completes (with timing info)
          ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            subscriber.handle_process_action(event)
          end

          # Fired on redirects
          ActiveSupport::Notifications.subscribe('redirect_to.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            subscriber.handle_redirect(event)
          end

          # Fired when a callback halts the request
          ActiveSupport::Notifications.subscribe('halted_callback.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            subscriber.handle_halted_callback(event)
          end
        end

        # Store params for view rendering to access
        def store_params(params)
          Thread.current[REQUEST_PARAMS_KEY] = params
        end

        # Retrieve stored params
        def current_params
          Thread.current[REQUEST_PARAMS_KEY]
        end

        # Clear stored params (called at end of request)
        def clear_params
          Thread.current[REQUEST_PARAMS_KEY] = nil
        end
      end

      def handle_start_processing(event)
        return unless TraceContext.current.active?

        payload = event.payload

        controller = payload[:controller]
        action = payload[:action]
        format = payload[:format]
        method = payload[:method]
        path = payload[:path]
        params = payload[:params]

        # Store filtered params for view rendering
        filtered = filter_params(params)
        self.class.store_params(filtered)

        # Build event name
        event_name = "controller.#{controller.underscore}.#{action}"

        attributes = {
          'controller.name' => controller,
          'controller.action' => action,
          'controller.format' => format.to_s,
          'http.method' => method,
          'http.path' => path
        }

        # Add filtered params (skip controller/action since they're already logged)
        filtered.each do |key, value|
          next if %w[controller action format].include?(key.to_s)
          attributes["params.#{key}"] = format_param_value(value)
        end

        OtelLogging.logger.event(event_name, **attributes)
      end

      def handle_process_action(event)
        # Clear params at end of request
        self.class.clear_params
        return unless TraceContext.current.active?

        payload = event.payload

        # Log exception with full backtrace in standard format
        if payload[:exception_object]
          e = payload[:exception_object]
          OtelLogging.logger.error("\n#{e.class} (#{e.message}):")
          OtelLogging.logger.error(e.backtrace&.join("\n"))
        elsif payload[:exception]
          # Fallback to exception array [class_name, message]
          exception_class, exception_message = payload[:exception]
          OtelLogging.logger.error("\n#{exception_class} (#{exception_message})")
        end
      end

      def handle_redirect(event)
        return unless TraceContext.current.active?

        payload = event.payload
        location = payload[:location]
        status = payload[:status]

        OtelLogging.logger.event('controller.redirect',
          'redirect.location' => location,
          'redirect.status' => status
        )
      end

      def handle_halted_callback(event)
        return unless TraceContext.current.active?

        payload = event.payload
        filter = payload[:filter]

        OtelLogging.logger.event('controller.halted',
          'halted.filter' => filter.to_s
        )
      end

      private

      def filter_params(params)
        return {} if params.nil?

        # Use Rails' built-in parameter filter if available
        if defined?(ActiveSupport::ParameterFilter) && defined?(Rails.application)
          filter = ActiveSupport::ParameterFilter.new(
            Rails.application.config.filter_parameters + DEFAULT_FILTERED_PARAMS
          )
          filter.filter(params.to_unsafe_h)
        else
          # Manual filtering
          params.to_unsafe_h.transform_values do |value|
            if DEFAULT_FILTERED_PARAMS.any? { |f| value.to_s.downcase.include?(f) }
              '[FILTERED]'
            else
              value
            end
          end
        end
      rescue StandardError
        {}
      end

      def format_param_value(value)
        case value
        when Hash
          value.to_json
        when Array
          value.map { |v| format_param_value(v) }.join(', ')
        when ActionDispatch::Http::UploadedFile
          "[File: #{value.original_filename}]"
        else
          value.to_s.truncate(100)
        end
      rescue StandardError
        value.to_s.truncate(100)
      end
    end
  end
end
