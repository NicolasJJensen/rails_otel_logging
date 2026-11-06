# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "tmpdir"

RSpec.describe "rails_otel_logging:install generator" do
  it "creates an initializer for automatic Rails setup" do
    Dir.mktmpdir("rails-otel-logging-generator") do |destination|
      Rails::Generators.invoke(
        "rails_otel_logging:install",
        [],
        destination_root: destination,
        behavior: :invoke
      )

      initializer = File.read(File.join(destination, "config/initializers/rails_otel_logging.rb"))
      expect(initializer).to include("OtelLogging.configure")
      expect(initializer).to include("config.output_mode = :live_delayed_on_error")
      expect(initializer).to include("config.rails_logs = :replace")
      expect(initializer).to include("config.tracer_provider")
      expect(initializer).to include("config.instrumentation do", "# subscribe /.*/")
      expect(initializer).not_to match(/^\s*subscribe /)
    end
  end
end
