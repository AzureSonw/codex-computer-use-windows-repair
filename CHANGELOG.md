# Changelog

All notable changes to this project are documented here.

## [1.0.0] - 2026-07-21

### Added

- First packaged release for Windows users.
- A single ZIP containing the PowerShell repair script, CMD launcher, usage guide, version file, and license.
- SHA-256 checksum generation for the downloadable ZIP.
- A reproducible PowerShell packaging script under `tools/`.

### Changed

- Renamed the CMD launcher to the clearer ASCII-only `Run-Codex-Computer-Use-Repair.cmd` name.
- Updated the README with ZIP download, extraction, checksum, and repository layout instructions.

### Safety

- The repair logic remains source-only and does not bundle OpenAI binaries, recovered runtimes, plugin caches, or user configuration.
- The PowerShell repair implementation is unchanged from the repository's initial tested revision.
