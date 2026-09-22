# Logging reference

[Back to the README](../README.md)

## Logger API

- `with_trace(name, attributes: {}) { |span| ... }`: root trace with exception cleanup.
- `with_span(name, attributes: {}) { |span| ... }`: child span inside a trace; outside
  a trace it yields `nil` and still runs the block.
- `debug`, `info`, `warn`, `error`, `fatal`, `unknown`, `add`, and `log`: standard Ruby logger
  calls. Inside a trace they are captured as span events; outside a trace they are
  emitted normally. Lazy blocks are checked against the logger level before they
  are evaluated.
- `event(name, severity: :info, **attributes)`: captures a named span event with
  severity and attributes inside a trace, and falls back to normal logger output
  outside a trace. `ERROR` and `FATAL` severity request the hybrid tree without
  changing span or request failure status.
- `tagged(*tags) { ... }` and chained tagged logging (with a tagged logger): tag values are snapshotted
  with each message, including delayed trees, so later tag changes do not rewrite history.
- `current_trace_id` / `current_span_id`: correlation identifiers or `nil`.

Raw `puts`, `print`, `p`, and `warn` to `STDERR` remain Ruby output and are not
captured as span events.

Existing request logging needs no changes:

```ruby
Rails.logger.tagged('order:123') do
  Rails.logger.info('Checking inventory')
  Rails.logger.warn('Only one item remaining')
  Rails.logger.debug { expensive_diagnostic }
end
```

Live mode prints each message immediately; delayed mode prints it once in the
completed tree. Hybrid mode intentionally replays messages in the completed tree
after an error. Broadcast destinations retain their own formatters and thresholds.

If sampling disables span recording, messages use normal logger output instead.
Completed trees use events retained by the SDK, so the provider's event-count and
attribute limits still apply.

## Errors and span status

Errors remain visible even when the request recovers. A failed child gets an
`ERROR` badge without changing its parent's status. Recorded exceptions do not
automatically mark a span as failed: live completion output uses `EXCEPTION`
when the span contains an exception but has no error status, and completed trees
show the exception event beneath that span. No recovery status is inferred;
use an event such as `prices.fallback_to_cache` to explain how work continued.

An `ERROR` or `FATAL` event requests the hybrid completed tree but does not mark
the span or request as failed. Failed spans receive the `ERROR` badge; recorded
exceptions are shown at error severity. At a `WARN` logger threshold, warning and error events remain
available, while debug/info event content is filtered; the tree headings needed
to show their structure are retained.

Exceptions that escape a `with_span` or `with_trace` block are recorded
automatically. If you rescue inside the block, explicitly record the exception
so it remains visible:

```ruby
logger = Rails.logger
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

