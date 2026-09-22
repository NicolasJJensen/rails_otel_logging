# frozen_string_literal: true

require_relative "lib/otel_logging/version"

Gem::Specification.new do |spec|
  spec.name = "rails_otel_logging"
  spec.version = OtelLogging::VERSION
  spec.authors = ["Nicolas J Jensen"]
  spec.email = ["nicolasjensen9@gmail.com"]
  spec.summary = "Readable OpenTelemetry trace logs with Rails integration"
  spec.description = "Prints OpenTelemetry spans as an indented tree with timings, events, and errors, " \
                     "either live or as one block when the root span closes. Adds with_trace, with_span, " \
                     "and event to a logger. Automatic Rails integration instruments " \
                     "requests, controllers, views, Active Record, and Action Cable, and can silence the " \
                     "matching Rails default logs during traces. Rails gets a managed provider by default; " \
                     "applications retain ownership of explicitly supplied providers."
  spec.homepage = "https://github.com/NicolasJJensen/rails_otel_logging"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues"
  }
  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
      .select { |path| File.file?(path) }
  end
  spec.require_paths = ["lib"]
  spec.add_dependency "opentelemetry-sdk", ">= 1.0", "< 2.0"
  spec.add_dependency "activesupport", ">= 7.0", "< 9.0"
  spec.add_dependency "logger", ">= 1.6", "< 2"
end
