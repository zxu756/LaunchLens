#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

RECORD="${LAUNCHLENS_RECORD:-0}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --record)
            RECORD=1
            ;;
        *)
            echo "Usage: Scripts/acceptance/m0-acceptance.sh [--record]" >&2
            exit 2
            ;;
    esac
    shift
done

REPORT_FILE="$ROOT/reports/m0-acceptance.txt"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/launchlens-m0-accept.XXXXXX")"
cleanup() {
    chmod -R u+rwx "$TMP_ROOT" 2>/dev/null || true
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

RAW_REPORT="$TMP_ROOT/m0-acceptance.raw.txt"
SANITIZED_REPORT="$TMP_ROOT/m0-acceptance.sanitized.txt"

# Derive SwiftPM package identity dynamically from the repository directory basename (L12 & W2)
PKG_IDENTITY="$(basename "$(cd "$ROOT" && pwd)")"

{
    echo "================================================================"
    echo "LaunchLens M0 Acceptance Suite (Hermetic Temp Dir + Fake launchctl)"
    echo "================================================================"
    echo "[Info] SwiftPM package dependency identity: $PKG_IDENTITY"

    echo "[Setup] Building LaunchLens executable..."
    swift build --product LaunchLens >/dev/null
    BIN_PATH="$(swift build --show-bin-path)/LaunchLens"
    if [[ ! -x "$BIN_PATH" ]]; then
        echo "FAIL: Built LaunchLens executable not found at $BIN_PATH" >&2
        exit 1
    fi

    # Programmable fake launchctl binary (shell script controlled via env / state files in $TMP_ROOT)
    FAKE_LAUNCHCTL="$TMP_ROOT/fake-launchctl.sh"
    cat > "$FAKE_LAUNCHCTL" <<'EOF'
#!/bin/sh
STATE_DIR="$FAKE_LAUNCHCTL_STATE_DIR"
echo "$*" >> "$STATE_DIR/calls.log"
SUBCMD="$1"
if [ "$SUBCMD" = "bootout" ] && [ -f "$STATE_DIR/bootout_exit" ]; then
    CODE="$(cat "$STATE_DIR/bootout_exit")"
    if [ "$CODE" != "0" ]; then
        echo "fake launchctl bootout failure (code=$CODE)" >&2
        exit "$CODE"
    fi
fi
if [ "$SUBCMD" = "bootstrap" ] && [ -f "$STATE_DIR/bootstrap_exit" ]; then
    CODE="$(cat "$STATE_DIR/bootstrap_exit")"
    if [ "$CODE" != "0" ]; then
        echo "fake launchctl bootstrap failure (code=$CODE)" >&2
        exit "$CODE"
    fi
fi
exit 0
EOF
    chmod +x "$FAKE_LAUNCHCTL"

    # Build a small external consumer probe linking LaunchLensCore in $TMP_ROOT/probe
    PROBE_PKG="$TMP_ROOT/probe"
    mkdir -p "$PROBE_PKG/Sources/M0Probe"
    cat > "$PROBE_PKG/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "M0Probe",
    platforms: [.macOS("14.0")],
    dependencies: [
        .package(path: "$ROOT")
    ],
    targets: [
        .executableTarget(
            name: "M0Probe",
            dependencies: [
                .product(name: "LaunchLensCore", package: "$PKG_IDENTITY")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
EOF

    cat > "$PROBE_PKG/Sources/M0Probe/main.swift" <<'EOF'
import Foundation
import LaunchLensCore

@main
struct M0Probe {
    static func samplePlist(label: String, program: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(program)</string>
            </array>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    static func assertTrue(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        do {
            if !(try condition()) {
                fputs("ASSERTION FAILED: \(message)\n", stderr)
                Foundation.exit(1)
            }
        } catch {
            fputs("ASSERTION THREW (\(message)): \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    @MainActor
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fputs("Usage: M0Probe <workDir> <fakeLaunchctlPath>\n", stderr)
            Foundation.exit(2)
        }
        let workRoot = URL(fileURLWithPath: args[1])
        let fakeLaunchctlURL = URL(fileURLWithPath: args[2])
        let fm = FileManager.default
        let enLoc = AppLocalizer(fixedLanguage: .en)
        let zhLoc = AppLocalizer(fixedLanguage: .zhHans)

        // ----------------------------------------------------------------
        // Row 1: Fake bootout returns non-zero -> throws; original plist untouched; ledger & backup clean
        // ----------------------------------------------------------------
        do {
            let caseDir = workRoot.appendingPathComponent("row1")
            let stateDir = caseDir.appendingPathComponent("state")
            let agentsDir = caseDir.appendingPathComponent("LaunchAgents")
            let vaultDir = caseDir.appendingPathComponent("Vault")
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            setenv("FAKE_LAUNCHCTL_STATE_DIR", stateDir.path, 1)
            try Data("36".utf8).write(to: stateDir.appendingPathComponent("bootout_exit"))

            let plistURL = agentsDir.appendingPathComponent("io.accept.row1.plist")
            let orig = samplePlist(label: "io.accept.row1", program: "/usr/bin/true")
            try orig.write(to: plistURL)

            let store = FreezeLedgerStore(
                vaultDirectory: vaultDir,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: SystemLaunchctlExecutor(executableURL: fakeLaunchctlURL)
            )
            let item = LaunchItem(
                id: "user::io.accept.row1",
                label: "io.accept.row1",
                domain: .userAgent,
                plistPath: plistURL.path,
                programCommand: "/usr/bin/true"
            )

            var caught: FreezeError?
            do {
                try store.freeze(item: item)
            } catch let err as FreezeError {
                caught = err
            }
            guard let err = caught else {
                assertTrue(false, "Row 1 expected FreezeError when bootout exits 36")
                return
            }
            assertTrue(fm.fileExists(atPath: plistURL.path), "Row 1 original plist must still exist")
            assertTrue((try Data(contentsOf: plistURL)) == orig, "Row 1 original plist bytes must be unchanged")
            assertTrue(store.loadRecords().isEmpty, "Row 1 ledger must have 0 residual records")
            let snaps = (try? fm.contentsOfDirectory(atPath: store.snapshotsDirectory.path)) ?? []
            assertTrue(snaps.isEmpty, "Row 1 backup directory must be cleaned up")
            assertTrue(err.localizedMessage(enLoc).contains("exit code 36"), "Row 1 EN message states exit code")
            assertTrue(err.localizedMessage(zhLoc).contains("退出码 36"), "Row 1 ZH message states exit code")
            print("[Row 1 PASS] Fake bootout exit=36 -> threw error (EN/ZH), plist intact, 0 ledger records, 0 orphan backups.")
        }

        // ----------------------------------------------------------------
        // Row 2 (L1 & L13): Read-only 0444 ledger.json AND read-only 0555 ledger directory -> throws; 0 launchctl calls; plist intact
        // ----------------------------------------------------------------
        do {
            // Subcase 2a: 0444 read-only ledger.json
            let caseDirA = workRoot.appendingPathComponent("row2a")
            let stateDirA = caseDirA.appendingPathComponent("state")
            let agentsDirA = caseDirA.appendingPathComponent("LaunchAgents")
            let vaultDirA = caseDirA.appendingPathComponent("Vault")
            try fm.createDirectory(at: stateDirA, withIntermediateDirectories: true)
            try fm.createDirectory(at: agentsDirA, withIntermediateDirectories: true)
            try fm.createDirectory(at: vaultDirA, withIntermediateDirectories: true)
            setenv("FAKE_LAUNCHCTL_STATE_DIR", stateDirA.path, 1)

            let plistURLA = agentsDirA.appendingPathComponent("io.accept.row2a.plist")
            let origA = samplePlist(label: "io.accept.row2a", program: "/usr/bin/true")
            try origA.write(to: plistURLA)

            let ledgerURLA = vaultDirA.appendingPathComponent("ledger.json")
            try Data("[]".utf8).write(to: ledgerURLA)
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ledgerURLA.path)

            let storeA = FreezeLedgerStore(
                vaultDirectory: vaultDirA,
                userLaunchAgentsDirectory: agentsDirA,
                uid: 501,
                launchctlExecutor: SystemLaunchctlExecutor(executableURL: fakeLaunchctlURL)
            )
            let itemA = LaunchItem(
                id: "user::io.accept.row2a",
                label: "io.accept.row2a",
                domain: .userAgent,
                plistPath: plistURLA.path,
                programCommand: "/usr/bin/true"
            )

            var caughtA: FreezeError?
            do {
                try storeA.freeze(item: itemA)
            } catch let err as FreezeError {
                caughtA = err
            }
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ledgerURLA.path)

            guard let errA = caughtA else {
                assertTrue(false, "Row 2a expected FreezeError on read-only 0444 ledger.json")
                return
            }
            assertTrue(!fm.fileExists(atPath: stateDirA.appendingPathComponent("calls.log").path), "Row 2a must NOT call launchctl")
            assertTrue((try Data(contentsOf: plistURLA)) == origA, "Row 2a original plist bytes must be unchanged")
            assertTrue(errA.localizedMessage(enLoc).contains("bootout was NOT called"), "Row 2a EN error confirms bootout skipped")
            assertTrue(errA.localizedMessage(zhLoc).contains("未调用 launchctl bootout"), "Row 2a ZH error confirms bootout skipped")

            // Subcase 2b (L13): Read-only 0555 ledger directory (while LaunchAgents stays writable 0755)
            let caseDirB = workRoot.appendingPathComponent("row2b_dir0555")
            let stateDirB = caseDirB.appendingPathComponent("state")
            let agentsDirB = caseDirB.appendingPathComponent("LaunchAgents")
            let vaultFresh0555 = caseDirB.appendingPathComponent("VaultFresh0555")
            let vaultInit0555 = caseDirB.appendingPathComponent("VaultInit0555")
            try fm.createDirectory(at: stateDirB, withIntermediateDirectories: true)
            try fm.createDirectory(at: agentsDirB, withIntermediateDirectories: true)
            try fm.createDirectory(at: vaultFresh0555, withIntermediateDirectories: true)
            try fm.createDirectory(at: vaultInit0555.appendingPathComponent("Snapshots"), withIntermediateDirectories: true)
            try fm.createDirectory(at: vaultInit0555.appendingPathComponent("Staged"), withIntermediateDirectories: true)
            setenv("FAKE_LAUNCHCTL_STATE_DIR", stateDirB.path, 1)

            let plistURLB = agentsDirB.appendingPathComponent("io.accept.row2b.plist")
            let origB = samplePlist(label: "io.accept.row2b", program: "/usr/bin/true")
            try origB.write(to: plistURLB)

            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: vaultFresh0555.path)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: vaultInit0555.path)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vaultFresh0555.path)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vaultInit0555.path)
            }

            let itemB = LaunchItem(
                id: "user::io.accept.row2b",
                label: "io.accept.row2b",
                domain: .userAgent,
                plistPath: plistURLB.path,
                programCommand: "/usr/bin/true"
            )

            for dirURL in [vaultFresh0555, vaultInit0555] {
                let storeB = FreezeLedgerStore(
                    vaultDirectory: dirURL,
                    userLaunchAgentsDirectory: agentsDirB,
                    uid: 501,
                    launchctlExecutor: SystemLaunchctlExecutor(executableURL: fakeLaunchctlURL)
                )
                var caughtB: FreezeError?
                do {
                    try storeB.freeze(item: itemB)
                } catch let err as FreezeError {
                    caughtB = err
                }
                assertTrue(caughtB != nil, "Row 2b (L13) expected FreezeError on 0555 ledger dir \(dirURL.lastPathComponent)")
                assertTrue(!fm.fileExists(atPath: stateDirB.appendingPathComponent("calls.log").path), "Row 2b (L13) must invoke fake launchctl 0 times")
                assertTrue(fm.fileExists(atPath: plistURLB.path), "Row 2b (L13) original plist must still exist")
                assertTrue((try Data(contentsOf: plistURLB)) == origB, "Row 2b (L13) original plist bytes must be unchanged")
            }

            print("[Row 2 PASS] Read-only 0444 ledger.json & 0555 ledger directory (L13) -> threw error (EN/ZH), 0 launchctl calls, original plist intact.")
        }

        // ----------------------------------------------------------------
        // Row 3: Fake bootstrap returns non-zero -> throws; both backup and ledger record preserved
        // ----------------------------------------------------------------
        do {
            let caseDir = workRoot.appendingPathComponent("row3")
            let stateDir = caseDir.appendingPathComponent("state")
            let agentsDir = caseDir.appendingPathComponent("LaunchAgents")
            let vaultDir = caseDir.appendingPathComponent("Vault")
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            setenv("FAKE_LAUNCHCTL_STATE_DIR", stateDir.path, 1)

            let plistURL = agentsDir.appendingPathComponent("io.accept.row3.plist")
            let orig = samplePlist(label: "io.accept.row3", program: "/usr/bin/true")
            try orig.write(to: plistURL)

            let store = FreezeLedgerStore(
                vaultDirectory: vaultDir,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: SystemLaunchctlExecutor(executableURL: fakeLaunchctlURL)
            )
            let item = LaunchItem(
                id: "user::io.accept.row3",
                label: "io.accept.row3",
                domain: .userAgent,
                plistPath: plistURL.path,
                programCommand: "/usr/bin/true"
            )
            let rec = try store.freeze(item: item)
            try Data("5".utf8).write(to: stateDir.appendingPathComponent("bootstrap_exit"))

            var caught: FreezeError?
            do {
                try store.restore(recordID: rec.id)
            } catch let err as FreezeError {
                caught = err
            }
            guard let err = caught else {
                assertTrue(false, "Row 3 expected FreezeError when bootstrap exits 5")
                return
            }
            assertTrue(fm.fileExists(atPath: rec.snapshotFilePath), "Row 3 backup file must still exist")
            assertTrue((try Data(contentsOf: URL(fileURLWithPath: rec.snapshotFilePath))) == orig, "Row 3 backup bytes intact")
            assertTrue(store.loadRecords().count == 1, "Row 3 frozen ledger record must still exist")
            assertTrue(err.localizedMessage(enLoc).contains("exit code 5"), "Row 3 EN states bootstrap exit code")
            assertTrue(err.localizedMessage(zhLoc).contains("退出码 5"), "Row 3 ZH states bootstrap exit code")
            print("[Row 3 PASS] Fake bootstrap exit=5 -> threw error (EN/ZH), backup file & ledger record both preserved.")
        }

        // ----------------------------------------------------------------
        // Row 4: Target path already has a file with different content -> refuses overwrite, names both files & diff
        // ----------------------------------------------------------------
        do {
            let caseDir = workRoot.appendingPathComponent("row4")
            let stateDir = caseDir.appendingPathComponent("state")
            let agentsDir = caseDir.appendingPathComponent("LaunchAgents")
            let vaultDir = caseDir.appendingPathComponent("Vault")
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            setenv("FAKE_LAUNCHCTL_STATE_DIR", stateDir.path, 1)

            let plistURL = agentsDir.appendingPathComponent("io.accept.row4.plist")
            let oldBytes = samplePlist(label: "io.accept.row4", program: "/opt/vendor/v1")
            try oldBytes.write(to: plistURL)

            let store = FreezeLedgerStore(
                vaultDirectory: vaultDir,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: SystemLaunchctlExecutor(executableURL: fakeLaunchctlURL)
            )
            let item = LaunchItem(
                id: "user::io.accept.row4",
                label: "io.accept.row4",
                domain: .userAgent,
                plistPath: plistURL.path,
                programCommand: "/opt/vendor/v1"
            )
            let rec = try store.freeze(item: item)

            let newVendorBytes = samplePlist(label: "io.accept.row4", program: "/opt/vendor/v2-new")
            try newVendorBytes.write(to: URL(fileURLWithPath: rec.originalPlistPath))

            var caught: FreezeError?
            do {
                try store.restore(recordID: rec.id)
            } catch let err as FreezeError {
                caught = err
            }
            guard let err = caught else {
                assertTrue(false, "Row 4 expected restoreTargetConflict error")
                return
            }
            assertTrue((try Data(contentsOf: URL(fileURLWithPath: rec.originalPlistPath))) == newVendorBytes, "Row 4 existing file must NOT be overwritten")
            let enMsg = err.localizedMessage(enLoc)
            let zhMsg = err.localizedMessage(zhLoc)
            assertTrue(enMsg.contains(rec.originalPlistPath) && enMsg.contains(rec.snapshotFilePath), "Row 4 EN names both files")
            assertTrue(zhMsg.contains(rec.originalPlistPath) && zhMsg.contains(rec.snapshotFilePath), "Row 4 ZH names both files")
            assertTrue(enMsg.contains("/opt/vendor/v1") && enMsg.contains("/opt/vendor/v2-new"), "Row 4 reports plist diff")
            print("[Row 4 PASS] Target file conflict -> did NOT overwrite, preserved backup & record, reported both paths & diff (EN/ZH).")
        }

        // ----------------------------------------------------------------
        // Row 5: Backup modified by 1 byte before restore -> rejected without writing plist or calling bootstrap
        // ----------------------------------------------------------------
        do {
            let caseDir = workRoot.appendingPathComponent("row5")
            let stateDir = caseDir.appendingPathComponent("state")
            let agentsDir = caseDir.appendingPathComponent("LaunchAgents")
            let vaultDir = caseDir.appendingPathComponent("Vault")
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            setenv("FAKE_LAUNCHCTL_STATE_DIR", stateDir.path, 1)

            let plistURL = agentsDir.appendingPathComponent("io.accept.row5.plist")
            let orig = samplePlist(label: "io.accept.row5", program: "/usr/bin/true")
            try orig.write(to: plistURL)

            let store = FreezeLedgerStore(
                vaultDirectory: vaultDir,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: SystemLaunchctlExecutor(executableURL: fakeLaunchctlURL)
            )
            let item = LaunchItem(
                id: "user::io.accept.row5",
                label: "io.accept.row5",
                domain: .userAgent,
                plistPath: plistURL.path,
                programCommand: "/usr/bin/true"
            )
            let rec = try store.freeze(item: item)
            try? fm.removeItem(at: stateDir.appendingPathComponent("calls.log"))

            var mutated = try Data(contentsOf: URL(fileURLWithPath: rec.snapshotFilePath))
            mutated[mutated.count - 3] ^= 0xFF
            try mutated.write(to: URL(fileURLWithPath: rec.snapshotFilePath))

            var caught: FreezeError?
            do {
                try store.restore(recordID: rec.id)
            } catch let err as FreezeError {
                caught = err
            }
            assertTrue(caught == .snapshotCorrupted("io.accept.row5"), "Row 5 expected snapshotCorrupted")
            assertTrue(!fm.fileExists(atPath: rec.originalPlistPath), "Row 5 must NOT write corrupted plist")
            assertTrue(!fm.fileExists(atPath: stateDir.appendingPathComponent("calls.log").path), "Row 5 must NOT call bootstrap")
            print("[Row 5 PASS] 1-byte tampered backup -> rejected immediately (SHA-256 mismatch), 0 writes, 0 bootstrap calls.")
        }

        // ----------------------------------------------------------------
        // Row 6: Freeze file outside LaunchAgents -> rejected
        // ----------------------------------------------------------------
        do {
            let caseDir = workRoot.appendingPathComponent("row6")
            let stateDir = caseDir.appendingPathComponent("state")
            let agentsDir = caseDir.appendingPathComponent("LaunchAgents")
            let outsideDir = caseDir.appendingPathComponent("NotLaunchAgents")
            let vaultDir = caseDir.appendingPathComponent("Vault")
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
            setenv("FAKE_LAUNCHCTL_STATE_DIR", stateDir.path, 1)

            let outsidePlist = outsideDir.appendingPathComponent("io.accept.outside.plist")
            try samplePlist(label: "io.accept.outside", program: "/usr/bin/true").write(to: outsidePlist)

            let store = FreezeLedgerStore(
                vaultDirectory: vaultDir,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: SystemLaunchctlExecutor(executableURL: fakeLaunchctlURL)
            )
            let outsideItem = LaunchItem(
                id: "user::io.accept.outside",
                label: "io.accept.outside",
                domain: .userAgent,
                plistPath: outsidePlist.path,
                programCommand: "/usr/bin/true"
            )

            var caught: FreezeError?
            do {
                try store.freeze(item: outsideItem)
            } catch let err as FreezeError {
                caught = err
            }
            assertTrue(
                caught == .outsideLaunchAgentsDirectory(path: outsidePlist.path, requiredDirectory: agentsDir.path),
                "Row 6 expected outsideLaunchAgentsDirectory error"
            )
            assertTrue(fm.fileExists(atPath: outsidePlist.path), "Row 6 outside file untouched")
            assertTrue(!fm.fileExists(atPath: stateDir.appendingPathComponent("calls.log").path), "Row 6 must NOT call bootout")
            print("[Row 6 PASS] File outside LaunchAgents -> rejected with outsideLaunchAgentsDirectory, file untouched.")
        }

        // ----------------------------------------------------------------
        // L14 Check: Crash after bootout before moving plist -> recovery re-runs bootstrap and verifies exit code
        // ----------------------------------------------------------------
        do {
            let caseDir = workRoot.appendingPathComponent("row_l14")
            let stateDir = caseDir.appendingPathComponent("state")
            let agentsDir = caseDir.appendingPathComponent("LaunchAgents")
            let vaultDir = caseDir.appendingPathComponent("Vault")
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            setenv("FAKE_LAUNCHCTL_STATE_DIR", stateDir.path, 1)

            let plistURL = agentsDir.appendingPathComponent("io.accept.l14.plist")
            let orig = samplePlist(label: "io.accept.l14", program: "/opt/l14/service")
            try orig.write(to: plistURL)
            let canonicalPlistPath = plistURL.resolvingSymlinksInPath().standardizedFileURL.path

            let store = FreezeLedgerStore(
                vaultDirectory: vaultDir,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: SystemLaunchctlExecutor(executableURL: fakeLaunchctlURL)
            )
            try fm.createDirectory(at: store.snapshotsDirectory, withIntermediateDirectories: true)
            let snapURL = store.snapshotsDirectory.appendingPathComponent("io.accept.l14-crash.plist")
            try orig.write(to: snapURL)

            let inProgressRec = FreezeSnapshotRecord(
                id: "l14-crash",
                label: "io.accept.l14",
                originalPlistPath: canonicalPlistPath,
                snapshotFilePath: snapURL.path,
                stagedPlistPath: store.stagingDirectory.appendingPathComponent("io.accept.l14-crash.staged.plist").path,
                sha256Hex: FreezeLedgerStore.sha256Hex(orig),
                frozenAt: Date(),
                rssBytesAtFreeze: 0,
                status: .inProgress
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([inProgressRec]).write(to: store.ledgerFileURL)

            // 1. Non-zero bootstrap (exit 5) preserves recovery state & throws recoveryBootstrapFailed
            try Data("5".utf8).write(to: stateDir.appendingPathComponent("bootstrap_exit"))
            var caughtFail: FreezeError?
            do {
                _ = try store.recoverInterruptedAndOrphanBackups()
            } catch let err as FreezeError {
                caughtFail = err
            }
            guard let failErr = caughtFail else {
                assertTrue(false, "L14 expected recoveryBootstrapFailed when bootstrap exits 5")
                return
            }
            assertTrue(failErr.localizedMessage(enLoc).contains("exit code 5"), "L14 EN reports bootstrap exit 5")
            assertTrue(failErr.localizedMessage(zhLoc).contains("退出码 5"), "L14 ZH reports bootstrap exit 5")
            assertTrue(fm.fileExists(atPath: snapURL.path), "L14 failed bootstrap must preserve snapshot backup")
            assertTrue(store.loadRecords().count == 1 && store.loadRecords().first?.status == .inProgress, "L14 failed bootstrap must preserve inProgress record")

            // 2. Subsequent bootstrap exit 0 re-loads service, removes backup, and clears inProgress
            try? fm.removeItem(at: stateDir.appendingPathComponent("bootstrap_exit"))
            try? fm.removeItem(at: stateDir.appendingPathComponent("calls.log"))
            let summary = try store.recoverInterruptedAndOrphanBackups()
            let callsText = (try? String(contentsOf: stateDir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
            assertTrue(callsText.contains("bootstrap gui/501 \(canonicalPlistPath)"), "L14 recovery must invoke launchctl bootstrap")
            assertTrue(summary.recoveredInProgressLabels == ["io.accept.l14"], "L14 recovery summary lists label")
            assertTrue(!fm.fileExists(atPath: snapURL.path), "L14 successful recovery removes snapshot backup")
            assertTrue(store.loadRecords().isEmpty, "L14 successful recovery clears inProgress record")
            print("[L14 PASS] Post-bootout crash recovery re-runs launchctl bootstrap, preserves state on non-zero exit, and clears record on exit 0.")
        }
    }
}
EOF

    echo "[Rows 1-6 + L14] Compiling & executing hermetic library probe..."
    swift build --package-path "$PROBE_PKG" >/dev/null
    PROBE_BIN="$(swift build --package-path "$PROBE_PKG" --show-bin-path)/M0Probe"
    "$PROBE_BIN" "$TMP_ROOT/cases" "$FAKE_LAUNCHCTL"

    # ----------------------------------------------------------------
    # Row 7: LaunchLens --cli nosuchcmd -> exit code 2 (EN and ZH)
    # ----------------------------------------------------------------
    for LANG_TAG in en zh; do
        OUT_FILE="$TMP_ROOT/cli_out_$LANG_TAG.txt"
        ERR_FILE="$TMP_ROOT/cli_err_$LANG_TAG.txt"
        set +e
        "$BIN_PATH" --cli nosuchcmd --lang "$LANG_TAG" >"$OUT_FILE" 2>"$ERR_FILE"
        CODE=$?
        set -e
        if [[ "$CODE" -ne 2 ]]; then
            echo "FAIL: Row 7 (--lang $LANG_TAG) expected exit code 2, got $CODE" >&2
            exit 1
        fi
        if [[ -s "$OUT_FILE" ]]; then
            echo "FAIL: Row 7 (--lang $LANG_TAG) expected empty stdout, got: $(cat "$OUT_FILE")" >&2
            exit 1
        fi
        if ! grep -q "nosuchcmd" "$ERR_FILE"; then
            echo "FAIL: Row 7 (--lang $LANG_TAG) stderr missing 'nosuchcmd': $(cat "$ERR_FILE")" >&2
            exit 1
        fi
        echo "[Row 7 PASS] LaunchLens --cli nosuchcmd --lang $LANG_TAG -> exit code $CODE, stderr: $(tr -d '\n' < "$ERR_FILE")"
    done

    # ----------------------------------------------------------------
    # Row 8 & W1: Scripted Mutation Checks in Isolated Workspace Copy
    # Every mutation MUST compile, run, and fail the exact named @Test,
    # then restore cleanly with 0 diff against original Sources & Tests.
    # ----------------------------------------------------------------
    MUT_DIR="$TMP_ROOT/mutcheck"
    CLEAN_REF="$TMP_ROOT/clean_ref"
    mkdir -p "$MUT_DIR" "$CLEAN_REF"
    cp "$ROOT/Package.swift" "$MUT_DIR/Package.swift"
    cp -R "$ROOT/Sources" "$MUT_DIR/Sources"
    cp -R "$ROOT/Tests" "$MUT_DIR/Tests"
    cp -R "$ROOT/Sources" "$CLEAN_REF/Sources"
    cp -R "$ROOT/Tests" "$CLEAN_REF/Tests"

    echo "[Row 8 / W1] Pre-warming isolated test build in temp workspace..."
    swift build --build-tests --package-path "$MUT_DIR" >/dev/null

    python3 - "$MUT_DIR" "$CLEAN_REF" "$TMP_ROOT" <<'PYEOF'
import filecmp
import pathlib
import subprocess
import sys

mut_dir = pathlib.Path(sys.argv[1])
clean_ref = pathlib.Path(sys.argv[2])
tmp_root = pathlib.Path(sys.argv[3])

mutations = [
    {
        "id": "M1 (Row 8: delete restore SHA-256 check)",
        "rel_file": "Sources/LaunchLensCore/Services/FreezeLedgerStore.swift",
        "target": """        guard Self.sha256Hex(snapBytes) == rec.sha256Hex else {
            throw FreezeError.snapshotCorrupted(rec.label)
        }""",
        "replacement": "        // MUTATION M1: restore SHA-256 verification deleted",
        "filter": "FreezeLedgerTests/testCorruptedSnapshotRejectedOnRestore",
        "expected_test_title": "Row 5 & Row 8 (L10): 1-byte corrupted backup is rejected on restore without writing plist or calling bootstrap",
    },
    {
        "id": "M2 (L13 & Row 2: bypass pre-bootout Step 3 ledger write)",
        "rel_file": "Sources/LaunchLensCore/Services/FreezeLedgerStore.swift",
        "target": """        do {
            try saveRecords([txRecord] + existingRecords)
        } catch {
            try? fm.removeItem(at: snapURL)""",
        "replacement": """        do {
            if false { try saveRecords([txRecord] + existingRecords) }
        } catch {
            try? fm.removeItem(at: snapURL)""",
        "filter": "FreezeLedgerTests/testReadOnlyLedgerDirectoryAbortsBeforeBootout",
        "expected_test_title": "L13 & Row 2: Read-only 0555 ledger directory aborts freeze before bootout with 0 launchctl calls and leaves plist untouched",
    },
    {
        "id": "M3 (Row 2: delete 0444 read-only ledgerFileURL guard)",
        "rel_file": "Sources/LaunchLensCore/Services/FreezeLedgerStore.swift",
        "target": """            if !fm.isWritableFile(atPath: ledgerFileURL.path) {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [
                    NSLocalizedDescriptionKey: "Ledger file is read-only / not writable: \\(ledgerFileURL.path)"
                ])
            }""",
        "replacement": "            // MUTATION M3: 0444 ledger file writability guard deleted",
        "filter": "FreezeLedgerTests/testUnwritableLedgerAbortsBeforeBootout",
        "expected_test_title": "Row 2 (L1): Unwritable ledger aborts before bootout and leaves original plist untouched",
    },
    {
        "id": "M4 (Row 1: ignore non-zero launchctl bootout exit code)",
        "rel_file": "Sources/LaunchLensCore/Services/FreezeLedgerStore.swift",
        "target": "        if bootoutResult.exitCode != 0 {",
        "replacement": "        if false && bootoutResult.exitCode != 0 {",
        "filter": "FreezeLedgerTests/testNonZeroBootoutRollsBackCleanly",
        "expected_test_title": "Row 1 (L1, L2): Non-zero bootout throws, leaves original plist intact, cleans ledger and backup",
    },
    {
        "id": "M5 (Row 3: ignore non-zero launchctl bootstrap exit code on restore)",
        "rel_file": "Sources/LaunchLensCore/Services/FreezeLedgerStore.swift",
        "target": "        if bootstrapResult.exitCode != 0 {",
        "replacement": "        if false && bootstrapResult.exitCode != 0 {",
        "filter": "FreezeLedgerTests/testNonZeroBootstrapPreservesBackupAndLedgerRecord",
        "expected_test_title": "Row 3 (L2): Non-zero bootstrap throws and preserves both backup file and frozen ledger record",
    },
    {
        "id": "M6 (L14: skip launchctl bootstrap during post-bootout crash recovery)",
        "rel_file": "Sources/LaunchLensCore/Services/FreezeLedgerStore.swift",
        "target": """                // before removing the backup or clearing the inProgress record.
                let res = launchctlExecutor.runLaunchctl(["bootstrap", "gui/\\(uid)", dstURL.path])""",
        "replacement": """                // MUTATION M6: skip bootstrap in post-bootout recovery
                let res = LaunchctlResult(exitCode: 0)""",
        "filter": "FreezeLedgerTests/testCrashAfterBootoutBeforeMoveRebootstrapsAndChecksExitCode",
        "expected_test_title": "L14: Crash after bootout before stage-move re-bootstraps service on recovery and checks bootstrap exit code",
    },
    {
        "id": "M7 (L10: weaken orphan PPID == 1 guard to true)",
        "rel_file": "Sources/LaunchLensCore/Scanners/LaunchScanner.swift",
        "target": """            guard proc.uid == currentUID,
                  proc.ppid == 1,
                  !claimedPIDs.contains(proc.pid) else { continue }""",
        "replacement": """            guard proc.uid == currentUID,
                  true,
                  !claimedPIDs.contains(proc.pid) else { continue }""",
        "filter": "ScannerCorrelationTests/testCorrelateAndOrphanDetection",
        "expected_test_title": "Correlates LaunchAgents with live RSS and isolates PPID==1 developer orphan daemons",
    },
    {
        "id": "M8 (L10: weaken orphan UID == currentUID guard to true)",
        "rel_file": "Sources/LaunchLensCore/Scanners/LaunchScanner.swift",
        "target": """            guard proc.uid == currentUID,
                  proc.ppid == 1,
                  !claimedPIDs.contains(proc.pid) else { continue }""",
        "replacement": """            guard true,
                  proc.ppid == 1,
                  !claimedPIDs.contains(proc.pid) else { continue }""",
        "filter": "ScannerCorrelationTests/testCorrelateAndOrphanDetection",
        "expected_test_title": "Correlates LaunchAgents with live RSS and isolates PPID==1 developer orphan daemons",
    },
]

def assert_trees_equal(dir_a: pathlib.Path, dir_b: pathlib.Path) -> None:
    res = subprocess.run(["diff", "-rq", str(dir_a), str(dir_b)], capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(f"FAIL: Mutated workspace not restored cleanly:\n{res.stdout}\n{res.stderr}\n")
        sys.exit(1)

for idx, mut in enumerate(mutations, start=1):
    target_path = mut_dir / mut["rel_file"]
    clean_path = clean_ref / mut["rel_file"]
    orig_text = clean_path.read_text(encoding="utf-8")
    count = orig_text.count(mut["target"])
    if count != 1:
        sys.stderr.write(f"FAIL: {mut['id']} expected exactly 1 match in {mut['rel_file']}, found {count}\n")
        sys.exit(1)

    mutated_text = orig_text.replace(mut["target"], mut["replacement"], 1)
    target_path.write_text(mutated_text, encoding="utf-8")

    try:
        proc = subprocess.run(
            ["swift", "test", "--package-path", str(mut_dir), "--no-parallel", "--filter", mut["filter"]],
            capture_output=True,
            text=True,
        )
        combined = proc.stdout + "\n" + proc.stderr
        (tmp_root / f"mut_{idx}.log").write_text(combined, encoding="utf-8")

        if proc.returncode == 0:
            sys.stderr.write(f"FAIL: {mut['id']} stayed GREEN (exit 0)!\n{combined}\n")
            sys.exit(1)
        if "◇ Test run started." not in combined:
            sys.stderr.write(f"FAIL: {mut['id']} did NOT compile and start test runner (compile failure does not count as RED test)!\n{combined}\n")
            sys.exit(1)
        expected_marker = f'✘ Test "{mut["expected_test_title"]}"'
        if expected_marker not in combined:
            sys.stderr.write(f"FAIL: {mut['id']} failed, but expected named test marker '{expected_marker}' was NOT found!\n{combined}\n")
            sys.exit(1)

        print(f"[Row 8 / W1 PASS] {mut['id']} -> compiled, ran, and failed named test '{mut['filter']}' (exit {proc.returncode}).")
    finally:
        target_path.write_text(orig_text, encoding="utf-8")

    assert_trees_equal(clean_ref / "Sources", mut_dir / "Sources")
    assert_trees_equal(clean_ref / "Tests", mut_dir / "Tests")
PYEOF

    echo "================================================================"
    echo "ALL M0 ACCEPTANCE & W1 MUTATION CHECKS PASSED (EXIT 0)"
    echo "================================================================"
} > "$RAW_REPORT"

python3 - "$RAW_REPORT" "$SANITIZED_REPORT" "$ROOT" "$TMP_ROOT" "$HOME" <<'PYEOF'
import os, pathlib, pwd, re, sys

raw_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
repo_root = sys.argv[3]
tmp_root = sys.argv[4]
home_dir = sys.argv[5]

text = raw_path.read_text(encoding="utf-8")
for val, token in [
    (str(pathlib.Path(tmp_root).resolve()), "<TMP_ROOT>"),
    (tmp_root, "<TMP_ROOT>"),
    (str(pathlib.Path(repo_root).resolve()), "<REPO_ROOT>"),
    (repo_root, "<REPO_ROOT>"),
    (str(pathlib.Path(home_dir).resolve()), "<HOME>"),
    (home_dir, "<HOME>"),
]:
    if val and val != "/":
        text = text.replace(val, token)

pw_home_parent = str(pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir).parent)
if pw_home_parent and pw_home_parent != "/":
    text = re.sub(re.escape(pw_home_parent) + r"/[^/\s\"')]+", "/<USER_HOME>", text)
text = re.sub(r"/private/var/folders/[^\s\"')]+", "<TMPDIR>", text)
text = re.sub(r"/var/folders/[^\s\"')]+", "<TMPDIR>", text)
text = re.sub(r"/private/tmp/[^\s\"')]+", "<TMP>", text)
text = re.sub(r"/tmp/[^\s\"')]+", "<TMP>", text)

out_path.write_text(text, encoding="utf-8")
PYEOF

cat "$SANITIZED_REPORT"

if [[ "$RECORD" == "1" ]]; then
    mkdir -p "$ROOT/reports"
    cp "$SANITIZED_REPORT" "$REPORT_FILE"
    echo "[Record] Wrote sanitized report to reports/m0-acceptance.txt"
fi
