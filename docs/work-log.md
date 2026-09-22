# RailsOtelLogging extraction

The reusable implementation lives in `../rails_otel_logging` (version 0.1.0).
Rails applications load it from the Gemfile and get the integration through the
Railtie automatically when `Rails::Railtie` is defined. The optional
`rails_otel_logging:install` generator writes an initializer for application-specific
configuration.

The Rails integration installs middleware, logger methods, and the single
`OtelLogging::ControllerHelpers` module for both Base and API controllers, plus
lazy notification hooks for the Rails components that are present.
`OtelLogging.configure` defaults to `:live_delayed_on_error` and `rails_logs: :replace`.
Replacement suppresses duplicate Rails subscribers only while an active gem trace
is running; logs outside gem traces remain available. `rails_logs: :preserve` keeps
the Rails subscribers active, and `OTEL_RAILS_LOGS=replace|preserve` selects the
boot default.

Rails creates a private SDK provider by default, manages its lifecycle, and derives
`service.name` and `service.version` from configuration. It does not replace the
global provider. `config.tracer_provider` accepts an explicit provider instance or
a lambda resolved after application initializers. An externally supplied provider
and its shutdown remain application-owned.

The standalone path remains explicit: core loading does not load Rails, and callers
install with `OtelLogging.install!(logger:, tracer_provider:)`. Installation adds
the gem's processors to the supplied provider without replacing it or taking over
its lifecycle. No compatibility aliases are retained for the former
`silence_default_logs` setting or `OTEL_SILENCE_DEFAULTS` variable.

Standard `debug`, `info`, `warn`, `error`, `fatal`, `add`, and `log` calls become
span events during an active trace and use normal logger output outside one.
`event(name, severity:, **attributes)` follows the same capture and fallback
rules. Logger thresholds are checked before lazy blocks run. Tagged logging uses
snapshots for both block and chained forms, including delayed output. At WARN,
warn/error events and the tree headings needed for structure remain while
debug/info event content is filtered. `ERROR` and `FATAL` events request the
hybrid live plus completed replay but do not mark the span or request failed;
actual failures still receive the `ERROR` badge. Raw `puts`, `print`, `p`, and
`warn` to STDERR remain untouched. Exporters write through the logger's original
`add` method to avoid recursion and accidental duplicates.

Validation: the full suite passes with 103 examples on the default Rails 8.0
bundle, Rails 8.1, and the OpenTelemetry SDK 1.0 bundle. Rails 7.0 also has no
failures, with four expected skips for BroadcastLogger, introduced in Rails 7.1.
The built gem was extracted and loaded independently without Rails; a standard
logger message appeared exactly once in delayed output. The diff whitespace
check passes.
