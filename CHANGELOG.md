# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add the `config.instrumentation` subscription DSL with exact, regex, and callable
  matchers, first-match precedence, and payload-based name/attribute transforms.
- Capture Rails 8.1 events with timestamps, tags, execution context, and source
  locations, while preserving other subscribers and avoiding framework duplicates.
- Add serializable `OtelLogging.trace_context` propagation and local output trees
  for work continuing a trace in another process.
- Add automatic Rails Railtie integration, optional install generator, lazy
  component hooks, and Base/API application support.
- Add managed private Rails SDK provider defaults and explicit
  `config.tracer_provider` instance or lambda support.
- Capture standard logger calls and Rails events as span events during recording
  spans, with normal logger fallback outside recording spans.

### Changed

- Require Ruby 3.2+ and Rails/ActiveSupport 8.1+.
- Move tracing and correlation helpers to `OtelLogging`; remove logger tracing
  methods, `logger.event`, and controller-specific tracing helpers.
- Make `with_span` always create a span. Parameterless `with_trace` creates an
  independent root; `with_trace(context:)` activates context without a span.
- Consolidate controller, SQL, view, and Cable instrumentation into notification
  lifecycle spans, with shared payload filtering and normalization.
- Enable colors by default in Rails development; keep them disabled elsewhere,
  with configuration and environment overrides preserved.
- Replace `silence_default_logs` and `OTEL_SILENCE_DEFAULTS` with `rails_logs`
  and `OTEL_RAILS_LOGS`, using `:replace` (default) or `:preserve`.
- `:replace` suppresses duplicate Rails subscriber output for operations
  represented by gem spans, preserving fallback output when sampling drops spans.
- Hybrid output replays a completed tree for actual failures and `ERROR` or
  `FATAL` events; event severity alone does not mark a span or request failed.
- Apply logger level filtering before evaluating lazy blocks and retain tagged
  snapshots in delayed trees.

### Fixed

- Show completed error traces for failed child spans and recorded exceptions,
  including failures rescued by a successful parent.
- Show errors and recorded exceptions at span completion in live output while
  preserving each span's own status.

## [0.1.0] - 2026-09-21

### Added

- Initial release.
