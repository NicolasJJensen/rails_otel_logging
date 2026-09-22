# rails_otel_logging

Readable OpenTelemetry trace logs for Ruby, with automatic Rails integration.
Provides nested trace trees, timings, events, errors, and tracing methods on an injected logger.

## Rails quickstart

```ruby
# Gemfile
gem 'rails_otel_logging'
```

Run `bundle install` and boot the application. When Rails defines `Rails::Railtie`,
loading `rails_otel_logging` loads the Railtie automatically. The integration adds
the trace middleware, logger methods, controller helpers, and available Rails
notification subscribers. Subscribers are loaded lazily when their Rails component
is present.

If you require the core before loading Rails itself, require
`rails_otel_logging/rails` after Rails has loaded to register the Railtie.

To create an editable initializer, run:

```sh
bin/rails generate rails_otel_logging:install
```

The generated initializer is optional. Use it to set application-specific options:

```ruby
OtelLogging.configure do |config|
  config.output_mode = :live_delayed_on_error
  config.rails_logs = :replace
  config.service_name = 'orders'
  config.service_version = '1.0.0'
end
```

Rails uses a private OpenTelemetry SDK provider by default. The gem manages that
provider's lifecycle and builds its resource from `service_name` and
`service_version`; it does not replace a global provider. `:replace` suppresses
Rails' duplicate log subscribers only while a gem trace is active. Logs emitted
outside a gem trace remain available. Set `config.rails_logs = :preserve` to keep
the Rails subscribers active.

The Rails integration automatically includes `OtelLogging::ControllerHelpers` in
both `ActionController::Base` and `ActionController::API` applications. Action
controllers can use its `trace_event` and `set_trace_attribute` helpers directly.

```ruby
class OrdersController < ApplicationController
  before_action do
    set_trace_attribute('orders.source', 'web')
    trace_event('orders.authorized')
  end
end
```

Requires Ruby 3.1+, ActiveSupport 7.0 through 8.x, and OpenTelemetry SDK 1.x.
Rails integration is tested with Rails 7.0, 7.1, 7.2, 8.0, and 8.1. The host supplies
Rails components.

## Advanced Rails configuration

`config.tracer_provider` can be an explicit provider instance or a lambda. A lambda
is resolved after application initializers, so an application can supply an
explicitly configured OpenTelemetry SDK provider after configuring exporters and
processors:

```ruby
OtelLogging.configure do |config|
  config.tracer_provider = -> { configured_sdk_provider }
  config.rails_logs = :preserve
end
```

The lambda must return the application's configured SDK tracer provider with its
exporters and processors. Do not resolve the default OpenTelemetry API no-op
provider.

When an external provider is supplied, the application owns its lifecycle, including
shutdown. The gem adds its logging processors without replacing the global provider.
The automatic middleware and lazy subscriber hooks remain enabled.
Configure these options in an initializer; restart the application after changing
the provider, instrumentation switches, or output mode.

`rails_logs` defaults to `:replace`. Set it to `:preserve` when Rails' original
request, view, or SQL subscribers should continue to emit their logs during traces.
ActionCable's application-owned connection logger remains unchanged in both modes.
The environment variable `OTEL_RAILS_LOGS` accepts `replace` or `preserve` and is
overridden by `OtelLogging.configure`.

Available switches include `enable_active_record`, `enable_action_controller`,
`enable_action_cable`, `enable_templates`, `enable_layouts`, `enable_partials`,
`partial_max_depth`, `view_allowlist`, `view_denylist`, and
`include_params_in_views`.

## Standalone Ruby setup

The core gem does not load Rails. Use explicit installation when integrating with a
Ruby process without Rails:

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

The application owns flushing and shutting down an explicitly supplied provider.
Repeated installation with the same logger and provider is a no-op. A conflicting
logger or provider raises `ArgumentError`.

## Output modes

- `:live`: spans and events appear as work runs; failed spans and recorded
  exceptions also print their details when the span finishes.
- `:delayed`: a complete tree, including durations, prints when the root finishes.
- `:both`: live output plus a completed tree.
- `:live_delayed_on_error`: live output, with a completed tree when any span has
  an error status or a recorded exception (default).

Errors remain visible even when the request recovers. A failed child gets an
`ERROR` badge without changing its parent's status. Recorded exceptions do not
automatically mark a span as failed: live completion output uses `EXCEPTION`
when the span contains an exception but has no error status, and completed trees
show the exception event beneath that span. No recovery status is inferred;
use an event such as `prices.fallback_to_cache` to explain how work continued.

Exceptions that escape a `with_span` or `with_trace` block are recorded
automatically. If you rescue inside the block, explicitly record the exception
so it remains visible:

```ruby
logger.with_trace('refresh_prices') do
  logger.with_span('fetch_prices') do |span|
    begin
      fetch_live_prices
    rescue PricingUnavailable => error
      span.record_exception(error)
      logger.event('prices.fallback_to_cache')
      load_cached_prices
    end
  end
end
```

These output rules apply to recorded spans; exceptions swallowed without being
recorded cannot be displayed. In live modes error details appear at span finish;
completed trees appear at root finish and include durations and individual outcomes.

`config.theme` customizes colors and emphasis. `NO_COLOR` disables automatic color
selection; `OTEL_COLORIZE` explicitly overrides it.

## Environment variables

Each variable sets the default for one configuration switch when the process
starts. A later `OtelLogging.configure` block wins over the variable. Boolean
variables read `true`, `1`, `yes`, or `on` (any letter case) as true, and every
other value as false.

| Variable | Config switch | Default |
| --- | --- | --- |
| `OTEL_RAILS_LOGS` | `rails_logs` (`replace` or `preserve`) | `replace` |
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
