# Changelog

All notable changes to this project are documented here.

## [1.2.0] - 2026-09-12

### Added

- Check-first CMD workflow: discover the currently installed trusted Store package and invoke the repair PS1 only when runtime, plugin resources, or necessary configuration need repair.
- Resource fingerprints and cached SHA-256 verification of every file, with key hashes checked on each invocation and a full audit on the next invocation after 24 hours (or with `-FullCheck`).
- Local diagnostic results, bounded log retention, exclusive invocation locking, bounded optional process waiting, failed-attempt cooldowns, and interrupted-repair detection.
- Isolated behavior and installed-package end-to-end tests, including same-version resource changes, same-size corruption, package updates, healthy no-op behavior, process races, rollback, and failure handling.

### Changed

- Healthy CMD runs no longer repeat repair, configuration writes, Node self-tests, or backups. Existing disabled-plugin preferences survive on-demand repair.
- Copy and verify staging before moving an existing directory to backup; recheck processes/package identity before publication. Process-check bypass now requires an isolated test root.
- Retained the original manual PowerShell entry point. No startup entries, scheduled tasks, background services, or automatic Codex launches are installed.
- Support registered Store package roots located on another volume through a junction while rejecting links within resource trees and repair targets.

### Verified

- Windows PowerShell 5.1 and PowerShell 7.x isolated behavior tests.
- Codex `26.901.6511.0` isolated restore: 4,684 runtime files, 849 marketplace files, restored Node `v24.19.0`, followed by healthy repeated checks.

## [1.1.0] - 2026-09-06

### Fixed

- Restored compatibility with Codex `26.820.9563.0` and later verified Codex `26.901.6511.0`, whose packages no longer include the previous Computer Use client wrapper script.
- Switched plugin-tree verification to a stable skill manifest and added clearer diagnostics for incomplete restored trees.
- Detect both `Codex.exe` and `ChatGPT.exe` before replacing runtime files.

### Verified

- Completed a clean isolated restore from Codex `26.820.9563.0`: 4,680 `cua_node` files, 826 bundled marketplace files, and restored Node.js `v24.19.0`.
- Completed a clean isolated restore from Codex `26.901.6511.0`: 4,684 `cua_node` files, 849 bundled marketplace files, and restored Node.js `v24.19.0`.
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
