#!/usr/bin/env bash
set -euo pipefail

# Opt-in only: M1 Row 4 real launchd freeze/restore + mid-freeze kill recovery test.
# Never executed automatically unless the user explicitly sets LAUNCHLENS_REAL_LAUNCHD=1.
if [[ "${LAUNCHLENS_REAL_LAUNCHD:-0}" != "1" ]]; then
    echo "[Row 4 SKIPPED] Real launchd freeze/restore test is OFF by default (set LAUNCHLENS_REAL_LAUNCHD=1 to opt in): 没跑"
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

UID_NUM="$(id -u)"
USER_AGENTS_DIR="$(python3 -c 'import os, pwd; print(os.path.join(pwd.getpwuid(os.getuid()).pw_dir, "Library/LaunchAgents"))')"

if [[ ! -d "$USER_AGENTS_DIR" ]]; then
    echo "FAIL: User LaunchAgents directory does not exist: $USER_AGENTS_DIR" >&2
    exit 1
fi

RAND_SUFFIX="$(python3 -c 'import uuid; print(uuid.uuid4().hex[:10])')"
LABEL="io.launchlens.m1test.${RAND_SUFFIX}"
PLIST_PATH="$USER_AGENTS_DIR/${LABEL}.plist"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/launchlens-real-launchd.XXXXXX")"
TMP_VAULT="$TMP_ROOT/vault"
REF_PLIST="$TMP_ROOT/ref.plist"

cleanup() {
    /bin/launchctl bootout "gui/$UID_NUM" "$PLIST_PATH" >/dev/null 2>&1 || true
    /bin/launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
    rm -f "$PLIST_PATH"
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

echo "==> [Real launchd] Building LaunchLens executable..."
swift build --product LaunchLens >/dev/null
BIN_PATH="$(swift build --show-bin-path)/LaunchLens"

cat > "$REF_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sleep</string>
        <string>300</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

cp "$REF_PLIST" "$PLIST_PATH"

echo "==> [Real launchd 1/4] Bootstrapping temporary service $LABEL..."
/bin/launchctl bootstrap "gui/$UID_NUM" "$PLIST_PATH"
/bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null

echo "==> [Real launchd 2/4] Freezing $LABEL via LaunchLens CLI..."
"$BIN_PATH" --cli freeze "$LABEL" --ledger-dir "$TMP_VAULT" --lang en
set +e
/bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1
PRINT_AFTER_FREEZE=$?
set -e
if [[ "$PRINT_AFTER_FREEZE" -ne 113 ]]; then
    echo "FAIL: Expected launchctl print exit 113 after freeze, got $PRINT_AFTER_FREEZE" >&2
    exit 1
fi
if [[ -e "$PLIST_PATH" ]]; then
    echo "FAIL: Expected $PLIST_PATH to be moved out of LaunchAgents after freeze" >&2
    exit 1
fi

echo "==> [Real launchd 3/4] Restoring $LABEL via LaunchLens CLI..."
"$BIN_PATH" --cli restore "$LABEL" --ledger-dir "$TMP_VAULT" --lang en
/bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null
if ! cmp -s "$PLIST_PATH" "$REF_PLIST"; then
    echo "FAIL: Restored plist is not byte-identical to original!" >&2
    exit 1
fi

echo "==> [Real launchd 4/4] Testing mid-freeze SIGKILL crash + repair recovery..."
PKG_IDENTITY="$(basename "$(cd "$ROOT" && pwd)")"
CRASH_PKG="$TMP_ROOT/crash_probe"
mkdir -p "$CRASH_PKG/Sources/CrashProbe"
cat > "$CRASH_PKG/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrashProbe",
    platforms: [.macOS("14.0")],
    dependencies: [.package(path: "$ROOT")],
    targets: [
        .executableTarget(
            name: "CrashProbe",
            dependencies: [.product(name: "LaunchLensCore", package: "$PKG_IDENTITY")]
        )
    ],
    swiftLanguageModes: [.v5]
)
EOF

cat > "$CRASH_PKG/Sources/CrashProbe/main.swift" <<'EOF'
import Darwin
import Foundation
import LaunchLensCore

let args = CommandLine.arguments
guard args.count == 5 else {
    fputs("Usage: CrashProbe <vaultDir> <agentsDir> <label> <stepRaw>\n", stderr)
    exit(2)
}
let vaultURL = URL(fileURLWithPath: args[1])
let agentsURL = URL(fileURLWithPath: args[2])
let label = args[3]
guard let targetStep = FreezeStep(rawValue: args[4]) else {
    fputs("Invalid FreezeStep: \(args[4])\n", stderr)
    exit(2)
}

let plistURL = agentsURL.appendingPathComponent("\(label).plist")
let store = FreezeLedgerStore(
    vaultDirectory: vaultURL,
    userLaunchAgentsDirectory: agentsURL,
    stepHook: { step in
        if step == targetStep {
            kill(getpid(), SIGKILL)
        }
    }
)
let item = LaunchItem(
    id: "user::\(label)",
    label: label,
    domain: .userAgent,
    plistPath: plistURL.path,
    programCommand: "/bin/sleep 300"
)
_ = try store.freeze(item: item)
EOF

(cd "$CRASH_PKG" && swift build --product CrashProbe >/dev/null)
CRASH_BIN="$(cd "$CRASH_PKG" && swift build --show-bin-path)/CrashProbe"

for CRASH_STEP in afterBootout afterRemoveOriginalPlist; do
    set +e
    "$CRASH_BIN" "$TMP_VAULT" "$USER_AGENTS_DIR" "$LABEL" "$CRASH_STEP"
    KILL_STATUS=$?
    set -e
    if [[ "$KILL_STATUS" -eq 0 ]]; then
        echo "FAIL: CrashProbe unexpectedly exited 0 for step $CRASH_STEP" >&2
        exit 1
    fi
    "$BIN_PATH" --cli repair --ledger-dir "$TMP_VAULT" --lang en
    "$BIN_PATH" --cli audit --ledger-dir "$TMP_VAULT" --lang en
    /bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null
    if ! cmp -s "$PLIST_PATH" "$REF_PLIST"; then
        echo "FAIL: Plist not byte-identical after recovering from $CRASH_STEP" >&2
        exit 1
    fi
done

echo "==> [Real launchd] Cleaning up temporary service and verifying zero residue..."
/bin/launchctl bootout "gui/$UID_NUM" "$PLIST_PATH"
rm -f "$PLIST_PATH"
set +e
/bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1
FINAL_PRINT=$?
set -e
if [[ "$FINAL_PRINT" -ne 113 ]]; then
    echo "FAIL: Expected launchctl print exit 113 after cleanup, got $FINAL_PRINT" >&2
    exit 1
fi
if compgen -G "$USER_AGENTS_DIR/io.launchlens.m1test.*" >/dev/null; then
    echo "FAIL: Residual temporary test plist found in $USER_AGENTS_DIR" >&2
    exit 1
fi

echo "[Row 4 PASS] Real launchd freeze, restore, mid-freeze SIGKILL recovery, and zero-residue cleanup verified."
