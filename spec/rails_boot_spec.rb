# frozen_string_literal: true

require "spec_helper"
require "open3"
require "json"
require "rbconfig"

RSpec.describe "automatic Rails integration" do
  def run_probe(mode: "managed", rails_logs: "replace")
    source = <<~RUBY
      require "json"
      require "fileutils"
      require "stringio"
      require "tmpdir"
      require "rails"
      require "action_controller/railtie"
      require "rails_otel_logging"

      OUTPUT = StringIO.new
      LOGGER = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(OUTPUT))

      class RecordingExporter
        attr_reader :spans, :shutdowns

        def initialize
          @spans = []
          @shutdowns = 0
        end

        def export(spans, timeout: nil)
          @spans.concat(spans)
          OpenTelemetry::SDK::Trace::Export::SUCCESS
        end

        def shutdown(timeout: nil)
          @shutdowns += 1
        end

        def force_flush(timeout: nil)
          OpenTelemetry::SDK::Trace::Export::SUCCESS
        end
      end

      EXPORTER = RecordingExporter.new
      EXTERNAL_PROVIDER = OpenTelemetry::SDK::Trace::TracerProvider.new(
        resource: OpenTelemetry::SDK::Resources::Resource.create(
          "service.name" => "external-service", "service.version" => "external-version"
        )
      )
      EXTERNAL_PROVIDER.add_span_processor(
        OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER)
      )

      APP_ROOT = Dir.mktmpdir("rails-otel-logging-boot")
      FileUtils.mkdir_p(File.join(APP_ROOT, "config/initializers"))
      File.write(File.join(APP_ROOT, "config/initializers/rails_otel_logging.rb"), <<~CONFIG)
        OtelLogging.configure do |config|
          config.output_mode = :delayed
          config.colorize = false
          config.service_name = "probe-service"
          config.service_version = "2026.09"
          #{case mode
            when "external" then "config.tracer_provider = -> { EXTERNAL_PROVIDER }"
            when "direct" then "config.tracer_provider = EXTERNAL_PROVIDER"
            else ""
          end}
        end
      CONFIG

      class ProbeApplication < Rails::Application
        config.root = APP_ROOT
        config.eager_load = false
        config.secret_key_base = "test" * 32
        config.hosts.clear
        config.logger = LOGGER
        config.action_dispatch.show_exceptions = :none
        FileUtils.mkdir_p(File.join(config.root, "app/views/probe"))
        File.write(File.join(config.root, "app/views/probe/index.html.erb"), "<p>base view</p>")

      end

      class ProbeController < ActionController::Base
        def index
          LOGGER.info("outside.request")
          ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM widgets", name: "Widget Load") {}
          render :index
        end
      end

      class ProbeApiController < ActionController::API
        def index
          LOGGER.info("outside.api_request")
          render plain: "api"
        end
      end

      app = nil
      base = nil
      api = nil
      provider = nil
      provider_shutdowns = 0
      provider_force_flushes = 0
      request_finishes = 0
      spans = []
      at_exit do
        puts JSON.generate(
          base: base.status, api: api.status,
          provider_class: provider.class.name,
          resource: provider.resource.send(:attributes),
          global_provider_same: OpenTelemetry.tracer_provider.equal?(provider),
          spans: spans,
          logs: OUTPUT.string,
          external_shutdowns: EXPORTER.shutdowns,
          provider_shutdowns: provider_shutdowns,
          provider_force_flushes: provider_force_flushes,
          request_finishes: request_finishes,
          trace_active: OtelLogging::TraceContext.current.active?,
          tags: LOGGER.formatter.current_tags,
          middleware_count: app.middleware.count { |entry| entry.klass == OtelLogging::Middleware::Trace }
        )
      end

      app = ProbeApplication.initialize!
      app.routes.draw do
        get "/probe", to: "probe#index"
        get "/api/probe", to: "probe_api#index"
      end

      ActiveSupport::Notifications.subscribe("request.action_dispatch") { request_finishes += 1 }
      require "active_record/railtie"
      ActiveRecord::Base
      LOGGER.info("outside.before_request")
      base = Rack::MockRequest.new(app).get("/probe", "HTTP_HOST" => "localhost")
      api = Rack::MockRequest.new(app).get("/api/probe", "HTTP_HOST" => "localhost")
      OtelLogging.logger.with_trace("outside.sql") do
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM outside_widgets", name: "Outside Load") {}
      end
      provider = OtelLogging.tracer_provider
      original_shutdown = provider.method(:shutdown)
      original_force_flush = provider.method(:force_flush)
      provider.define_singleton_method(:force_flush) do |timeout: nil|
        provider_force_flushes += 1
        original_force_flush.call(timeout: timeout)
      end
      provider.define_singleton_method(:shutdown) do |timeout: nil|
        provider_shutdowns += 1
        original_shutdown.call(timeout: timeout)
      end
      LOGGER.info("outside.after_request")
      spans = EXPORTER.spans.map { |span| { name: span.name, attributes: span.attributes } }

    RUBY

    env = { "RAILS_ENV" => "test", "OTEL_RAILS_LOGS" => rails_logs, "OTEL_COLORIZE" => "false" }
    output, error, status = Open3.capture3(env, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", source)
    expect(status.success?).to be(true), "#{output}\n#{error}"
    JSON.parse(output.lines.last)
  end

  it "boots from require alone with a managed provider and instruments Base and API controllers" do
    result = run_probe

    expect(result).to include("base" => 200, "api" => 200, "global_provider_same" => false,
                              "provider_shutdowns" => 1, "trace_active" => false,
                              "tags" => [], "middleware_count" => 1, "provider_force_flushes" => 1,
                              "request_finishes" => 2)
    expect(result["resource"]).to include("service.name" => "probe-service", "service.version" => "2026.09")
    expect(result["logs"]).to include("GET probe#index", "GET probe_api#index", "render probe/index.html.erb",
                                       "outside.before_request", "outside.request", "outside.api_request",
                                       "outside.after_request")
    expect(result["logs"]).not_to include("Started GET", "Processing by", "Completed 200")
    expect(result["logs"].scan("db.select.outside_widgets").length).to eq(1)
    expect(result["logs"].scan("db.select.widgets").length).to eq(1)
  end

  it "uses an explicit provider returned by a lambda without taking ownership" do
    result = run_probe(mode: "external")

    expect(result).to include("global_provider_same" => false, "external_shutdowns" => 0,
                              "provider_shutdowns" => 0, "provider_force_flushes" => 0,
                              "request_finishes" => 2, "trace_active" => false, "tags" => [])
    expect(result["resource"]).to include("service.name" => "external-service", "service.version" => "external-version")
    expect(result["spans"].map { |span| span["name"] }).to include(
      "GET probe#index", "GET probe_api#index", "probe#index", "probe_api#index", "render probe/index.html.erb"
    )
  end

  it "accepts an already-created explicit provider" do
    result = run_probe(mode: "direct")

    expect(result).to include("global_provider_same" => false, "external_shutdowns" => 0,
                              "provider_shutdowns" => 0, "provider_force_flushes" => 0)
    expect(result["resource"]).to include("service.name" => "external-service", "service.version" => "external-version")
  end

  it "preserves Rails request logs when rails_logs is preserve" do
    result = run_probe(rails_logs: "preserve")

    expect(result["logs"]).to include("Started GET", "Processing by", "Completed 200")
    expect(result["logs"]).to include("outside.before_request", "outside.request", "outside.api_request", "outside.after_request")
  end
end
