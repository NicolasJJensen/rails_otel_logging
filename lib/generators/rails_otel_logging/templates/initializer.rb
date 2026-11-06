# frozen_string_literal: true

OtelLogging.configure do |config|
  config.output_mode = :live_delayed_on_error
  config.rails_logs = :replace

  config.instrumentation do
    # Capture every notification using its name and filtered payload.
    # First match wins: put specific rules before this fallback.
    # This overrides built-in mappings for matching notifications.
    # subscribe /.*/
  end

  # Use :preserve to keep Rails logs alongside trace output.
  # config.rails_logs = :preserve

  # These resource attributes apply to the gem-managed provider.
  # config.service_name = 'my_app'
  # config.service_version = '1.0.0'

  # An application-owned provider keeps its existing processors and lifecycle.
  # The block runs after application initializers, when telemetry is configured.
  # config.tracer_provider = -> { OpenTelemetry.tracer_provider }
end
