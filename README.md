# rails_otel_logging

Readable Rails logs built on OpenTelemetry. Group requests, database queries,
view rendering, and application messages into trace trees with timings and error
details. Existing `Rails.logger.info`, `warn`, and other standard logging calls
work automatically.

A shortened example of a completed tree in `:delayed` mode (logger prefixes and
request attributes omitted):

```text
trace 8c5a1d2e3f4b6079
◆ GET /orders/123 7b93a210 24.6ms
└ ◆ inventory.check 31d9a8c2 3.2ms
  ├ + INFO Checking inventory
  └ + INFO inventory.checked
      available: true
```

## Installation

Add the gem to your application's Gemfile:

```ruby
gem 'rails_otel_logging'
```

Then run:

```sh
bundle install
```

Restart your application. Rails integration is automatic: requests get traces,
available Rails components are instrumented, and application logs appear in the
active trace. No initializer is required.

By default, logs appear as work runs. If a trace contains a failure, a recorded
exception, or an error/fatal message, a completed tree is also printed when the
request finishes. Duplicate Rails request, view, and SQL subscriber output is
suppressed during traces.

## Usage

### Existing Rails logging

Continue using the standard logger methods:

```ruby
Rails.logger.info('Checking inventory')
Rails.logger.warn('Only one item remaining')
Rails.logger.debug { expensive_diagnostic }
```

Inside a request trace, messages become events on the current span. Outside a
trace, they use normal logger output. Logger levels still apply, and lazy blocks
are only evaluated when their level is enabled.

### Custom spans and structured events

Requests already have a trace. Add a span to measure an operation within one,
and use `event` to attach structured details:

```ruby
Rails.logger.with_span('inventory.check') do
  Rails.logger.info('Checking inventory')
  Rails.logger.event('inventory.checked', available: true)
end
```

For work outside a request, start a trace explicitly:

```ruby
Rails.logger.with_trace('inventory.refresh') do
  Rails.logger.with_span('inventory.fetch') do
    Rails.logger.event('inventory.refreshed', count: 42)
  end
end
```

Without an active trace, `with_span` still runs its block but does not create a span.

### Tagged logging

Rails tags work with both block and chained logging:

```ruby
Rails.logger.tagged('order:123') do
  Rails.logger.info('Checking inventory')
end

Rails.logger.tagged('order:123').warn('Only one item remaining')
```

Tags are saved with each message, so delayed output retains the tags from when
the message was logged. Broadcast destinations keep their own formatters and levels.
Raw `puts`, `print`, `p`, and `Kernel.warn` output is not captured.

### Controller helpers

Both standard and API controllers can add events and attributes to their current
span without additional setup:

```ruby
class OrdersController < ApplicationController
  before_action do
    set_trace_attribute('orders.source', 'web')
    trace_event('orders.authorized')
  end
end
```

## Configuration

Optionally generate an initializer:

```sh
bin/rails generate rails_otel_logging:install
```

For example, to print only completed trees:

```ruby
# config/initializers/rails_otel_logging.rb
OtelLogging.configure do |config|
  config.output_mode = :delayed
  config.service_name = 'orders'
end
```

| Option | Default | Purpose |
| --- | --- | --- |
| `output_mode` | `:live_delayed_on_error` | Control when logs and completed trees appear. |
| `rails_logs` | `:replace` | Use `:preserve` to retain Rails' original subscribers during traces. |
| `service_name` | `'rails_app'` | Identify your service in the managed provider's resource. |
| `service_version` | `'1.0.0'` | Identify your service version. |
| `colorize` | `false` | Enable ANSI colors. |

See the [configuration reference](docs/configuration.md) for instrumentation
switches, view filtering, environment variables, and custom providers.

### Output modes

| Mode | Output |
| --- | --- |
| `:live` | Spans and messages as work runs; failure and exception details at span completion. |
| `:delayed` | One completed tree with durations when the root trace finishes. |
| `:both` | Live output followed by a completed tree for every trace. |
| `:live_delayed_on_error` (default) | Live output, then a completed tree if the trace contains a failure, recorded exception, or error/fatal message. |

The completed tree intentionally repeats earlier messages in `:both` and in the
default mode when an error triggers replay.

## Errors and rescued exceptions

A failed child span remains visible even if its parent rescues the error and the
request succeeds. Logging an error or fatal message triggers the default replay
without marking the span or request as failed.

Exceptions escaping a `with_span` or `with_trace` block are recorded automatically.
If you rescue inside the block, call `span.record_exception(error)` to retain the
exception details. Normal logger thresholds still apply to error output.

See the [logging reference](docs/logging.md) for a rescued-exception example,
span status rules, the complete logger API, and sampling and SDK retention limits.

## Advanced usage

- [Configuration and custom OpenTelemetry providers](docs/configuration.md)
- [Logger API and error behavior](docs/logging.md)
- [Standalone Ruby setup](docs/standalone.md)

## Requirements

Ruby 3.1+, ActiveSupport 7.0 through 8.x, and OpenTelemetry SDK 1.x.
Rails integration is tested with Rails 7.0, 7.1, 7.2, 8.0, and 8.1; the application
supplies its Rails components. Standalone Ruby use does not load Rails.

## Development and contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/NicolasJJensen/rails_otel_logging).

Clone the repository, then run:

```sh
bundle install
bundle exec rake
gem build rails_otel_logging.gemspec
```

The test suite needs no host application, database, or browser. Rails integration
specs boot isolated applications to exercise middleware and request logging.

## License

Available under the [MIT License](LICENSE.txt).
