# frozen_string_literal: true

require "rails/generators"

module RailsOtelLogging
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)
      desc 'Create the Rails OpenTelemetry logging initializer.'

      def create_initializer
        template 'initializer.rb', 'config/initializers/rails_otel_logging.rb'
      end
    end
  end
end
