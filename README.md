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

### Instrument operations and report events

Register application operations in your initializer:

```ruby
OtelLogging.configure do |config|
  config.instrumentation do
    subscribe "inventory.check"
  end
end
```

Use Rails notifications for timed operations, and Rails events for structured facts:

```ruby
ActiveSupport::Notifications.instrument("inventory.check", product_id: 123) do
  Rails.logger.info("Checking inventory")
  Rails.event.notify("inventory.checked", available: true)
end
```

The operation becomes a span, using the notification name and filtered payload.
Requests, controller actions, SQL, views, and selected Action Cable operations
already have built-in instrumentation. Registered operations outside requests
start their own traces.

Direct spans are also supported without registration:

```ruby
OtelLogging.with_span("inventory.refresh") do |span|
  span.set_attribute("inventory.source", "warehouse")
  Rails.event.notify("inventory.refreshed", count: 42)
end
```

`with_span` creates a child of the current span, or a root span and new trace when
there is no parent. It always yields a span object, even when sampling disables
recording. See the [instrumentation guide](docs/instrumentation.md) for matching
rules, transformations, and first-match precedence.

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

### Trace metadata and propagation

Tracing helpers belong to `OtelLogging`, not the logger:

```ruby
OtelLogging.set_span_attribute("order.id", order.id)
OtelLogging.current_trace_id
OtelLogging.current_span_id
```

To continue work elsewhere, pass `OtelLogging.trace_context`, a serialization-ready
hash, and consume it with `OtelLogging.with_span("name", context: context)`.
See the [job example and trace API](docs/logging.md#continuing-a-trace-in-a-job).
The gem does not install job hooks or change job arguments.

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
| `colorize` | `true` in Rails development; `false` otherwise | Enable ANSI colors. |

See the [configuration reference](docs/configuration.md) for instrumentation
switches, view filtering, environment variables, and custom providers.

### Output modes

| Mode | Output |
| --- | --- |
| `:live` | Spans and messages as work runs; failure and exception details at span completion. |
| `:delayed` | One completed tree with durations when the local root and its tracked children finish. |
| `:both` | Live output followed by a completed tree for every local tree. |
| `:live_delayed_on_error` (default) | Live output, then a completed tree if the trace contains a failure, recorded exception, or error/fatal message. |

The completed tree intentionally repeats earlier messages in `:both` and in the
default mode when an error triggers replay.

## Errors and rescued exceptions

A failed child span remains visible even if its parent rescues the error and the
request succeeds. Logging an error or fatal message triggers the default replay
without marking the span or request as failed.

Exceptions escaping an instrumented operation, `with_span`, or a root-creating
`with_trace` block are recorded automatically.
If you rescue inside the block, call `span.record_exception(error)` to retain the
exception details. Normal logger thresholds still apply to error output.

See the [logging reference](docs/logging.md) for a rescued-exception example,
span status rules, the tracing API, and sampling and SDK retention limits.
Completed console trees contain local work; separate processes print separate
trees correlated by trace ID.

## Advanced usage

- [Configuration and custom OpenTelemetry providers](docs/configuration.md)
- [Tracing, logging, and error behavior](docs/logging.md)
- [Instrumentation DSL](docs/instrumentation.md)
- [Standalone Ruby setup](docs/standalone.md)

## Requirements

Ruby 3.2+, Rails/ActiveSupport 8.1+ (below 9.0), and OpenTelemetry SDK 1.x.
The application supplies its Rails components. Standalone Ruby use does not load Rails.

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
