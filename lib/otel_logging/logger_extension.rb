# frozen_string_literal: true

module OtelLogging
  module LoggerExtension
    [:debug, :info, :warn, :error, :fatal, :unknown].each do |name|
      define_method(name) do |progname = nil, &block|
        add(::Logger::Severity.const_get(name.to_s.upcase), nil, progname, &block)
      end
    end

    def add(severity, message = nil, progname = nil, &block)
      severity = Output.severity(severity)
      output = Output.for(self)
      return output.add(severity, message, progname, &block) unless OpenTelemetry::Trace.current_span.recording?
      return true unless output.enabled?(severity)

      if message.nil?
        if block
          message = block.call
        else
          message = progname || self.progname
          progname = nil
        end
      end
      return true if message.equal?(Output::SUPPRESSED)

      Capture.message(message, severity: severity, logger: self, progname: progname)
    end
    alias_method :log, :add
  end

  module BroadcastTags
    def tagged(*tags, &block)
      return super if defined?(ActiveSupport::TaggedLogging) && singleton_class.ancestors.include?(ActiveSupport::TaggedLogging)

      if block
        Output.for(self).tagged(*tags) { block.call(self) }
      else
        copy = clone
        copy.broadcasts.replace(broadcasts.map do |sink|
          sink.respond_to?(:tagged) ? sink.tagged(*tags) : sink.clone
        end)
        copy
      end
    end
  end
end
