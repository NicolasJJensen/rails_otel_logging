# rails_otel_logging

Readable OpenTelemetry trace logs for Ruby, with an optional Rails integration.
Provides nested trace trees, timings, events, errors, and tracing methods on an injected logger.

## Install

```ruby
# Gemfile
gem 'rails_otel_logging'
```

Or run `bundle add rails_otel_logging`.

Requires Ruby 3.1+, ActiveSupport 7.0 through 8.x, and OpenTelemetry SDK 1.x.
Rails integration is tested with Rails 7.0, 7.1, 7.2, 8.0, and 8.1. The host supplies Rails components;
requiring the core gem does not load Rails, modify its logs, or configure the SDK.

## Explicit setup

```ruby
require 'rails_otel_logging'
require 'logger'

logger = Logger.new($stdout)
provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
  resource: OpenTelemetry::SDK::Resources::Resource.create(
    'service.name' => 'my_app', 'service.version' => '1.0.0'
  )
)

OtelLogging.configure do |config|
  config.output_mode = :delayed
  config.colorize = false
end
OtelLogging.install!(logger: logger, tracer_provider: provider)

logger.with_trace('orders.create') do
  logger.with_span('orders.validate') do
    logger.event('validation.complete', valid: true)
  end
end

# The application owns flushing and shutting down its provider.
provider.shutdown
```

`OtelLogging.configure` changes settings only. `OtelLogging.install!` attaches processors to the
provider supplied by the caller, preserving its existing processors. It does not
call `OpenTelemetry::SDK.configure`, replace the global provider, or shut down the
provider. An existing SDK provider can be passed directly.

Repeated installation with the same logger and provider is a no-op. A conflicting
logger or provider raises `ArgumentError`. Configure output mode before installing;
processor selection is fixed for that installation. Service resource attributes
belong to the caller's provider.

## Output modes

- `:live`: spans and events appear as work runs.
- `:delayed`: a complete tree, including durations, prints when the root finishes.
- `:both`: live output plus a completed tree.
- `:live_delayed_on_error`: live output, with a completed tree on errors (default).

`config.theme` customizes colors and emphasis. `NO_COLOR` disables automatic color
selection; `OTEL_COLORIZE` explicitly overrides it.

## Environment variables

Each variable sets the default for one configuration switch when the process
starts. A later `OtelLogging.configure` block wins over the variable. Boolean
variables read `true`, `1`, `yes`, or `on` (any letter case) as true, and every
other value as false.

| Variable | Config switch | Default |
| --- | --- | --- |
| `OTEL_SILENCE_DEFAULTS` | `silence_default_logs` | `true` |
| `OTEL_ACTIVE_RECORD` | `enable_active_record` | `true` |
| `OTEL_ACTION_CONTROLLER` | `enable_action_controller` | `true` |
| `OTEL_ACTION_CABLE` | `enable_action_cable` | `true` |
| `OTEL_VIEW_TEMPLATES` | `enable_templates` | `true` |
| `OTEL_VIEW_LAYOUTS` | `enable_layouts` | `true` |
| `OTEL_VIEW_PARTIALS` | `enable_partials` | `true` |
| `OTEL_VIEW_PARAMS` | `include_params_in_views` | `true` |
| `OTEL_VIEW_PARTIAL_DEPTH` | `partial_max_depth` | unset, meaning unlimited depth |
| `OTEL_COLORIZE` | `colorize` | unset, meaning colors stay off |

`colorize` is the one exception to the table's "unset means default" reading.
The gem turns colors on only when `OTEL_COLORIZE` is set to a true value, because
the core gem cannot tell whether the host's output supports ANSI colors. Setting
the standard `NO_COLOR` variable also keeps colors off.

## Rails

Load the adapter and install it from an application initializer, before the
middleware stack is built:

```ruby
require 'rails_otel_logging/rails'

OtelLogging.configure do |config|
  config.output_mode = :delayed
  config.colorize = Rails.env.development?
  # Enabled by default. Set false to retain Rails' default log output:
  # config.silence_default_logs = false
end

# Use the application's SDK provider configured by its own telemetry setup.
OtelLogging::RailsIntegration.install!(
  application: Rails.application,
  logger: Rails.logger,
  tracer_provider: application_tracer_provider
)
```

The adapter instruments requests, controllers, views, ActiveRecord, and
ActionCable when their components and configuration switches are enabled.
Installation is safe to repeat without duplicating middleware or subscriptions.
For controller action spans, include `OtelLogging::ControllerHelpers` in
`ApplicationController`. Application-specific span names and events stay in the
application.

**Default Rails log suppression is on.** Opt out before installation with
`config.silence_default_logs = false` or `OTEL_SILENCE_DEFAULTS=false`. This setting
controls the gem's suppression of Rails defaults; it does not mute the injected
application logger. Restart the application when changing boot-time integration
settings.

Available switches include `enable_active_record`, `enable_action_controller`,
`enable_action_cable`, `enable_templates`, `enable_layouts`, `enable_partials`,
`partial_max_depth`, `view_allowlist`, `view_denylist`, and `include_params_in_views`.
Do not disable the host's view logger separately if you want the suppression
opt-out to restore normal view logging.

## Logger API

- `with_trace(name, attributes: {}) { |span| ... }`: root trace with exception cleanup.
- `with_span(name, attributes: {}) { |span| ... }`: child span inside a trace; outside
  a trace it yields `nil` and still runs the block.
- `event(name, **attributes)`: event on the active span.
- `current_trace_id` / `current_span_id`: correlation identifiers or `nil`.

## Development

Clone the repository, then:

```sh
bundle install
bundle exec rake
gem build rails_otel_logging.gemspec
```

`bundle exec rake` runs the RSpec suite. It needs no host application, no
database, and no browser. The Rails adapter specs boot one Rails application per
process and exercise its middleware and request logging directly.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/NicolasJJensen/rails_otel_logging.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
