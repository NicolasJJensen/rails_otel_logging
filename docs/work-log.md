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

Validation: 78 examples pass on the local Ruby 3.3 / Rails 8.0 bundle. Fresh
Rails processes verify automatic boot, Base/API controllers, view spans, lazy SQL
logging, replacement/preservation, request cleanup, and managed/external provider
lifecycle. The gem builds with the Railtie and generator included, and the
packaged core loads without Rails. The broader compatibility matrix remains a
CI check.
