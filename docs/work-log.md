# Rails event and instrumentation integration

Implemented November 6, 2026. The gem targets Ruby 3.2+ and Rails/ActiveSupport
8.1+, with OpenTelemetry SDK 1.x. Its managed Rails provider remains private;
applications retain ownership of explicitly supplied providers.

Tracing and correlation methods now live on `OtelLogging`. Logger tracing methods,
`logger.event`, and controller helpers have been removed. Standard logger methods
and Rails tags retain their capture, fallback, severity, and destination behavior.
Structured application events use `Rails.event.notify` or, outside Rails,
`ActiveSupport.event_reporter.notify`.

```ruby
OtelLogging.configure do |config|
  config.instrumentation do
    subscribe "inventory.check"
  end
end

ActiveSupport::Notifications.instrument("inventory.check", product_id: 123) do
  Rails.logger.info("Checking inventory")
  Rails.event.notify("inventory.checked", available: true)
end
```

Application notification rules accept exact names, regular expressions, or
payload-aware callables. The first match wins before built-in framework mappings.
The selected mapping is evaluated at start and completion, with shared parameter
filtering and attribute normalization. Controller, SQL, view, and Cable spans use
the same lifecycle infrastructure. Native Rails completion events already
represented by recording spans are omitted from this gem's output; other event
subscribers remain intact. Exporter output cannot recursively create notification
spans or reporter events.

`with_span` always creates a span. Parameterless `with_trace` creates an independent
root; `with_trace(context:)` activates imported context without creating a span.
`trace_context` returns a serializable W3C hash. Context propagation is explicit in
application code, with no job hooks. Exporters group spans by local entry span,
flush after that root and its already-started children finish, and correlate
separate process output using the shared trace ID.

Validation on macOS with Ruby 3.3.6 and Rails 8.1.3.1:

- Current SDK bundle: 122 examples, zero failures, seed 3129.
- OpenTelemetry SDK 1.0 bundle: 122 examples, zero failures, seed 32335.
- Rails subprocess boot coverage includes development and production, Base/API
  controllers, multiple destinations, default-log replacement, and native events.
- A built and extracted gem loaded without Rails. A second Ruby process consumed
  serialized context after the originating span ended, retained the correct
  trace/parent IDs, and printed its own completed local tree. Logger capture
  appeared once.
- Diff whitespace checks passed. CI covers Ruby 3.2, 3.3, and 3.4 on Rails 8.1;
  only Ruby 3.3 was executed locally.

A local diagnostic benchmark of 10,000 empty notifications per case, with delayed
output and no output device, measured approximately 0.69 microseconds without a
subscriber, 4.31 for unmatched dispatch, 72.86 for an exact rule creating a span,
and 72.81 for a catch-all rule creating a span. These are single-run development
measurements, not application performance guarantees or regression thresholds.
