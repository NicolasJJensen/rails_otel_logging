# RailsOtelLogging extraction

The reusable implementation now lives in `../rails_otel_logging` (version 0.1.0).
The application loads it through a local Gemfile path. The gem README documents
standalone Ruby and optional Rails setup. The original 38 logging examples moved
to the gem; lifecycle, ownership, installation, and Rails regressions expand its
suite to 54 passing examples.

`OtelLogging.configure` only changes settings. Installation explicitly accepts a logger
and an SDK tracer provider, preserves existing processors, and rejects conflicting
repeat installation. Core loading does not load Rails or configure the global SDK.
The application initializer owns its local provider and shutdown, or reuses an
existing global SDK provider. Controller helpers use `OtelLogging::ControllerHelpers`.

Default Rails logging suppression remains enabled. To retain Rails defaults, set
`OTEL_SILENCE_DEFAULTS=false` before starting the application, or set
`config.silence_default_logs = false` before installation. The separate development
view logger override was removed so it cannot defeat this opt-out. Application
logs remain enabled. Suppression removes framework log subscribers; it does not
blanket-mute the ActionCable connection logger.

Validation: 54 gem examples pass, including two fresh Rails application boot
checks for suppression on/off, request completion, middleware uniqueness, logger
tag cleanup, and SQL logging. Two host integration examples verify actual gem
loading, provider ownership, controller helpers, middleware, nested output and
context cleanup. The built RubyGem installs and loads without Rails or replacing
the global provider. An unintended unfiltered host suite also ran and failed;
its browser/system failures are not treated as extraction validation. Browser
compatibility is not established by this work.
