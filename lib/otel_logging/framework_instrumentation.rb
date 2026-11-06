# frozen_string_literal: true

module OtelLogging
  module FrameworkInstrumentation
    VIEW_TYPES = {
      'render_template.action_view' => :template,
      'render_layout.action_view' => :layout,
      'render_partial.action_view' => :partial,
      'render_collection.action_view' => :partial
    }.freeze
    EVENT_NOTIFICATIONS = {
      'action_controller.request_completed' => 'process_action.action_controller',
      'active_record.sql' => 'sql.active_record',
      'action_view.render_template' => 'render_template.action_view',
      'action_view.render_layout' => 'render_layout.action_view',
      'action_view.render_partial' => 'render_partial.action_view',
      'action_view.render_collection' => 'render_collection.action_view'
    }.freeze
    SQL_IGNORED = /\A(?:EXPLAIN |SET |SHOW |BEGIN\z|COMMIT\z|ROLLBACK\z|SAVEPOINT |RELEASE SAVEPOINT )|schema_migrations|ar_internal_metadata/i
    CABLE_OPERATIONS = %w[perform_action transmit broadcast transmit_subscription_confirmation transmit_subscription_rejection].freeze

    def self.rule_for(notification_name, payload)
      config = OtelLogging.config
      transform = case notification_name
      when 'process_action.action_controller'
        if config.enable_action_controller
          proc do |_name, data|
            controller = data[:controller].to_s.delete_suffix('Controller').underscore
            name "#{controller}##{data[:action]}"
            attributes('rails.controller' => controller, 'rails.action' => data[:action],
                       'rails.format' => data[:format].to_s, 'http.status_code' => data[:status])
          end
        end
      when 'sql.active_record'
        if config.enable_active_record && payload[:sql].is_a?(String) &&
            !%w[SCHEMA EXPLAIN].include?(payload[:name]) && !SQL_IGNORED.match?(payload[:sql])
          proc do |_name, data|
            sql = data[:sql]
            operation = sql.lstrip[/\A(?:SELECT|INSERT|UPDATE|DELETE)\b/i]&.downcase || 'query'
            table = sql[/\b(?:FROM|INTO|UPDATE)\s+["`]?(\w+)/i, 1]
            name ['db', operation, table].compact.join('.')
            attributes('db.statement' => sql, 'db.cached' => !!data[:cached])
          end
        end
      else
        if VIEW_TYPES.key?(notification_name) && view_enabled?(notification_name, payload)
          proc do |event_name, data|
            kind = VIEW_TYPES[event_name]
            identifier = FrameworkInstrumentation.view_path(data[:identifier] || 'templates')
            prefix = kind == :template ? 'render' : "render #{kind}"
            name "#{prefix} #{identifier}"
            values = { 'view.identifier' => identifier, 'view.layout' => data[:layout], 'view.count' => data[:count] }
            if kind == :template && OtelLogging.config.include_params_in_views
              controller = Instrumentation.frames.reverse.find { |frame| frame[:name] == 'process_action.action_controller' }
              values['params'] = controller[:payload][:params] if controller
            end
            attributes(values)
          end
        elsif notification_name.end_with?('.action_cable') && config.enable_action_cable &&
            CABLE_OPERATIONS.include?(notification_name.delete_suffix('.action_cable'))
          proc do |event_name, data|
            operation = event_name.delete_suffix('.action_cable')
            name ['websocket', operation, data[:channel_class], data[:action]].compact.join('.')
            attributes('websocket.channel' => data[:channel_class], 'websocket.action' => data[:action],
                       'websocket.broadcasting' => data[:broadcasting], 'websocket.via' => data[:via])
          end
        end
      end
      Instrumentation::Rule.new(matcher: notification_name, transform: transform) if transform
    end

    def self.view_path(identifier)
      path = identifier.to_s
      path = path.delete_prefix("#{Rails.root}/") if defined?(Rails.root) && Rails.root
      path.delete_prefix('app/views/').delete_prefix('app/')
    end

    def self.view_enabled?(notification_name, payload)
      config = OtelLogging.config
      kind = VIEW_TYPES[notification_name]
      enabled = case kind
      when :template then config.enable_templates
      when :layout then config.enable_layouts
      when :partial then config.enable_partials
      end
      identifier = payload[:identifier]
      identifier ||= 'templates' if notification_name == 'render_collection.action_view'
      return false unless enabled && identifier.is_a?(String) && config.view_allowed?(view_path(identifier))
      return true unless kind == :partial && config.partial_max_depth

      depth = Instrumentation.frames.count { |frame| VIEW_TYPES[frame[:name]] == :partial && frame[:handle] }
      depth < config.partial_max_depth
    end

    module ViewStart
      def start(name, id, payload)
        # Rails may emit render_start before our regular lifecycle callback.
        # Begin the same invocation early; the regular callback then reuses it.
        OtelLogging.config.instrumentation.start_view(name, id, payload, source: :native_view_start)
        super
      end
    end

    def self.install_view_start!
      return unless defined?(ActionView::StructuredEventSubscriber::Start)

      klass = ActionView::StructuredEventSubscriber::Start
      klass.prepend(ViewStart) unless klass.ancestors.include?(ViewStart)
    end

    module EventOrigin
      def call(event)
        previous = Thread.current[:otel_native_notification]
        Thread.current[:otel_native_notification] = event
        super
      ensure
        Thread.current[:otel_native_notification] = previous
      end
    end

    def self.install_event_origin!
      require 'active_support/structured_event_subscriber'
      klass = ActiveSupport::StructuredEventSubscriber
      klass.prepend(EventOrigin) unless klass.ancestors.include?(EventOrigin)
    end

    def self.duplicate_event?(event)
      notification_name = EVENT_NOTIFICATIONS[event[:name]]
      notification = Thread.current[:otel_native_notification]
      if notification && notification.name == notification_name
        return Instrumentation.represented?(notification.name, notification.payload)
      end

      # View start events come from a start/finish subscriber, rather than call.
      event[:name] == 'action_view.render_start' &&
        event.dig(:source_location, :filepath).to_s.end_with?('/structured_event_subscriber.rb') &&
        Instrumentation.covered?(event.dig(:payload, :is_layout) ? 'render_layout.action_view' : 'render_template.action_view')
    end
  end
end
