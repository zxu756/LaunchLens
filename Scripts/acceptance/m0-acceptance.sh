#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

mkdir -p "$ROOT/reports"
REPORT_FILE="$ROOT/reports/m0-acceptance.txt"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/launchlens-m0-accept.XXXXXX")"
cleanup() {
    chmod -R u+rwx "$TMP_ROOT" 2>/dev/null || true
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

{
    echo "================================================================"
    echo "LaunchLens M0 Acceptance Suite (Hermetic Temp Dir + Fake launchctl)"
    echo "================================================================"

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
                .product(name: "LaunchLensCore", package: "LaunchLens")
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
        // Row 2: Unwritable ledger file -> throws; bootout NOT called; original plist unchanged
        // ----------------------------------------------------------------
        do {
            let caseDir = workRoot.appendingPathComponent("row2")
            let stateDir = caseDir.appendingPathComponent("state")
            let agentsDir = caseDir.appendingPathComponent("LaunchAgents")
            let vaultDir = caseDir.appendingPathComponent("Vault")
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)
            setenv("FAKE_LAUNCHCTL_STATE_DIR", stateDir.path, 1)

            let plistURL = agentsDir.appendingPathComponent("io.accept.row2.plist")
            let orig = samplePlist(label: "io.accept.row2", program: "/usr/bin/true")
            try orig.write(to: plistURL)

            let ledgerURL = vaultDir.appendingPathComponent("ledger.json")
            try Data("[]".utf8).write(to: ledgerURL)
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ledgerURL.path)

            let store = FreezeLedgerStore(
                vaultDirectory: vaultDir,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: SystemLaunchctlExecutor(executableURL: fakeLaunchctlURL)
            )
            let item = LaunchItem(
                id: "user::io.accept.row2",
                label: "io.accept.row2",
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
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ledgerURL.path)

            guard let err = caught else {
                assertTrue(false, "Row 2 expected FreezeError on read-only ledger.json")
                return
            }
            let callsLog = stateDir.appendingPathComponent("calls.log")
            assertTrue(!fm.fileExists(atPath: callsLog.path), "Row 2 must NOT call launchctl bootout")
            assertTrue(fm.fileExists(atPath: plistURL.path), "Row 2 original plist must remain in place")
            assertTrue((try Data(contentsOf: plistURL)) == orig, "Row 2 original plist bytes must be unchanged")
            assertTrue(err.localizedMessage(enLoc).contains("bootout was NOT called"), "Row 2 EN error confirms bootout skipped")
            assertTrue(err.localizedMessage(zhLoc).contains("未调用 launchctl bootout"), "Row 2 ZH error confirms bootout skipped")
            print("[Row 2 PASS] Read-only ledger.json -> threw error (EN/ZH), 0 launchctl calls, original plist intact.")
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
        // Row 6: Freeze file outside LaunchAgents (plus symlink) -> rejected
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
    }
}
EOF

    echo "[Rows 1-6] Compiling & executing hermetic library probe..."
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
    # Row 8: Delete SHA-256 check in restore inside isolated copy -> test turns RED
    # ----------------------------------------------------------------
    MUT_DIR="$TMP_ROOT/mutcheck"
    mkdir -p "$MUT_DIR"
    cp "$ROOT/Package.swift" "$MUT_DIR/Package.swift"
    cp -R "$ROOT/Sources" "$MUT_DIR/Sources"
    cp -R "$ROOT/Tests" "$MUT_DIR/Tests"

    python3 - "$MUT_DIR/Sources/LaunchLensCore/Services/FreezeLedgerStore.swift" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
target = """        guard Self.sha256Hex(snapBytes) == rec.sha256Hex else {
            throw FreezeError.snapshotCorrupted(rec.label)
        }"""
assert target in src, "Expected SHA-256 guard in FreezeLedgerStore.restore"
p.write_text(src.replace(target, "        // MUTATION: SHA-256 verification deleted"), encoding="utf-8")
PYEOF

    set +e
    swift test --package-path "$MUT_DIR" --no-parallel --filter "FreezeLedgerTests/testCorruptedSnapshotRejectedOnRestore" >"$TMP_ROOT/mut.log" 2>&1
    MUT_CODE=$?
    set -e
    if [[ "$MUT_CODE" -eq 0 ]]; then
        echo "FAIL: Row 8 mutation check stayed GREEN (exit 0) when SHA-256 verification was deleted!" >&2
        cat "$TMP_ROOT/mut.log" >&2
        exit 1
    fi
    echo "[Row 8 PASS] Deleting SHA-256 verification in restore turned FreezeLedgerTests/testCorruptedSnapshotRejectedOnRestore RED (exit code $MUT_CODE)."

    echo "================================================================"
    echo "ALL 8 M0 ACCEPTANCE TABLE CHECKS PASSED (EXIT 0)"
    echo "================================================================"
} | tee "$REPORT_FILE"
