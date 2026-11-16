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
            echo "Usage: Scripts/acceptance/m1-ledger.sh [--record]" >&2
            exit 2
            ;;
    esac
    shift
done

REPORT_FILE="$ROOT/reports/m1-ledger.txt"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/launchlens-m1-ledger.XXXXXX")"
SPAWNED_PIDS_FILE="$TMP_ROOT/spawned_pids.txt"
touch "$SPAWNED_PIDS_FILE"

kill_spawned_probes() {
    if [[ -f "$SPAWNED_PIDS_FILE" ]]; then
        while IFS= read -r spid; do
            if [[ -n "$spid" && "$spid" =~ ^[0-9]+$ ]]; then
                kill -9 "$spid" 2>/dev/null || true
            fi
        done < "$SPAWNED_PIDS_FILE"
    fi
}

cleanup() {
    local exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
        echo "[Diagnostic] m1-ledger.sh failed (exit=$exit_code); host uptime: $(/usr/bin/uptime 2>&1 || true)" >&2
    fi
    kill_spawned_probes
    chmod -R u+rwx "$TMP_ROOT" 2>/dev/null || true
    rm -rf "$TMP_ROOT"
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

RAW_REPORT="$TMP_ROOT/m1-ledger.raw.txt"
SANITIZED_REPORT="$TMP_ROOT/m1-ledger.sanitized.txt"
HOST_BEFORE="$TMP_ROOT/host_before.json"
HOST_AFTER="$TMP_ROOT/host_after.json"

snapshot_host_state() {
    local out_json="$1"
    python3 - "$out_json" <<'PYEOF'
import hashlib, json, os, pwd, sys

out_path = sys.argv[1]
pw_dir = pwd.getpwuid(os.getuid()).pw_dir
agents_dir = os.path.join(pw_dir, "Library/LaunchAgents")
vault_dir = os.path.join(pw_dir, "Library/Application Support/LaunchLens")

agents_entries = []
if os.path.isdir(agents_dir):
    for fn in sorted(os.listdir(agents_dir)):
        fp = os.path.join(agents_dir, fn)
        st = os.lstat(fp)
        digest = None
        if os.path.isfile(fp) and not os.path.islink(fp):
            with open(fp, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
        agents_entries.append({
            "name_sha256": hashlib.sha256(fn.encode("utf-8")).hexdigest(),
            "mode": st.st_mode,
            "size": st.st_size,
            "mtime_ns": st.st_mtime_ns,
            "sha256": digest,
        })

vault_entries = []
vault_exists = os.path.exists(vault_dir)
if vault_exists and os.path.isdir(vault_dir):
    for root_d, dirs, files in os.walk(vault_dir):
        dirs.sort()
        for fn in sorted(files):
            fp = os.path.join(root_d, fn)
            rel = os.path.relpath(fp, vault_dir)
            st = os.lstat(fp)
            vault_entries.append({
                "rel_sha256": hashlib.sha256(rel.encode("utf-8")).hexdigest(),
                "size": st.st_size,
                "mtime_ns": st.st_mtime_ns,
            })

with open(out_path, "w", encoding="utf-8") as f:
    json.dump({
        "agents_exists": os.path.isdir(agents_dir),
        "agents_count": len(agents_entries),
        "agents_entries": agents_entries,
        "vault_exists": vault_exists,
        "vault_entries": vault_entries,
    }, f, indent=2, sort_keys=True)
PYEOF
}

{
    echo "================================================================"
    echo "LaunchLens M1 Real-Environment Ledger & Orphan Verification Suite"
    echo "Date: $(date +%Y-%m-%d)"
    echo "================================================================"

    snapshot_host_state "$HOST_BEFORE"
    BEFORE_COUNT="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["agents_count"])' "$HOST_BEFORE")"
    echo "[Setup] Captured read-only pre-run host LaunchAgents snapshot (files=$BEFORE_COUNT, 0 private labels logged)."

    echo "[Setup] Building LaunchLens CLI binary (headless, zero GUI)..."
    swift build --product LaunchLens >/dev/null
    BIN_PATH="$(swift build --show-bin-path)/LaunchLens"
    if [[ ! -x "$BIN_PATH" ]]; then
        echo "FAIL: Built LaunchLens executable not found at $BIN_PATH" >&2
        exit 1
    fi

    NODE_BIN="$(command -v node || true)"
    if [[ -z "$NODE_BIN" ]]; then
        for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
            if [[ -x "$candidate" ]]; then
                NODE_BIN="$candidate"
                break
            fi
        done
    fi
    if [[ -z "$NODE_BIN" ]]; then
        echo "FAIL: 'node' runtime not found in PATH or standard Homebrew locations." >&2
        exit 1
    fi

    echo ""
    echo "--- [Live Ledger Cross-Check: launchctl + ps + lsof + Orphan Injection] ---"

    python3 - "$BIN_PATH" "$NODE_BIN" "$TMP_ROOT" "$SPAWNED_PIDS_FILE" "$ROOT/Scripts/acceptance/m1_ledger_ref.py" <<'PYEOF'
from __future__ import annotations
import json
import os
import pathlib
import pwd
import signal
import subprocess
import sys
import time

bin_path = sys.argv[1]
node_bin = sys.argv[2]
tmp_root = pathlib.Path(sys.argv[3])
spawned_pids_file = pathlib.Path(sys.argv[4])
ref_verifier_py = sys.argv[5]

def record_pid(pid: int) -> None:
    with spawned_pids_file.open("a", encoding="utf-8") as f:
        f.write(f"{pid}\n")

# 1. Prepare temporary scripts:
#    (a) Detached orphan node TCP listener (ppid == 1)
#    (b) Detached orphan python3 TCP listener (ppid == 1)
#    (c) Live-parent child process running node_modules/.bin/live_parent_worker.js (ppid > 1)
orphan_node_js = tmp_root / "m1_orphan_node_probe.js"
orphan_node_info = tmp_root / "orphan_node.json"
orphan_node_js.write_text(
    """const net = require('net');
const fs = require('fs');
const infoPath = process.argv[2];
const srv = net.createServer(() => {});
srv.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(infoPath, JSON.stringify({ pid: process.pid, port: srv.address().port }));
});
setInterval(() => {}, 10000);
""",
    encoding="utf-8",
)

orphan_py_script = tmp_root / "m1_orphan_py_probe.py"
orphan_py_info = tmp_root / "orphan_py.json"
orphan_py_script.write_text(
    """import json, os, socket, sys, time
info_path = sys.argv[1]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(5)
port = s.getsockname()[1]
with open(info_path, "w", encoding="utf-8") as f:
    json.dump({"pid": os.getpid(), "port": port}, f)
time.sleep(300)
""",
    encoding="utf-8",
)

nm_bin_dir = tmp_root / "node_modules" / ".bin"
nm_bin_dir.mkdir(parents=True, exist_ok=True)
live_worker_js = nm_bin_dir / "live_parent_worker.js"
live_worker_info = tmp_root / "live_worker.json"
live_worker_js.write_text(
    """const net = require('net');
const fs = require('fs');
const infoPath = process.argv[2];
const srv = net.createServer(() => {});
srv.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(infoPath, JSON.stringify({ pid: process.pid, ppid: process.ppid, port: srv.address().port }));
});
setInterval(() => {}, 10000);
""",
    encoding="utf-8",
)

def spawn_detached(cmd: list[str]) -> None:
    # Double-fork via short-lived python helper so child is immediately reparented to PID 1 (launchd)
    launcher = (
        "import subprocess, sys; "
        "subprocess.Popen(sys.argv[1:], start_new_session=True, "
        "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)"
    )
    subprocess.run([sys.executable, "-c", launcher, *cmd], check=True)

spawn_detached([node_bin, str(orphan_node_js), str(orphan_node_info)])
spawn_detached([sys.executable, str(orphan_py_script), str(orphan_py_info)])

# Spawn a dedicated live parent process (ppid > 1) that keeps live_parent_worker.js alive as its direct child
parent_holder = subprocess.Popen(
    [
        sys.executable,
        "-c",
        "import subprocess, sys, time; "
        "p = subprocess.Popen([sys.argv[1], sys.argv[2], sys.argv[3]], "
        "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
        "time.sleep(300)",
        node_bin,
        str(live_worker_js),
        str(live_worker_info),
    ],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
record_pid(parent_holder.pid)

deadline = time.time() + 8.0
while time.time() < deadline:
    if orphan_node_info.exists() and orphan_py_info.exists() and live_worker_info.exists():
        try:
            n_meta = json.loads(orphan_node_info.read_text(encoding="utf-8"))
            p_meta = json.loads(orphan_py_info.read_text(encoding="utf-8"))
            w_meta = json.loads(live_worker_info.read_text(encoding="utf-8"))
            break
        except Exception:
            pass
    time.sleep(0.05)
else:
    raise RuntimeError("Timed out waiting for temporary orphan/control listener probes to start")

node_pid, node_port = int(n_meta["pid"]), int(n_meta["port"])
py_pid, py_port = int(p_meta["pid"]), int(p_meta["port"])
live_child_pid, live_child_ppid, live_child_port = int(w_meta["pid"]), int(w_meta["ppid"]), int(w_meta["port"])

record_pid(node_pid)
record_pid(py_pid)
record_pid(live_child_pid)

# Wait briefly until kernel reparents both detached probes to PID 1
reparent_deadline = time.time() + 3.0
while time.time() < reparent_deadline:
    ps_check = subprocess.check_output(["/bin/ps", "-o", "pid=,ppid=", "-p", f"{node_pid},{py_pid}"], text=True)
    ppids = {}
    for ln in ps_check.splitlines():
        parts = ln.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            ppids[int(parts[0])] = int(parts[1])
    if ppids.get(node_pid) == 1 and ppids.get(py_pid) == 1:
        break
    time.sleep(0.05)

# 2. Run width-capped (<=25%, up to 3 retries) bracketed before -> LaunchLens -> after verification (LR1 & LR2)
empty_vault = tmp_root / "empty_vault"
user_agents_dir = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, "Library/LaunchAgents")

try:
    verify_res = subprocess.run(
        [
            sys.executable,
            ref_verifier_py,
            "--live-capture",
            "--bin-path", str(bin_path),
            "--ledger-dir", str(empty_vault),
            "--work-dir", str(tmp_root),
            "--max-retries", "3",
            "--user-agents-dir", user_agents_dir,
            "--current-uid", str(os.getuid()),
            "--node-pid", str(node_pid),
            "--node-port", str(node_port),
            "--py-pid", str(py_pid),
            "--py-port", str(py_port),
            "--live-child-pid", str(live_child_pid),
            "--live-child-ppid", str(live_child_ppid),
            "--live-child-port", str(live_child_port),
        ],
        check=False,
    )
finally:
    # 3. Always tear down all spawned test processes immediately after verification
    for pid in (live_child_pid, parent_holder.pid, node_pid, py_pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        parent_holder.wait(timeout=2.0)
    except Exception:
        pass

# Verify zero residual probe processes
time.sleep(0.1)
for pid in (node_pid, py_pid, live_child_pid, parent_holder.pid):
    rc = subprocess.call(["/bin/ps", "-p", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if rc == 0:
        raise RuntimeError(f"Residual spawned test process still alive: PID {pid}")

if verify_res.returncode != 0:
    sys.exit(verify_res.returncode)
PYEOF

    echo ""
    echo "--- [Row 4: Opt-In Real launchd Freeze/Restore & Mid-Freeze Kill Check] ---"
    if [[ "${LAUNCHLENS_REAL_LAUNCHD:-0}" == "1" ]]; then
        "$ROOT/Scripts/acceptance/m1-real-launchd.sh"
        echo "[M1 Row 4 PASS] LAUNCHLENS_REAL_LAUNCHD=1 real launchd freeze/restore + SIGKILL recovery passed."
    else
        echo "[M1 Row 4 SKIPPED] Real launchd freeze/restore + mid-freeze SIGKILL recovery (LAUNCHLENS_REAL_LAUNCHD!=1): 没跑"
    fi

    echo ""
    echo "--- [Isolated Temporary Code Mutation Checks (M1 + L20: 8/8)] ---"
    MUT_WS="$TMP_ROOT/mut_ws"
    mkdir -p "$MUT_WS"
    cp "$ROOT/Package.swift" "$MUT_WS/Package.swift"
    cp -R "$ROOT/Sources" "$MUT_WS/Sources"
    cp -R "$ROOT/Tests" "$MUT_WS/Tests"

    echo "[Mutation Setup] Building baseline isolated workspace in $MUT_WS..."
    (cd "$MUT_WS" && swift build --build-tests >/dev/null 2>&1)

    run_mutation_check() {
        local mut_id="$1"
        local rel_file="$2"
        local test_filter="$3"
        local py_mutator="$4"

        local target_file="$MUT_WS/$rel_file"
        local orig_file="$ROOT/$rel_file"
        cp "$orig_file" "$target_file"

        python3 -c "$py_mutator" "$target_file"

        if cmp -s "$orig_file" "$target_file"; then
            echo "FAIL: Mutation $mut_id did NOT modify $rel_file!" >&2
            exit 1
        fi

        if ! (cd "$MUT_WS" && swift build --build-tests >/dev/null 2>&1); then
            echo "FAIL: Mutation $mut_id failed to compile (must be a valid behavioral mutation)!" >&2
            cp "$orig_file" "$target_file"
            exit 1
        fi

        set +e
        (cd "$MUT_WS" && swift test --no-parallel --filter "$test_filter" >/dev/null 2>&1)
        local test_rc=$?
        set -e

        cp "$orig_file" "$target_file"
        if ! diff -rq "$ROOT/Sources" "$MUT_WS/Sources" >/dev/null; then
            echo "FAIL: Failed to restore clean Sources after $mut_id!" >&2
            exit 1
        fi

        if [[ "$test_rc" -eq 0 ]]; then
            echo "FAIL: Mutation $mut_id SURVIVED ($test_filter stayed GREEN)!" >&2
            exit 1
        fi

        echo "[Mutation $mut_id PASS] Killed by $test_filter (swift test exit=$test_rc, workspace restored)."
    }

    run_mutation_check \
        "M1_L4_PYTHON_APP" \
        "Sources/LaunchLensCore/Scanners/LaunchScanner.swift" \
        "ScannerCorrelationTests/testM1OrphanPythonAppVsGenuineGUIAppExclusion" \
        'import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "return appSegments.contains { !cliFrameworkInterpreterBundles.contains($0) }"
new = "return !appSegments.isEmpty"
assert old in s, "target not found"
p.write_text(s.replace(old, new, 1))'

    run_mutation_check \
        "M1_L5_EXACT_BASENAME" \
        "Sources/LaunchLensCore/Scanners/LaunchScanner.swift" \
        "ScannerCorrelationTests/testM1OrphanExactBasenameAndInterpreterScriptClassification" \
        'import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "return exactDevDaemonBasenames.contains(procInv.executableBasename)"
new = "return exactDevDaemonBasenames.contains(where: { procInv.executablePath.lowercased().contains($0) }) || procInv.executablePath.lowercased().contains(\"python\")"
assert old in s, "target not found"
p.write_text(s.replace(old, new, 1))'

    run_mutation_check \
        "M1_L5_INTERPRETER_TARGET" \
        "Sources/LaunchLensCore/Scanners/LaunchScanner.swift" \
        "ScannerCorrelationTests/testM1OrphanExactBasenameAndInterpreterScriptClassification" \
        'import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = """        case let (.scriptingRuntime(pFam), .scriptingRuntime(cFam)):
            guard pFam == cFam,
                  let pTarget = plistInv.target.identityKey,
                  let cTarget = procInv.target.identityKey else {
                return false
            }
            return pTarget == cTarget"""
new = """        case let (.scriptingRuntime(pFam), .scriptingRuntime(cFam)):
            return pFam == cFam"""
assert old in s, "target not found"
p.write_text(s.replace(old, new, 1))'

    run_mutation_check \
        "M1_L7_DESCENDANT_RSS" \
        "Sources/LaunchLensCore/Scanners/LaunchScanner.swift" \
        "ScannerCorrelationTests/testM1ServiceDescendantTreeRSSDeduplicationAndSystemDaemonProgramMatch" \
        'import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "let treePIDs = collectProcessTreePIDs(roots: roots, childrenByPPID: childrenByPPID)"
new = "let treePIDs = roots.filter { $0 > 0 }"
assert old in s, "target not found"
p.write_text(s.replace(old, new, 1))'

    run_mutation_check \
        "M1_L20_PRELEDGER_BACKUP" \
        "Sources/LaunchLensCore/Services/FreezeLedgerStore.swift" \
        "FreezeLedgerTests/testL20MidFreezeStepInjectionCrashAndRecoveryAtEveryStep" \
        'import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "if let activePlistURL = findByteMatchingPlistInLaunchAgents(inferredLabel: inferredLabel, digest: digest) {"
new = "if false, let activePlistURL = findByteMatchingPlistInLaunchAgents(inferredLabel: inferredLabel, digest: digest) {"
assert old in s, "target not found"
p.write_text(s.replace(old, new, 1))'

    run_mutation_check \
        "M1_L20_PREFLIGHT_ANCESTOR" \
        "Sources/LaunchLensCore/Services/FreezeLedgerStore.swift" \
        "FreezeLedgerTests/testL20PreflightAncestorDirectoryWritability" \
        'import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "if !fm.isWritableFile(atPath: ancestor.path) {"
new = "if false && !fm.isWritableFile(atPath: ancestor.path) {"
assert old in s, "target not found"
p.write_text(s.replace(old, new, 1))'

    run_mutation_check \
        "M1_L20_PREFLIGHT_SUBDIR" \
        "Sources/LaunchLensCore/Services/FreezeLedgerStore.swift" \
        "FreezeLedgerTests/testL20PreflightSubdirectoryWritability" \
        'import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "if requireSubdirectoriesWritable {"
new = "if false && requireSubdirectoriesWritable {"
assert old in s, "target not found"
p.write_text(s.replace(old, new, 1))'

    run_mutation_check \
        "M1_L20_PRINT_EXITCODE" \
        "Sources/LaunchLensCore/Services/FreezeLedgerStore.swift" \
        "FreezeLedgerTests/testL20UnexpectedLaunchctlPrintFailurePreservesStateWithoutBootstrapping" \
        'import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "} else if printRes.exitCode == 113 {"
new = "} else if printRes.exitCode != 0 {"
assert old in s, "target not found"
p.write_text(s.replace(old, new))'

    echo ""
    echo "--- [Host Read-Only Non-Mutation Verification] ---"
    snapshot_host_state "$HOST_AFTER"
    if ! cmp -s "$HOST_BEFORE" "$HOST_AFTER"; then
        echo "FAIL: Host ~/Library/LaunchAgents or Application Support/LaunchLens mutated during m1-ledger.sh!" >&2
        diff -u "$HOST_BEFORE" "$HOST_AFTER" >&2 || true
        exit 1
    fi
    echo "[Host Guard PASS] ~/Library/LaunchAgents ($BEFORE_COUNT files) and vault state 100% unchanged (sha256 + mtime_ns verified)."

    echo "================================================================"
    echo "M1 LEDGER VERIFICATION COMPLETED (EXECUTED CHECKS PASSED; SKIPPED CHECKS SEPARATE)"
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

passed = len(re.findall(r'^\[.*PASS\]', text, flags=re.MULTILINE))
skipped = len(re.findall(r'^\[.*SKIPPED\]', text, flags=re.MULTILINE))
text += f"[M1 Summary] passed={passed} failed=0 skipped={skipped}\n"

mac_home_prefix = "/" + "Users" + "/"
if mac_home_prefix in text:
    raise RuntimeError("Privacy violation: macOS home path prefix leaked into sanitized m1-ledger output!")

out_path.write_text(text, encoding="utf-8")
PYEOF

if [[ "$RECORD" == "1" ]]; then
    mkdir -p "$(dirname "$REPORT_FILE")"
    cp "$SANITIZED_REPORT" "$REPORT_FILE"
fi

cat "$SANITIZED_REPORT"
