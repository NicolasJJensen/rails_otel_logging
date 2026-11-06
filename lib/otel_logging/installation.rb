# frozen_string_literal: true

module OtelLogging
  class Installation
    class << self
      def install!(logger:, tracer_provider:)
        raise ArgumentError, 'logger is required' if logger.nil?
        raise ArgumentError, 'tracer_provider is required' if tracer_provider.nil?

        OtelLogging.send(:installation_mutex).synchronize do
          current = OtelLogging.send(:installation)
          if current
            return true if current[:logger].equal?(logger) && current[:tracer_provider].equal?(tracer_provider)

            raise ArgumentError, 'OtelLogging is already installed with a different logger or tracer provider'
          end

          Output.for(logger)
          logger.extend(LoggerExtension) unless logger.singleton_class.ancestors.include?(LoggerExtension)
          logger.extend(BroadcastTags) if logger.respond_to?(:broadcasts)
          processors = build_processors(logger)
          processors.each { |processor| tracer_provider.add_span_processor(processor) }
          OtelLogging.send(:set_installation, logger: logger, tracer_provider: tracer_provider, processors: processors)
          OtelLogging.config.instrumentation.install!
          if OtelLogging.config.capture_rails_events
            subscriber = EventSubscriber.new
            ActiveSupport.event_reporter.subscribe(subscriber)
            OtelLogging.instance_variable_set(:@event_subscriber, subscriber)
          end
          true
        end
      end

      private

      def build_processors(logger)
        processors = []
        if OtelLogging.config.live?
          OtelLogging.live_exporter = Exporters::Live.new(logger)
          processors << OtelLogging.live_exporter
        end
        processors << Exporters::Buffered.new(logger) if OtelLogging.config.delayed?
        processors << Exporters::Buffered.new(logger, only_on_error: true) if OtelLogging.config.delayed_on_error?
        processors
      end
    end
  end

  class << self
    attr_reader :logger, :tracer_provider

    def install!(logger:, tracer_provider:)
      Installation.install!(logger: logger, tracer_provider: tracer_provider)
    end

    private

    def installation_mutex
      @installation_mutex ||= Mutex.new
    end

    def installation
      @installation
    end

    def set_installation(logger:, tracer_provider:, processors:)
      @logger = logger
      @tracer_provider = tracer_provider
      @installation = { logger: logger, tracer_provider: tracer_provider, processors: processors }.freeze
    end
  end
end
