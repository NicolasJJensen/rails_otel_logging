# frozen_string_literal: true

module OtelLogging
  class TraceContext
    Handle = Struct.new(:span, :token, :owner, :finished, keyword_init: true) do
      def finish(error: nil)
        return if finished
        self.finished = true
        begin
          if error
            span.record_exception(error)
            span.status = OpenTelemetry::Trace::Status.error(error.message)
          end
          span.finish
        ensure
          OpenTelemetry::Context.detach(token)
          owner.handles.delete(self)
        end
        span
      end
    end

    attr_reader :handles

    def self.current
      Thread.current[:otel_trace_context] ||= new
    end

    def self.reset!
      Thread.current[:otel_trace_context] = nil
    end

    def self.tracer
      provider = OtelLogging.tracer_provider
      raise 'OtelLogging has not been installed' unless provider

      provider.tracer('rails_otel_logging', OtelLogging.config.service_version)
    end

    def initialize
      @handles = []
    end

    def start_span(name, attributes: {}, parent_context: OpenTelemetry::Context.current, kind: :internal)
      attributes = Attributes.normalize(attributes).merge('log.tags' => Output.for(OtelLogging.logger).tags)
      span = self.class.tracer.start_span(name, attributes: attributes, with_parent: parent_context, kind: kind)
      token = OpenTelemetry::Context.attach(OpenTelemetry::Trace.context_with_span(span, parent_context: parent_context))
      handle = Handle.new(span: span, token: token, owner: self, finished: false)
      @handles << handle
      handle
    end

    def current_span
      OpenTelemetry::Trace.current_span
    end

    def root_span
      @handles.first&.span
    end

    def active?
      current_span.recording?
    end

    def depth
      [@handles.size - 1, 0].max
    end
  end

  class << self
    UNSPECIFIED_CONTEXT = Object.new.freeze

    def with_trace(name = 'trace', context: UNSPECIFIED_CONTEXT, attributes: {}, &block)
      if context.equal?(UNSPECIFIED_CONTEXT)
        run_span(name, attributes: attributes, parent_context: OpenTelemetry::Context.empty, &block)
      else
        raise ArgumentError, 'context-only with_trace does not accept a name or attributes' unless name == 'trace' && attributes.empty?

        OpenTelemetry::Context.with_current(extract_context(context), &block)
      end
    end

    def with_span(name, context: UNSPECIFIED_CONTEXT, attributes: {}, kind: :internal, &block)
      parent = context.equal?(UNSPECIFIED_CONTEXT) ? OpenTelemetry::Context.current : extract_context(context)
      run_span(name, attributes: attributes, parent_context: parent, kind: kind, &block)
    end

    def trace_context
      carrier = {}
      OpenTelemetry::Trace::Propagation::TraceContext.text_map_propagator.inject(carrier)
      carrier
    end

    def current_trace_id
      context = OpenTelemetry::Trace.current_span.context
      context.hex_trace_id if context.valid?
    end

    def current_span_id
      context = OpenTelemetry::Trace.current_span.context
      context.hex_span_id if context.valid?
    end

    def set_span_attribute(key, value)
      span = OpenTelemetry::Trace.current_span
      span.add_attributes(Attributes.normalize(key => value)) if span.recording?
    end

    private

    def extract_context(carrier)
      raise ArgumentError, 'context must be a trace context Hash' unless carrier.is_a?(Hash)

      OpenTelemetry::Trace::Propagation::TraceContext.text_map_propagator.extract(
        carrier, context: OpenTelemetry::Context.empty
      )
    end

    def run_span(name, attributes:, parent_context:, kind: :internal)
      handle = TraceContext.current.start_span(name, attributes: attributes, parent_context: parent_context, kind: kind)
      error = nil
      begin
        yield handle.span
      rescue Exception => exception
        error = exception
        raise
      ensure
        handle.finish(error: error)
      end
    end
  end
end
