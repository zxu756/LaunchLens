# LaunchLens — Engineering Specification

## 1. Purpose & Reproducible Scope
LaunchLens is a local, zero-network SwiftPM macOS 14+ application (main ledger window, menu bar popover, and headless CLI) that inspects `.plist` service definitions across user/global/system directories, correlates user-domain `launchctl list` PIDs with `ps` resident memory (`RSS`) and `lsof` listening TCP ports, and provides rollback-safe SHA-256 freeze and restore for user-owned `~/Library/LaunchAgents` items.

## 2. Safety Invariants (since `v0.3.0`)
1. **Strict Path Containment (`L8`)**: `FreezeLedgerStore.freeze` checks `lstat(2)` before symlink resolution, rejects symbolic links and non-regular files, resolves the canonical parent directory, and requires strict containment inside `userLaunchAgentsDirectory` (`~/Library/LaunchAgents` by default). Duplicate freezes for an existing `label` are rejected without touching existing snapshots.
2. **Read-Only System Boundaries**: `/Library/LaunchDaemons`, `/Library/LaunchAgents`, and `com.apple.*` items are read-only in both UI and `FreezeLedgerStore`; LaunchLens never invokes `sudo`.
3. **Zero Network Access**: `Sources/` contains zero network calls or telemetry.
4. **Transactional 6-Step Freeze (`L1, L2, L13, L19`)**:
   - Step 1: Validate domain, non-Apple prefix, `lstat` regular-file check, canonical `LaunchAgents` containment, duplicate `label` check, and vault directory / subdirectory / `ledger.json` writability preflight *before* creating any directory or writing any backup file.
   - Step 2: Write byte-exact `.plist` backup into `Snapshots/` and verify read-back SHA-256.
   - Step 3: Write an `"inProgress"` (`进行中`) record to `ledger.json` (re-verifying writability) *before* calling `launchctl bootout` or touching the user's `.plist`.
   - Step 4: Execute `/bin/launchctl bootout gui/<uid> <plist>` via `LaunchctlExecuting` and require `exitCode == 0`. On non-zero exit, clean the `"inProgress"` record and backup, leaving the original `.plist` untouched.
   - Step 5: Move (never delete) the active `.plist` into `Staged/` next to `Snapshots/`. If moving fails, run `launchctl bootstrap` rollback and clean temporary artifacts.
   - Step 6: Update the ledger entry from `"inProgress"` to `"frozen"` (`已冻结`) and remove the staged duplicate. If the final ledger commit fails, move the staged `.plist` back to `~/Library/LaunchAgents` and re-run `launchctl bootstrap`.
5. **Safe Restore & Conflict Detection (`L2, L3, L19`)**:
   - Verifies backup SHA-256 before writing anything or calling `bootstrap`.
   - Checks `lstat(2)` at `originalPlistPath`: if a file already exists (for example, recreated by an app update), `restore` refuses silent overwrite and reports both paths, byte sizes, SHA-256 digests, and a PropertyList/line diff so the user can choose explicitly.
   - Preflights vault directory and `ledger.json` writability before writing the target `.plist` or invoking `launchctl bootstrap`.
   - Runs `/bin/launchctl bootstrap gui/<uid> <plist>` and requires `exitCode == 0`. On non-zero exit, removes the newly placed target copy while preserving both the verified backup file and the `.frozen` ledger record.
6. **Startup Integrity Check & Recovery (M0 Item 3, `L14, L16, L17`)**:
   - On startup (`LaunchLensMonitor.init`), `--cli audit`, and rescan, `auditInterruptedTransactionsAndOrphanBackups()` detects `"inProgress"` records, untracked `.plist` files in `Snapshots/` or `Staged/`, missing backup files, or corrupted ledger JSON, surfacing a `Repair / Recover` (`修复 / 恢复`) flow.
   - During `recoverInterruptedAndOrphanBackups()`, when the original `.plist` is still in `LaunchAgents` matching the backup SHA-256 (Branch 1), recovery first runs read-only `/bin/launchctl print gui/<uid>/<label>`: if `exitCode == 0` (interrupted before `bootout`, service still loaded), it skips `bootstrap` and cleans temporary backup/staged files; if `exitCode != 0` (interrupted after `bootout` before moving the `.plist`), it executes `/bin/launchctl bootstrap gui/<uid> <plist>` and checks `exitCode == 0` before deleting the backup or clearing `"inProgress"` (preserving the `.plist`, backup, and `"inProgress"` record with `FreezeError.recoveryBootstrapFailed` on non-zero exit). When the `.plist` was already moved out of `LaunchAgents` and sits in `Snapshots/`/`Staged/` (Branch 2), recovery copies it back and runs `bootstrap`; if `bootstrap` exits non-zero, it removes the unbootstrapped destination copy and downgrades the record to `.frozen` so the user can inspect or restore manually.
7. **Command Confirmation & Read-Only Orphans (`L5, L6`)**:
   - Freezing and restoring in both the main window and menu bar popover open an explicit confirmation sheet displaying the exact `/bin/launchctl` command and file paths.
   - Orphan daemon rows are strictly read-only in M0 (no process-termination UI button).

## 3. Known M0 Measurement Limits & Planned M1 Work
- **User-Domain `RSS` Accounting Scope (`L7`)**: `LaunchScanner.scanLiveHost` queries unprivileged `/bin/launchctl list`, which reports PIDs in the current user GUI domain. Root/system-domain `LaunchDaemons` without user-domain PIDs appear with `Idle` / `0 MB` in M0, and helper child processes not directly listed as the `launchctl` PID are not yet summed into parent service RSS (scheduled for M1).
- **Orphan Detection Heuristics (`L4, L5`)**: In M0, `LaunchScanner.correlate` matches `uid == currentUID && ppid == 1` processes not claimed by `launchctl list` using runtime command substrings (`node`, `python`, `uvx`, `mcp`, etc.) and skips paths containing `.app/Contents/`. On macOS, framework Python binaries (`Python.app/Contents/MacOS/Python`) are missed by that `.app/Contents/` exclusion, and non-daemon commands whose arguments contain hint substrings can match. Exact executable + script resolution is scheduled for M1.

## 4. Targets & CLI Exit Codes (`L9`, since `v0.3.0`)
- `LaunchLensCore`: `Models`, `Scanners`, `Services`, `CLI`, `Localization`, `ViewModels`, `Views`.
- `LaunchLens`: Pre-GUI CLI entrypoint (`LaunchLensEntrypoint`) + SwiftUI app (`--demo` loads synthetic preview data with `[DEMO]` badges; default launch scans live host).
- CLI exit codes:
  - `0`: Command succeeded (`list`, `orphans`, `frozen`, clean `audit`, `--help` / `-h`).
  - `1`: Runtime, filesystem, corrupted ledger, or `audit` integrity error.
  - `2`: Unknown subcommand (`--cli nosuchcmd`), unknown option flag, or invalid argument value.
