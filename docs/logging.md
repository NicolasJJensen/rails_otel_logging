# Tracing and logging reference

[Back to the README](../README.md)

## Direct tracing

Tracing methods belong to `OtelLogging`; the logger keeps its standard methods.

| Method | Behavior |
| --- | --- |
| `with_span(name, attributes: {}, context: ..., kind: :internal)` | Create and activate a span for the block. Use the current parent by default, or the supplied context. Without a valid parent, start a new trace. |
| `with_trace` | Start an independent trace with a root span named `trace`, even inside another trace. |
| `with_trace("name", attributes: {})` | Start an independent trace with a named root span. |
| `with_trace(context: carrier)` | Activate existing context for the block without creating a span. Does not accept a span name or attributes. |
| `trace_context` | Return a new serializable W3C context hash; return `{}` without a valid active span context. |
| `current_trace_id` / `current_span_id` | Return the current identifiers, including imported context, or `nil`. |
| `set_span_attribute(key, value)` | Filter and normalize an attribute on the current recording span; do nothing without one. |

Span-creating blocks always yield an OpenTelemetry span, including a non-recording
span when sampling disables recording. They return the block's result and restore
the previous context in `ensure`. `with_trace(context:)` activates a parent; it
does not reopen an ended span or extend that span's duration. A supplied context
must be a Hash. Empty or invalid W3C headers provide no valid parent.

```ruby
OtelLogging.with_span("inventory.refresh") do |span|
  span.set_attribute("inventory.source", "warehouse")
  OtelLogging.with_span("inventory.fetch") { fetch_inventory }
end
```

For operations reusable by other Rails instrumentation subscribers, prefer the
[Notifications DSL](instrumentation.md). Direct spans remain fully supported.

## Continuing a trace in a job

The application decides how to pass context. There are no automatic job hooks or
changes to job arguments:

```ruby
# Inside a traced request:
RefreshInventoryJob.perform_later(order.id, OtelLogging.trace_context)
```

```ruby
class RefreshInventoryJob < ApplicationJob
  def perform(order_id, context)
    OtelLogging.with_span("inventory.refresh", context: context) do
      Rails.logger.info("Refreshing inventory")
      OtelLogging.with_span("inventory.fetch") { fetch_inventory(order_id) }
      Rails.event.notify("inventory.refreshed", order_id: order_id)
    end
  end
end
```

This alternative creates the same parent relationship:

```ruby
OtelLogging.with_trace(context: incoming_context) do
  OtelLogging.with_span("inventory.refresh") { refresh_inventory }
end
```

The worker shares the originating trace ID, creates new span IDs, and uses the
captured span as its parent. It may run after the originating request finishes.
Context carries a parent span ID and sampling state, not just a trace ID.

## Local console trees

OpenTelemetry has no global trace-completion signal. Delayed output prints a local
tree after its local root and all already-tracked children finish. A root with a
remote or otherwise untracked parent is still a local output root. Passing context
for a parent already in a local tree keeps the child in that tree.

The request and worker print separate trees with the same trace ID. A tracing
backend can combine their spans; this gem does not aggregate output between
processes or wait for future queued jobs. Long-abandoned buffers are subject to
five-minute cleanup. Sampling and the provider's event-count and attribute limits
also apply to recorded output.

## Standard logging and Rails events

`debug`, `info`, `warn`, `error`, `fatal`, `unknown`, `add`, and `log` retain normal
logger semantics. Inside a recording span, they become span events. Without a
recording span—including inside a context-only block with an imported parent—they
use normal logger output. Lazy blocks run only when their level is enabled.

```ruby
Rails.logger.info("Checking inventory")
Rails.logger.debug { expensive_diagnostic }
Rails.event.notify("inventory.checked", available: true)
```

The event subscriber preserves the Rails event timestamp, payload, tags, execution
context, and source location. Metadata uses `rails.event.tags.*`,
`rails.event.context.*`, and `code.*` attribute names. Custom event objects must
implement `serialize` returning a Hash. Tag objects can also implement `serialize`;
the serialized data is filtered before recording. Additional Rails subscribers
continue to receive events normally.

Imported events have INFO severity. `Rails.event.debug` retains Rails' debug-mode
gating, but the delivered event has no severity marker; the gem does not infer
DEBUG from it. Event names and a payload field named `severity` do not set span
failure status or logger severity. Use standard logger methods for explicit
severity:

```ruby
Rails.event.notify("payment.declined", order_id: 123)
Rails.logger.error("Payment provider unavailable")
```

Rails logger tags are snapshotted for both block and chained forms, including
completed output. Event reporter tags and context remain separate attributes.
Broadcast destinations keep their own formatters and thresholds. Raw `puts`,
`print`, `p`, and `Kernel.warn` are not captured.

Live modes print messages immediately. Delayed mode prints messages in the
completed local tree. `:both` and error-triggered replay intentionally repeat
messages. Exporters bypass capture through the logger's original output methods.

## Errors and rescued exceptions

Exceptions escaping a span-creating block or registered notification are recorded
and re-raised. Failed children retain their ERROR badge even when ancestors rescue
the exception and succeed. A recorded exception alone does not set span status;
live completion uses EXCEPTION for a span with an exception but no error status.

If you rescue inside a block, explicitly record the exception:

```ruby
OtelLogging.with_span("fetch_prices") do |span|
  begin
    fetch_live_prices
  rescue PricingUnavailable => error
    span.record_exception(error)
    Rails.event.notify("prices.fallback_to_cache")
    load_cached_prices
  end
end
```

Error and fatal messages trigger the default completed-tree replay without marking
the span failed. At WARN, warning/error events and their required tree headings
remain visible while informational content is filtered. Context-only
`with_trace(context:)` has no recording span of its own, so use `with_span` around
work whose failures should be recorded.
