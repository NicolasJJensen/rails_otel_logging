# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Show completed error traces for failed child spans and recorded exceptions,
  including failures rescued by a successful parent.
- Show errors and recorded exceptions at span completion in live output while
  preserving each span's own status.

## [0.1.0] - 2026-09-21

### Added

- Initial release.
