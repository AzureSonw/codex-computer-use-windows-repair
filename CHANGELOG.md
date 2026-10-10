# Changelog

All notable changes to this project are documented here.

## [1.3.1] - 2026-10-10

### Fixed

- Fixed a real v1.3.0 initialization blocker on Codex `26.1007.2314.0`: the repair wrote a plain Windows marketplace path, while the app server compares it against its canonical `\\?\C:\...` source. The same directory was rejected as "already added from a different source", leaving Chrome registration missing until timeout.
- Obtain the canonical source from a Windows directory handle, preserving filesystem casing and long names. Migrate the old configuration with an exact backup and retain disabled-plugin choices and unrelated settings.
- Accept the app server's basic, literal and single-line triple-literal TOML encodings, including paths containing apostrophes. A valid desktop rewrite no longer triggers repeated configuration repair.

### Verified

- Added `tests/Test-Marketplace.ps1`, which starts the trusted installed app server with isolated homes. It reproduces the old source conflict, applies the real configuration repair, and verifies two successful registrations and checker acceptance, including spaces, apostrophes and case aliases.
- Live desktop initialization and Chrome extension connectivity still require running the repair after closing Codex. Successful marketplace registration alone is not a successful Chrome handshake.

## [1.3.0] - 2026-10-03

### Added

- Chrome desktop integration checks: trusted Native Messaging manifest/bridge/origins, current-user HKCU registration, versioned `latest` junction, both v2 resource registrations, and bundled marketplace initialization metadata.
- A separate `Repair.Chrome.ps1` stage prepares a hash-verified decrypted resource view and, with `-InitializeChrome`, lets the official desktop application generate registration and feature-dependent marketplace metadata. The existing CMD enables this one-time initialization when needed.
- `ChromeIntegration` diagnostics, integration snapshots, automatic rollback after initializer failure when process guards permit, and explicit `-RestoreChromeBackup` recovery.
- Isolated Chrome fault/rollback tests and installed-package discovery/resource-view validation that never initializes live Chrome registration.

### Fixed

- Healthy runtime/plugin trees no longer hide incomplete Chrome registration after WindowsApps copying interrupted marketplace initialization. This is one cause of an installed extension incorrectly requesting the desktop app.
- Healthy manual runs preserve files/configuration just like automatic runs. Registration-only repairs leave healthy resource trees in place, and both entry points preserve disabled-plugin preferences.

### Safety

- Preserve trusted Store package discovery, decrypted stream copying, staging/hash checks, backups, process guards and PowerShell 5.1/7 compatibility. No package/plugin version or extension ID is hard-coded.
- Back up existing integration files, HKCU default value/key existence and latest target before invoking desktop initialization. Tool registry writes are limited to restoring that exact HKCU value; no HKLM writes or direct registration synthesis.
- Recognize initialization contracts from the trusted installed application and fail closed on unsupported layouts/content variants. The environment override is process-local. No startup task, scheduled task, background repair service, downloads or redistributed OpenAI binaries.
- Initialization timeout or inability to validate returns `Deferred`; local `Healthy` does not claim a successful browser handshake. Real desktop initialization/Chrome handshake must still be checked through the repair entry point.

## [1.2.1] - 2026-09-12

### Fixed

- Fixed unrelated Node processes (observed with Elgato Stream Deck) blocking repair after Codex had fully quit. When `Get-Process.Path` is unreadable, query the process image using `PROCESS_QUERY_LIMITED_INFORMATION` before classifying it. Unrelated resolved Node paths are excluded; genuine runtime users and unresolved processes still block safely.
- Show blocking process names, PIDs, image paths, and reasons in diagnostics instead of only saying Codex is running.
- The CMD invocation now waits up to 120 seconds for blockers to exit and continues within the same window. No scheduled task, startup entry, background service, or forced process termination is added.
- Retry transient directory move access/sharing failures for at most one second, with process checks before retries and existing backup/rollback behavior retained.

### Verified

- Added native process-query and Stream Deck regression tests, with bounded-wait and PID-reporting assertions in the existing isolated suite.
- Clean isolated restoration from Codex `26.908.4834.0`: 4,123 runtime files / 263,414,106 bytes, 952 marketplace files / 82,779,095 bytes, Node `v24.20.0`; repeated healthy check preserved configuration and backups.

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
