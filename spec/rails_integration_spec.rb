# frozen_string_literal: true

require "rails"
require "action_controller/railtie"
require "rack/mock"
require "rails_otel_logging/rails"
require_relative "spec_helper"

# A process can initialize only one Rails::Application, because Rails freezes
# global initializer state on the first boot. Every example here shares that one
# application and varies OtelLogging configuration instead of booting again.
module RailsIntegrationApplication
  OUTPUT = StringIO.new
  LOGGER = ActiveSupport::Logger.new(OUTPUT)

  class << self
    def boot(tracer_provider:)
      @application ||= build_and_boot(tracer_provider)
      install(@application, tracer_provider)
      @application
    end

    private

    def build_and_boot(tracer_provider)
      application = Class.new(Rails::Application) do
        config.eager_load = false
        config.secret_key_base = "x" * 64
        config.logger = LOGGER
        config.hosts.clear
      end
      Object.const_set(:OtelIntegrationController, Class.new(ActionController::Base) do
        def ok = render(plain: "ok")
      end)
      application.routes.draw { get "/", to: "otel_integration#ok" }
      install(application, tracer_provider)
      application.initialize!
      application
    end

    def install(application, tracer_provider)
      OtelLogging::RailsIntegration.install!(
        application: application, logger: LOGGER, tracer_provider: tracer_provider
      )
    end
  end
end

RSpec.describe OtelLogging::RailsIntegration do
  def otel_output = RailsIntegrationApplication::OUTPUT

  def otel_logger = RailsIntegrationApplication::LOGGER

  def application = RailsIntegrationApplication.boot(tracer_provider: otel_provider)

  before do
    otel_output.truncate(0)
    otel_output.rewind
  end

  it "traces a request and always clears trace context" do
    response = Rack::MockRequest.new(application).get("/")

    expect(response.status).to be_between(200, 599)
    expect(OtelLogging::TraceContext.current.active?).to be(false)
    expect(OpenTelemetry::Trace.current_span).to be_a(OpenTelemetry::Trace::Span)
  end

  it "installs middleware and notifications only once" do
    booted = application
    after_first = ActiveSupport::Notifications.notifier.listeners_for("start_processing.action_controller").length
    OtelLogging::RailsIntegration.install!(application: booted, logger: otel_logger, tracer_provider: otel_provider)
    after_second = ActiveSupport::Notifications.notifier.listeners_for("start_processing.action_controller").length

    expect(after_second).to eq(after_first)
    expect(booted.instance.middleware.to_a.count { |entry| entry.klass == OtelLogging::Middleware::Trace }).to eq(1)
  end

  it "suppresses Rails default request logging by default" do
    expect(OtelLogging.config.silence_default_logs).to be(true)

    Rack::MockRequest.new(application).get("/")

    expect(otel_output.string).not_to include("Started GET")
    expect(otel_output.string).not_to include("Processing by")
  end

  it "does not silence Rails default logging when suppression is disabled" do
    booted = application
    OtelLogging.config.silence_default_logs = false
    expect(OtelLogging::Silencers).not_to receive(:silence_defaults!)
    OtelLogging::RailsIntegration.install!(application: booted, logger: otel_logger, tracer_provider: otel_provider)

    Rack::MockRequest.new(booted).get("/")

    expect(otel_output.string).to include("trace ")
    expect(OtelLogging.config.silence_default_logs).to be(false)
  end
end
