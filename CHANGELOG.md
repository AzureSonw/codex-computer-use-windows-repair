# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Fixed

- Restored compatibility with Codex `26.820.9563.0` and the bundled Computer Use plugin `26.820.71523`, whose package no longer includes the previous client wrapper script.
- Switched plugin-tree verification to a stable skill manifest and added clearer diagnostics for incomplete restored trees.
- Detect both `Codex.exe` and `ChatGPT.exe` before replacing runtime files.

### Verified

- Completed a clean isolated restore from Codex `26.820.9563.0`: 4,680 `cua_node` files, 826 bundled marketplace files, and restored Node.js `v24.19.0`.
- Rechecked syntax with Windows PowerShell 5.1 and PowerShell 7.x, repeated-run behavior, and the repaired Computer Use API.

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
