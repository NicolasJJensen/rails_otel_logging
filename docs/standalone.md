# Standalone Ruby

[Back to the README](../README.md)

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

provider.shutdown
```

The application owns flushing and shutting down an explicitly supplied provider.
Repeated installation with the same logger and provider is a no-op. A conflicting
logger or provider raises `ArgumentError`.

