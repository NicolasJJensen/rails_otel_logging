# frozen_string_literal: true

require 'active_support/notifications'

module OtelLogging
  module Subscribers
    class ActionCable
      class << self
        def subscribe!
          subscriber = new

          # Fired when a channel action is performed
          ActiveSupport::Notifications.subscribe('perform_action.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            subscriber.handle_perform_action(event)
          end

          # Fired when data is transmitted to the client
          ActiveSupport::Notifications.subscribe('transmit.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            subscriber.handle_transmit(event)
          end

          # Fired when broadcasting to a channel
          ActiveSupport::Notifications.subscribe('broadcast.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            subscriber.handle_broadcast(event)
          end

          # Fired when a subscription is confirmed
          ActiveSupport::Notifications.subscribe('transmit_subscription_confirmation.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            subscriber.handle_subscription_confirmation(event)
          end

          # Fired when a subscription is rejected
          ActiveSupport::Notifications.subscribe('transmit_subscription_rejection.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            subscriber.handle_subscription_rejection(event)
          end
        end
      end

      def handle_perform_action(event)
        return unless TraceContext.current.active?

        payload = event.payload
        channel_class = payload[:channel_class]
        action = payload[:action]
        data = payload[:data]

        event_name = "websocket.action.#{channel_class.underscore}.#{action}"

        attributes = {
          'websocket.channel' => channel_class,
          'websocket.action' => action.to_s,
          'websocket.duration_ms' => event.duration.round(2)
        }

        # Add data attributes (filtered)
        if data.is_a?(Hash)
          data.each do |key, value|
            attributes["websocket.data.#{key}"] = format_value(value)
          end
        end

        OtelLogging.logger.event(event_name, **attributes)
      end

      def handle_transmit(event)
        return unless TraceContext.current.active?

        payload = event.payload
        channel_class = payload[:channel_class]
        data = payload[:data]
        via = payload[:via]

        event_name = "websocket.transmit.#{channel_class.underscore}"

        attributes = {
          'websocket.channel' => channel_class,
          'websocket.via' => via
        }

        # Summarize data being transmitted
        if data.is_a?(Hash)
          attributes['websocket.data_keys'] = data.keys.join(', ')
        end

        OtelLogging.logger.event(event_name, **attributes)
      end

      def handle_broadcast(event)
        return unless TraceContext.current.active?

        payload = event.payload
        broadcasting = payload[:broadcasting]
        message = payload[:message]
        coder = payload[:coder]

        event_name = "websocket.broadcast.#{broadcasting}"

        attributes = {
          'websocket.broadcasting' => broadcasting,
          'websocket.coder' => coder.to_s
        }

        # Summarize message being broadcast
        if message.is_a?(Hash)
          attributes['websocket.message_keys'] = message.keys.join(', ')
        end

        OtelLogging.logger.event(event_name, **attributes)
      end

      def handle_subscription_confirmation(event)
        return unless TraceContext.current.active?

        payload = event.payload
        channel_class = payload[:channel_class]
        identifier = payload[:identifier]

        event_name = "websocket.subscribed.#{channel_class.underscore}"

        attributes = {
          'websocket.channel' => channel_class,
          'websocket.identifier' => identifier.to_s.truncate(100)
        }

        OtelLogging.logger.event(event_name, **attributes)
      end

      def handle_subscription_rejection(event)
        return unless TraceContext.current.active?

        payload = event.payload
        channel_class = payload[:channel_class]
        identifier = payload[:identifier]

        event_name = "websocket.rejected.#{channel_class.underscore}"

        attributes = {
          'websocket.channel' => channel_class,
          'websocket.identifier' => identifier.to_s.truncate(100)
        }

        OtelLogging.logger.event(event_name, **attributes)
      end

      private

      def format_value(value)
        case value
        when Hash
          value.to_json.truncate(100)
        when Array
          "[#{value.length} items]"
        else
          value.to_s.truncate(100)
        end
      rescue StandardError
        value.to_s.truncate(50)
      end
    end
  end
end
