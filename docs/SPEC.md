# LaunchLens — Engineering Specification (`v0.1.0`)

## 1. Problem Statement & Scope
macOS developers accumulate background `LaunchAgents`, `LaunchDaemons`, and orphaned CLI/MCP child processes (`PPID == 1` `node`, `python`, `uvx`, `codex` daemons) that silently consume gigabytes of unified RAM and bind `localhost` TCP ports across sessions. Existing native tools are either paid closed-source utilities or raw plist editors that do not correlate `.plist` definitions with live RSS memory, listening ports, and reversible state snapshots.

**LaunchLens** is a lightweight (~2 MB), zero-network, pure-SwiftPM native macOS 14+ application (main dashboard + menu bar extra + CLI) that:
1. Ranks every active persistent agent, daemon, and orphaned user process by **live resident memory (RSS)**, CPU%, and bound TCP ports.
2. Provides **100% reversible freeze & restore** for user-domain `~/Library/LaunchAgents` items via byte-exact `.plist` snapshots and a local JSON ledger—never deleting original configuration files without a verified backup.

## 2. Non-Goals & Safety Invariants
- **Zero Root Escalation**: System `/Library/LaunchDaemons` and `/Library/LaunchAgents` are strictly **read-only** in the UI/CLI; LaunchLens never prompts for `sudo` or modifies `/System` or `/Library`.
- **Zero Network Access**: No `URLSession`, telemetry, or external calls.
- **Byte-Exact Reversibility**: Freezing a user `LaunchAgent` writes an immutable backup copy + SHA-256 digest into `~/Library/Application Support/LaunchLens/Snapshots/` before unloading via `launchctl bootout gui/<uid>` and moving the active `.plist` aside so `launchd` will not respawn it on reboot; restoring moves the exact original bytes back to `~/Library/LaunchAgents/` and runs `launchctl bootstrap gui/<uid>`.
- **Apple System Filtering**: `com.apple.*` services are hidden by default behind an explicit "Show Apple System Services" toggle and can never be frozen.

## 3. Data Pipeline (Verified on macOS 14–27)
1. **Plist Discovery**: `~/Library/LaunchAgents/*.plist`, `/Library/LaunchAgents/*.plist`, `/Library/LaunchDaemons/*.plist` decoded via `PropertyListSerialization`.
2. **Launchd Runtime State**: `launchctl list` (`PID`, `LastExitStatus`, `Label`).
3. **Process Footprint & Orphan Detection**: `ps -axo pid,ppid,uid,rss,pcpu,comm`:
   - Matches running `PID`s back to `launchctl` labels.
   - Detects **Orphaned Developer/Agent Daemons**: current-UID processes with `ppid == 1` whose executable is not backed by any known LaunchAgent or `.app` UI bundle and matches developer/agent runtimes (`node`, `python`, `uv`, `uvx`, `npx`, `codex`, `claude`, `opencode`, `deno`, `bun`, `ollama`, `llama-server`).
4. **Port Correlation**: `lsof -iTCP -sTCP:LISTEN -P -n -F pcn` maps `PID -> [UInt16]` listening ports.

## 4. Architecture & Targets
- `LaunchLensCore` (Swift library):
  - `Models/LaunchModels.swift`
  - `Scanners/LaunchScanner.swift` (injectable command runner & directory paths for deterministic unit tests)
  - `Services/FreezeLedgerStore.swift` (snapshot backup, SHA-256 verification, freeze/restore state machine)
  - `ViewModels/LaunchLensMonitor.swift` (`@MainActor` observable store + `.preview` deterministic dataset + 2x Retina `ScreenshotExporter`)
  - `Views/MainDashboardView.swift` & `Views/MenuBarPopoverView.swift`
- `LaunchLens` (Executable):
  - SwiftUI `@main` app (`Window` + `MenuBarExtra`)
  - Headless CLI flags: `--cli list`, `--cli orphans`, `--export-screenshots <dir>`
- `LaunchLensCoreTests` (Swift Testing suite):
  - `ps` / `launchctl` / `lsof` parser tests
  - Orphaned MCP/CLI daemon classification tests
  - Hermetic temporary-directory Freeze → Ledger → Byte-exact Restore round-trip test
  - 2x Retina screenshot rendering test
