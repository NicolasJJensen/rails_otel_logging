# frozen_string_literal: true

module OtelLogging
  module Middleware
    # Rack middleware that wraps each HTTP request in a trace.
    # This should be inserted at the top of the middleware stack.
    class Trace
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        trace_name = build_trace_name(env)
        attributes = build_attributes(env, request)

        OtelLogging.with_span(trace_name, attributes: attributes, kind: :server,
          context: { 'traceparent' => env['HTTP_TRACEPARENT'], 'tracestate' => env['HTTP_TRACESTATE'] }.compact) do |span|
          # Store trace info in env for access by controllers
          env['otel.trace_id'] = span.context.hex_trace_id
          env['otel.span_id'] = span.context.hex_span_id

          status, headers, response = @app.call(env)

          # Add response attributes
          span.set_attribute('http.status_code', status)
          update_span_name(span, env)

          # Mark as error if 5xx
          if status >= 500
            span.status = OpenTelemetry::Trace::Status.error("HTTP #{status}")
          end

          [status, headers, response]
        end
      end

      private

      def build_trace_name(env)
        method = env['REQUEST_METHOD']
        path = env['PATH_INFO'] || '/'
        "#{method} #{path}"
      end

      def build_attributes(env, request)
        attrs = {
          'http.method' => env['REQUEST_METHOD'],
          'http.scheme' => request.scheme,
          'http.host' => request.host_with_port,
          'http.target' => env['REQUEST_URI'] || env['PATH_INFO'],
        }

        attrs['http.user_agent'] = env['HTTP_USER_AGENT'] if env['HTTP_USER_AGENT']
        attrs['http.client_ip'] = request.ip if request.ip
        attrs
      end

      def update_span_name(span, env)
        # Update span name with controller/action if available
        if env['action_controller.instance']
          controller = env['action_controller.instance']
          controller_name = controller.class.name.sub(/Controller$/, '').underscore
          action_name = controller.action_name
          method = env['REQUEST_METHOD']
          span.name = "#{method} #{controller_name}##{action_name}"
        end
      end
    end
  end
end
