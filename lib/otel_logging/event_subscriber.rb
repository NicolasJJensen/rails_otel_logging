# frozen_string_literal: true

module OtelLogging
  class EventSubscriber
    def emit(event)
      return if OtelLogging.diagnosing? || Thread.current[:otel_writing_output]
      return if defined?(FrameworkInstrumentation) && FrameworkInstrumentation.duplicate_event?(event)

      payload = event[:payload] || {}
      payload = payload.serialize unless payload.is_a?(Hash)
      raise ArgumentError, 'event objects must serialize to a Hash' unless payload.is_a?(Hash)

      attributes = Attributes.normalize(payload)
      {
        'rails.event.tags' => (event[:tags] || {}).transform_values { |value| value.respond_to?(:serialize) ? value.serialize : value },
        'rails.event.context' => event[:context],
        'code' => event[:source_location]
      }.each do |prefix, metadata|
        Attributes.normalize(metadata || {}).each { |key, value| attributes["#{prefix}.#{key}"] = value }
      end
      Capture.message(event[:name], attributes: attributes, timestamp: event[:timestamp] / 1_000_000_000.0)
    rescue StandardError => error
      OtelLogging.diagnostic(error)
    end
  end

  class << self
    def diagnosing?
      Thread.current[:otel_diagnosing]
    end

    def diagnostic(error)
      return if diagnosing?

      begin
        Thread.current[:otel_diagnosing] = true
        Output.for(logger).write("rails_otel_logging: #{error.class}: #{error.message}", severity: Logger::ERROR) if logger
      rescue StandardError
        nil
      ensure
        Thread.current[:otel_diagnosing] = false
      end
    end
  end
end
