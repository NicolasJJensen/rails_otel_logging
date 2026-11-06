# frozen_string_literal: true

module OtelLogging
  module Capture
    def self.message(message, severity: Logger::INFO, logger: OtelLogging.logger, attributes: {}, progname: nil, timestamp: nil)
      output = Output.for(logger)
      return true unless output.enabled?(severity)

      name = case message
      when String then message.dup
      when Exception then "#{message.message} (#{message.class})\n#{Array(message.backtrace).join("\n")}"
      else message.inspect
      end
      attributes = Attributes.normalize(attributes)
      tags = output.tags
      span = OpenTelemetry::Trace.current_span
      unless span.recording?
        details = attributes.empty? ? name : "#{name} #{attributes.inspect}"
        return output.write(details, severity: severity, tags: tags, progname: progname)
      end

      metadata = attributes.merge('log.severity' => severity, 'log.tags' => tags)
      metadata['log.progname'] = progname.to_s.dup if progname
      options = { attributes: metadata }
      options[:timestamp] = timestamp if timestamp
      span.add_event(name, **options)
      OtelLogging.notify_event(name, metadata, TraceContext.current)
      true
    end
  end
end
