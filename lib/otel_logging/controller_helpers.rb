# frozen_string_literal: true

require "active_support/concern"

module OtelLogging
  module ControllerHelpers
    extend ActiveSupport::Concern

    included do
      around_action :otel_trace_action
    end

    private

    def otel_trace_action
      logger = OtelLogging.logger
      logger.with_span("#{controller_name}##{action_name}", attributes: {
        "rails.controller" => controller_name,
        "rails.action" => action_name,
        "rails.format" => request.format.to_s
      }) do |span|
        yield
        span.set_attribute("http.status_code", response.status) if span && response
      end
    end

    def set_trace_attribute(key, value)
      span = OpenTelemetry::Trace.current_span
      span.set_attribute(key, value) if span
    end

    def trace_event(name, **attributes)
      OtelLogging.logger.event(name, **attributes)
    end
  end
end
