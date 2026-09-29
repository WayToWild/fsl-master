# Changelog

Notable changes to FSL Master. Format: [Keep a Changelog](https://keepachangelog.com/), versions: [SemVer](https://semver.org/).

## [0.1.1] - 2026-09-29

### Changed
- The whole application (user interface, messages, reports, log messages, build output) and all documentation are now in English.

### Fixed
- The "FSLogix absent" service-info test no longer depends on the services of the machine running the tests.

## [0.1.0] - 2026-09-29

### Added
- First version: WPF interface (PowerShell 5.1) with dashboard, FSLogix configuration (policy vs. local), services and components,
  users and sessions (WTS API), containers and redirects, events, FSLogix log files, health check with score, reporting
  (HTML/JSON/CSV/TXT, optionally sanitized) and an About screen.
- Background processing in runspaces, error isolation per data source, auto-refresh without overlapping runs.
- Dark and light theme; status always with text and icon.
- Portable `fsl-master.exe` (PS2EXE 1.0.18, `requireAdministrator`), SHA256 file and ZIP via `build.ps1`.
- Pester test suite for the data collection and export layers.
- Documentation: README, architecture, building, security, troubleshooting.
