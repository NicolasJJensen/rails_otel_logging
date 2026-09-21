# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'
require 'rbconfig'

RSpec.describe 'Rails application boot' do
  def run_application(suppression)
    source = <<~'APP'
      require 'tmpdir'
      require 'json'
      require 'stringio'
      require 'rails'
      require 'action_controller/railtie'
      require 'rails_otel_logging/rails'

      OUTPUT = StringIO.new
      LOGGER = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(OUTPUT))
      PROVIDER = OpenTelemetry::SDK::Trace::TracerProvider.new
      class ProbeApplication < Rails::Application
        config.root = Dir.mktmpdir('rails-otel-logging-rails')
        config.eager_load = false
        config.secret_key_base = 'test' * 32
        config.hosts.clear
        config.logger = LOGGER
        config.log_tags = [:request_id]
        config.action_dispatch.show_exceptions = :none
        initializer 'probe.otel' do |app|
          OtelLogging.configure do |settings|
            settings.output_mode = :delayed
            settings.colorize = false
          end
          2.times do
            OtelLogging::RailsIntegration.install!(application: app, logger: LOGGER, tracer_provider: PROVIDER)
          end
        end
      end
      class ProbeController < ActionController::Base
        include OtelLogging::ControllerHelpers
        def index
          LOGGER.info('application.message')
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT * FROM widgets', name: 'Widget Load') {}
          render plain: 'ok'
        end
      end
      app = ProbeApplication.initialize!
      app.routes.draw { get '/probe', to: 'probe#index' }
      finishes = 0
      ActiveSupport::Notifications.subscribe('request.action_dispatch') { finishes += 1 }
      response = app.call(Rack::MockRequest.env_for('/probe', 'HTTP_HOST' => 'localhost'))
      body = +''
      response[2].each { |chunk| body << chunk }
      response[2].close if response[2].respond_to?(:close)
      puts JSON.generate(status: response[0], body: body, logs: OUTPUT.string,
        middleware_count: app.middleware.count { |entry| entry.klass == OtelLogging::Middleware::Trace },
        request_finishes: finishes, tags: LOGGER.formatter.current_tags,
        trace_active: OtelLogging::TraceContext.current.active?)
      PROVIDER.shutdown
    APP
    output, error, status = Open3.capture3(
      { 'RAILS_ENV' => 'test', 'OTEL_SILENCE_DEFAULTS' => suppression.to_s, 'OTEL_COLORIZE' => 'false' },
      RbConfig.ruby, '-I', File.expand_path('../lib', __dir__), '-e', source
    )
    expect(status.success?).to be(true), "#{output}\n#{error}"
    JSON.parse(output.lines.last)
  end

  it 'suppresses Rails defaults while preserving nicer traces, app logs, tags and request cleanup' do
    result = run_application(true)
    expect(result).to include('status' => 200, 'body' => 'ok', 'middleware_count' => 1,
                              'request_finishes' => 1, 'tags' => [], 'trace_active' => false)
    expect(result['logs']).to include('GET probe#index', 'application.message', 'db.select.widgets')
    expect(result['logs']).not_to include('Started GET', 'Processing by ProbeController', 'Completed 200')
    expect(result['logs'].scan('db.select.widgets').length).to eq(1)
  end

  it 'retains Rails default logs when suppression is disabled' do
    result = run_application(false)
    expect(result).to include('status' => 200, 'body' => 'ok', 'middleware_count' => 1,
                              'request_finishes' => 1, 'tags' => [], 'trace_active' => false)
    expect(result['logs']).to include('Started GET', 'Processing by ProbeController', 'Completed 200', 'application.message')
  end
end
