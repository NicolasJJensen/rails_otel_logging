# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add automatic Rails Railtie integration, optional install generator, lazy
  component hooks, and automatic controller helpers for Base/API applications.
- Add managed private Rails SDK provider defaults and explicit
  `config.tracer_provider` instance or lambda support.
- Capture standard logger calls and named `event` calls as span events during
  traces, with normal logger fallback outside traces.

### Changed

- Enable colors by default in Rails development; keep them disabled elsewhere,
  with configuration and environment overrides preserved.

- Replace `silence_default_logs` and `OTEL_SILENCE_DEFAULTS` with `rails_logs`
  and `OTEL_RAILS_LOGS`, using `:replace` (default) or `:preserve`.
- `:replace` suppresses duplicate Rails subscribers only during active gem
  traces, preserving logs outside those traces.
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
