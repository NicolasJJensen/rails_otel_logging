# frozen_string_literal: true

require 'active_support/notifications'

module OtelLogging
  class Instrumentation
    class Evaluation
      attr_reader :span_name, :span_attributes

      def initialize(notification_name, payload, &block)
        @span_name = notification_name
        @span_attributes = payload
        instance_exec(notification_name, payload, &block) if block
        raise ArgumentError, 'span name must be a nonempty String' unless @span_name.is_a?(String) && !@span_name.empty?
        raise ArgumentError, 'span attributes must be a Hash' unless @span_attributes.is_a?(Hash)
      end

      def name(value)
        @span_name = value
      end

      def attributes(value)
        @span_attributes = value
      end
    end

    Rule = Struct.new(:matcher, :transform, keyword_init: true) do
      def matches?(notification_name, payload)
        case matcher
        when String then matcher == notification_name
        when Regexp then matcher.match?(notification_name)
        else matcher.call(notification_name, payload)
        end
      end

      def evaluate(notification_name, payload)
        Evaluation.new(notification_name, payload, &transform)
      end
    end

    attr_reader :rules

    def initialize
      @rules = []
      @framework = false
    end

    def subscribe(matcher, &block)
      unless matcher.is_a?(String) || matcher.is_a?(Regexp) || matcher.respond_to?(:call)
        raise ArgumentError, 'notification matcher must be a String, Regexp, or callable'
      end
      raise ArgumentError, 'instrumentation is already installed; configure it before installation' if @rules.frozen?

      @rules << Rule.new(matcher: matcher, transform: block).freeze
      self
    end

    def enable_framework!
      @framework = true
    end

    def select(notification_name, payload)
      @rules.find { |rule| rule.matches?(notification_name, payload) } ||
        (@framework && FrameworkInstrumentation.rule_for(notification_name, payload))
    end

    def install!
      return if @subscriber

      @rules.freeze
      @subscriber = Subscriber.new(self)
      # Rails' subscription matcher receives only a name. Dispatch ourselves so
      # callable rules can inspect each invocation's payload, never a cached one.
      @subscription = ActiveSupport::Notifications.subscribe(nil, @subscriber)
    end

    def start_view(notification_name, id, payload, source:)
      @subscriber&.start(notification_name, id, payload, source: source)
    end

    def uninstall!
      ActiveSupport::Notifications.unsubscribe(@subscription) if @subscription
      @subscription = @subscriber = nil
    end

    def self.frames
      Thread.current[:otel_notification_frames] ||= []
    end

    def self.covered?(notification_name)
      frames.reverse_each.any? { |frame| frame[:name] == notification_name && frame[:handle]&.span&.recording? }
    end

    def self.outcomes
      Thread.current[:otel_notification_outcomes] ||= {}
    end

    def self.represented?(notification_name, payload)
      outcomes[notification_name]&.[](payload) || false
    end

    class Subscriber
      def initialize(registry)
        @registry = registry
      end

      def start(notification_name, id, payload, source: :regular)
        previous = Instrumentation.frames.last
        if previous && previous[:name] == notification_name && previous[:id] == id &&
            previous[:payload].equal?(payload) && !previous[:sources].include?(source)
          previous[:sources] << source
          return
        end

        frame = { name: notification_name, payload: payload, id: id, sources: [source] }
        Instrumentation.frames << frame
        if defined?(FrameworkInstrumentation) && FrameworkInstrumentation::EVENT_NOTIFICATIONS.value?(notification_name)
          outcomes = Instrumentation.outcomes[notification_name] ||= ObjectSpace::WeakMap.new
          outcomes[payload] = false
        end
        return if OtelLogging.diagnosing? || Thread.current[:otel_writing_output]

        rule = @registry.select(notification_name, payload)
        return unless rule

        evaluation = rule.evaluate(notification_name, payload)
        frame[:rule] = rule
        frame[:handle] = TraceContext.current.start_span(
          evaluation.span_name, attributes: evaluation.span_attributes
        )
        outcomes[payload] = frame[:handle].span.recording? if outcomes
      rescue StandardError => error
        OtelLogging.diagnostic(error)
      end

      def finish(notification_name, id, payload)
        frames = Instrumentation.frames
        index = frames.rindex { |frame| frame[:name] == notification_name && frame[:id] == id && frame[:payload].equal?(payload) }
        return unless index

        frame = frames[index]
        handle = frame[:handle]
        return unless handle

        begin
          evaluation = frame[:rule].evaluate(notification_name, payload)
          handle.span.name = evaluation.span_name
          attributes = Attributes.normalize(evaluation.span_attributes)
          handle.span.add_attributes(attributes)
          if notification_name == 'process_action.action_controller' && payload[:status].to_i >= 500
            handle.span.status = OpenTelemetry::Trace::Status.error("HTTP #{payload[:status]}")
          end
        rescue StandardError => error
          OtelLogging.diagnostic(error)
        ensure
          error = payload[:exception_object]
          if !error && payload[:exception].is_a?(Array)
            handle.span.add_event('exception', attributes: {
              'exception.type' => payload[:exception][0].to_s,
              'exception.message' => payload[:exception][1].to_s
            })
            handle.span.status = OpenTelemetry::Trace::Status.error(payload[:exception][1].to_s)
          end
          handle.finish(error: error)
        end
      ensure
        if frames && index
          frames.delete_at(index)
        end
      end
    end
  end
end
