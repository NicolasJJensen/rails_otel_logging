# frozen_string_literal: true

require "otel_logging/rails"

module OtelLogging
  class Railtie < Rails::Railtie
    initializer "rails_otel_logging.install", after: :load_config_initializers, before: :build_middleware_stack do |application|
      RailsIntegration.install!(application: application)
    end
  end
end
