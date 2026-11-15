# LaunchLens — Engineering Specification

## 1. Purpose & Reproducible Scope
LaunchLens is a local, zero-network SwiftPM macOS 14+ application (main ledger window, menu bar popover, and headless CLI) that inspects `.plist` service definitions across user/global/system directories, computes deduplicated process-tree resident memory (`RSS`) and `lsof` listening TCP ports across services and detached user orphan daemons, and provides rollback-safe SHA-256 freeze and restore for user-owned `~/Library/LaunchAgents` items.

## 2. Safety Invariants (Unreleased, after `v0.2.0`)
1. **Strict Path Containment (`L8`)**: `FreezeLedgerStore.freeze` checks `lstat(2)` before symlink resolution, rejects symbolic links and non-regular files, resolves the canonical parent directory, and requires strict containment inside `userLaunchAgentsDirectory` (`~/Library/LaunchAgents` by default). Duplicate freezes for an existing `label` are rejected without touching existing snapshots.
2. **Read-Only System Boundaries**: `/Library/LaunchDaemons`, `/Library/LaunchAgents`, and `com.apple.*` items are read-only in both UI and `FreezeLedgerStore`; LaunchLens never invokes `sudo`.
3. **Zero Network Access & Zero Environment Sniffing**: `Sources/` contains zero network calls, zero telemetry, and zero branches on `XCTestConfigurationFilePath` or test environment variables; dependencies (`LaunchctlExecuting`, `stepHook`, directories) are injected explicitly from entrypoints and initializers.
4. **Transactional 6-Step Freeze (`L1, L2, L13, L19, L20`)**:
   - Step 1: Validate domain, non-Apple prefix, `lstat` regular-file check, canonical `LaunchAgents` containment, duplicate `label` check, and vault directory / ancestor directory / subdirectory (`Snapshots/`, `Staged/`) / `ledger.json` writability preflight *before* creating any directory or writing any backup file.
   - Step 2 (`afterWriteBackup`): Write byte-exact `.plist` backup into `Snapshots/` and verify read-back SHA-256.
   - Step 3 (`afterWriteInProgress`): Write an `"inProgress"` (`进行中`) record to `ledger.json` *before* calling `launchctl bootout` or touching the user's `.plist`.
   - Step 4 (`afterBootout`): Execute `/bin/launchctl bootout gui/<uid> <plist>` via `LaunchctlExecuting` and require `exitCode == 0`. On non-zero exit, clean the `"inProgress"` record and backup, leaving the original `.plist` untouched.
   - Step 5 (`afterRemoveOriginalPlist`): Move (never delete) the active `.plist` into `Staged/` next to `Snapshots/`. If moving fails, run `launchctl bootstrap` rollback and clean temporary artifacts.
   - Step 6 (`afterWriteFrozen`): Update the ledger entry from `"inProgress"` to `"frozen"` (`已冻结`) and remove the staged duplicate. If the final ledger commit fails, move the staged `.plist` back to `~/Library/LaunchAgents` and re-run `launchctl bootstrap`.
5. **Safe Restore & Conflict Detection (`L2, L3, L19`)**:
   - Verifies backup SHA-256 before writing anything or calling `bootstrap`.
   - Checks `lstat(2)` at `originalPlistPath`: if a file already exists (for example, recreated by an app update), `restore` refuses silent overwrite and reports both paths, byte sizes, SHA-256 digests, and a PropertyList/line diff so the user can choose explicitly.
   - Preflights vault directory and `ledger.json` writability before writing the target `.plist` or invoking `launchctl bootstrap`.
   - Runs `/bin/launchctl bootstrap gui/<uid> <plist>` and requires `exitCode == 0`. On non-zero exit, removes the newly placed target copy while preserving both the verified backup file and the `.frozen` ledger record.
6. **Startup Integrity Check & Recovery (`L14, L16, L17, L20`)**:
   - On startup (`LaunchLensMonitor.init`), `--cli audit`, `--cli repair`, and rescan, `auditInterruptedTransactionsAndOrphanBackups()` detects `"inProgress"` records, untracked `.plist` files in `Snapshots/` or `Staged/`, missing backup files, or corrupted ledger JSON.
   - During `recoverInterruptedAndOrphanBackups()`, when a byte-matching `.plist` still resides in `LaunchAgents` (either with an `"inProgress"` ledger record or from an untracked pre-ledger `afterWriteBackup` interruption), recovery queries read-only `/bin/launchctl print gui/<uid>/<label>`:
     - `exitCode == 0` (already loaded): cleans duplicate backup/staged files without calling `bootstrap` and never falsely adopts an active service as `.frozen`.
     - `exitCode == 113` (service not found / unloaded): executes `/bin/launchctl bootstrap gui/<uid> <plist>` and requires `exitCode == 0` before cleaning temporary files.
     - Any other non-zero exit code (unexpected `launchctl print` error): preserves the `.plist`, backup file, and record untouched and throws `FreezeError.recoveryPrintFailed`.
   - When the `.plist` was already moved out of `LaunchAgents` into `Snapshots/`/`Staged/`, recovery copies it back and runs `bootstrap`; if `bootstrap` exits non-zero, it removes the unbootstrapped destination copy and downgrades the record to `.frozen`.
7. **Command Confirmation & Read-Only Orphans (`L5, L6`)**:
   - Freezing and restoring in both the main window and menu bar popover open an explicit confirmation sheet displaying the exact `/bin/launchctl` command and file paths.
   - Orphan daemon rows are strictly read-only in UI (no process-termination button).

## 3. Service Memory Formula & Orphan Classification (M1: `L4, L5, L7`)
1. **Service Process-Tree RSS (`L7`)**:
   - Primary root lookup: if `launchctl list` reports `pid > 0` for `meta.label`, `roots = {pid}`.
   - Fallback root lookup (e.g. `/Library/LaunchDaemons` entries invisible to unprivileged `launchctl list`): matches unclaimed `ps` processes whose parsed invocation matches the plist's `Program` / `ProgramArguments` (exact normalized executable path for native binaries; exact runtime family + script/`-m`/`-jar` identity for interpreters).
   - Process-tree sum: `collectProcessTreePIDs(roots:childrenByPPID:)` traverses `ppid -> children` breadth/depth-first with a `Set<Int>` visited set (deduplicating PIDs and guarding against cycles), summing `rssKB * 1024`, `cpuPercent`, and `lsof` listening TCP ports across all tree PIDs.
2. **Orphan Daemon Detection (`L4, L5`)**:
   - Requires `proc.uid == currentUID && proc.ppid == 1`, unclaimed by any active `launchctl list` tree or plist-matched service tree, and not matching any known non-frozen plist invocation.
   - Excludes `/System/`, `/usr/libexec/`, `/usr/sbin/`, `/sbin/`, `.xpc/Contents/`, `.appex/Contents/`, and genuine GUI `.app/Contents/` bundles, while explicitly exempting command-line framework interpreter bundles (`Python.app`, `Python3.app`, `Ruby.app`) and `Xcode.app/Contents/Developer/` toolchains.
   - Matches native developer/AI daemons strictly by exact executable basename (`exactDevDaemonBasenames`, zero substring matching) and classifies scripting runtimes (`python*`, `node`, `deno`, `bun`, `npx`, `bunx`, `tsx`, `ts-node`, `uv`, `uvx`, `ruby`, `perl`, `java`) and shells (`sh`, `bash`, `zsh`, `dash`, `fish`) by their target script path, `-m <module>`, or `-jar <jar>`.

## 4. Targets & CLI Exit Codes (`L9`, Unreleased after `v0.2.0`)
- `LaunchLensCore`: `Models`, `Scanners`, `Services`, `CLI`, `Localization`, `ViewModels`, `Views`.
- `LaunchLens`: Pre-GUI CLI entrypoint (`LaunchLensEntrypoint`) + SwiftUI app (`--demo` loads synthetic preview data with `[DEMO]` badges; default launch scans live host).
- CLI subcommands: `list`, `orphans`, `frozen`, `audit`, and confirmation-gated write subcommands `freeze <label> --confirm`, `restore <id-or-label> --confirm`, `repair --confirm` (`--json`, `--lang en|zh`, `--ledger-dir <dir>`, `--agents-dir <dir>`, `--help` / `-h`). Invoking `freeze`, `restore`, or `repair` without `--confirm` performs zero writes and zero `launchctl` mutations, prints the exact command and file paths to `stderr`, and exits with code `2`.
- CLI exit codes:
  - `0`: Command succeeded.
  - `1`: Runtime, filesystem, corrupted ledger, freeze/restore/repair failure, or `audit` integrity error.
  - `2`: Unknown subcommand (`--cli nosuchcmd`), missing required target argument, missing `--confirm` on write subcommands, unknown option flag, or invalid argument value.
