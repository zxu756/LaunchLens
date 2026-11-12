# LaunchLens

**Native macOS background `LaunchAgents`, `LaunchDaemons`, and orphaned AI/dev daemon memory ledger with byte-exact SHA-256 reversible freeze & restore.**

![LaunchLens Main Ledger](docs/screenshot-main.png)

Developers on Apple Silicon routinely lose 4–12 GB of unified RAM and dozens of `localhost` TCP ports to forgotten background `LaunchAgents`, silent auto-updaters, and orphaned CLI / MCP child processes (`PPID == 1` `node`, `python`, `uvx`, `ollama`, `codex` daemons) that outlive terminal sessions.

**LaunchLens** is a ~1.5 MB pure-SwiftPM macOS 14+ application (main ledger window + menu bar popover + headless CLI) with **zero third-party dependencies, zero root prompts, and zero network access**.

## Highlights

- **Unified Memory Allocation Strip** — Visualizes at a glance how your non-Apple background resident memory (RSS) is split across persistent `LaunchAgents`, system daemons, and orphaned developer processes.
- **Orphaned AI & Dev Daemon Detector** — Correlates `launchctl list`, `ps`, and `lsof` to isolate `PPID == 1` processes owned by your user (`node`, `npx`, `uvx`, `python`, `ollama`, `codex`, `claude`, `opencode`) that are not tracked by any `.plist` or `.app` UI bundle.
- **Byte-Exact SHA-256 Freeze & Restore Vault** — Freezing a user `LaunchAgent` writes an immutable `.plist` backup + SHA-256 digest to `~/Library/Application Support/LaunchLens/Snapshots/` *before* calling `launchctl bootout gui/<uid>` and moving the active `.plist` aside so it never respawns on reboot. One click verifies the SHA-256 digest, restores the exact original bytes, and runs `launchctl bootstrap`.
- **Strict Safety Boundaries** — `/Library/LaunchDaemons`, `/Library/LaunchAgents`, and `com.apple.*` services are strictly read-only; LaunchLens never requests `sudo` or modifies system files.
- **Menu Bar Popover & Headless CLI** — Pin your live non-Apple background RSS in the macOS menu bar, or query directly from a terminal.

<p align="center">
  <img src="docs/screenshot-menubar.png" width="380" alt="LaunchLens Menu Bar Popover" />
</p>

## Install

### Homebrew Cask

```bash
brew install --cask zxu756/tap/launchlens
```

### Build from Source (macOS 14.0+, Apple Silicon)

```bash
git clone https://github.com/zxu756/LaunchLens.git
cd LaunchLens
swift test
chmod +x Scripts/build-app.sh
./Scripts/build-app.sh
open build/LaunchLens.app
```

## Headless CLI Usage

```bash
# Top non-Apple background services ranked by live RSS
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list

# List orphaned PPID==1 developer & MCP daemons
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli orphans

# Inspect SHA-256 verified frozen snapshots
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli frozen
```

## Architecture & Spec

See [docs/SPEC.md](docs/SPEC.md) for the correlation pipeline, safety invariants, and snapshot state machine.

## License

MIT
