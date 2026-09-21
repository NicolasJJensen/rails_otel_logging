# frozen_string_literal: true

require "stringio"
require "rails_otel_logging"
require "otel_logging/subscribers/active_record"

RSpec.configure do |config|
  config.expect_with(:rspec) { |expectations| expectations.include_chain_clauses_in_custom_matcher_descriptions = true }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.order = :random
  Kernel.srand config.seed

  config.include Module.new {
    def otel_output
      @otel_output ||= StringIO.new
    end

    def otel_logger
      @otel_logger ||= ActiveSupport::Logger.new(otel_output)
    end

    def otel_provider
      @otel_provider ||= OpenTelemetry::SDK::Trace::TracerProvider.new
    end
  }

  config.around do |example|
    saved = OtelLogging.instance_variables.to_h { |key| [key, OtelLogging.instance_variable_get(key)] }
    OtelLogging.instance_variables.each { |key| OtelLogging.remove_instance_variable(key) }
    OtelLogging::TraceContext.reset!
    OtelLogging.configure do |settings|
      settings.colorize = false
      settings.output_mode = :delayed
    end
    OtelLogging.install!(logger: otel_logger, tracer_provider: otel_provider) unless example.metadata[:uninstalled]
    example.run
  ensure
    @otel_provider&.shutdown
    OtelLogging::TraceContext.reset!
    OtelLogging.instance_variables.each { |key| OtelLogging.remove_instance_variable(key) }
    saved.each { |key, value| OtelLogging.instance_variable_set(key, value) }
  end
end
