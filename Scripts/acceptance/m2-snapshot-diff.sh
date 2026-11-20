#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

RECORD="${LAUNCHLENS_RECORD:-0}"
MUTATION_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --record)
            RECORD=1
            ;;
        --mutation)
            if [[ $# -lt 2 ]]; then
                echo "Error: --mutation requires 1, 2, 3, or all" >&2
                exit 2
            fi
            MUTATION_ID="$2"
            shift 2
            continue
            ;;
        --mutation=*)
            MUTATION_ID="${1#--mutation=}"
            ;;
        *)
            echo "Usage: Scripts/acceptance/m2-snapshot-diff.sh [--record] [--mutation <1|2|3|all>]" >&2
            exit 2
            ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Optional Mutation Verification Mode (Acceptance Row 7)
# ---------------------------------------------------------------------------
run_single_mutation() {
    local mut_num="$1"
    local mut_name=""
    local rel_file=""
    local py_patch=""

    case "$mut_num" in
        1)
            mut_name="M2_MUT1_SERVICE_KEY_INCLUDES_PID"
            rel_file="Sources/LaunchLensCore/Services/SessionSnapshotDiffer.swift"
            py_patch='import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "return \"\\(entry.domainScope.rawValue)::\\(entry.label)::\\(canonicalPlist)\""
new = "return \"\\(entry.domainScope.rawValue)::\\(entry.label)::\\(canonicalPlist)::\\(entry.pid ?? -1)\""
assert old in s, f"Mutation 1 target not found in {p}"
p.write_text(s.replace(old, new, 1), encoding="utf-8")'
            ;;
        2)
            mut_name="M2_MUT2_DISABLE_LISTENER_ORPHAN_DEDUP"
            rel_file="Sources/LaunchLensCore/Scanners/SessionSnapshotCollector.swift"
            py_patch='import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "if includedListenerPIDs.contains(proc.pid) || !treePIDs.isDisjoint(with: includedListenerPIDs) {"
new = "if false && (includedListenerPIDs.contains(proc.pid) || !treePIDs.isDisjoint(with: includedListenerPIDs)) {"
assert old in s, f"Mutation 2 target not found in {p}"
p.write_text(s.replace(old, new, 1), encoding="utf-8")'
            ;;
        3)
            mut_name="M2_MUT3_DROP_LSTART_FROM_ORPHAN_KEY"
            rel_file="Sources/LaunchLensCore/Models/SessionSnapshotModels.swift"
            py_patch='import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "\"pid=\\(pid)|lstart=\\(lstart)|exe=\\(executable)\""
new = "\"pid=\\(pid)|exe=\\(executable)\""
assert old in s, f"Mutation 3 target not found in {p}"
p.write_text(s.replace(old, new, 1), encoding="utf-8")'
            ;;
        *)
            echo "Error: Unknown mutation '$mut_num' (expected 1, 2, 3, or all)" >&2
            exit 2
            ;;
    esac

    local target_abs="$ROOT/$rel_file"
    local mut_tmp
    mut_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ll-m2-mut.XXXXXX")"
    local backup_file="$mut_tmp/original.swift"
    cp "$target_abs" "$backup_file"
    local orig_sha
    orig_sha="$(shasum -a 256 "$backup_file" | awk '{print $1}')"

    restore_mutated_file() {
        if [[ -f "$backup_file" ]]; then
            cp "$backup_file" "$target_abs"
            swift build --product LaunchLens >/dev/null 2>&1 || true
        fi
        rm -rf "$mut_tmp"
    }
    trap restore_mutated_file EXIT INT TERM

    echo "==> [Mutation $mut_num: $mut_name] Applying single-point mutation to $rel_file..."
    python3 -c "$py_patch" "$target_abs"

    set +e
    "$ROOT/Scripts/test.sh" scope Snapshot >"$mut_tmp/row1.log" 2>&1
    local row1_rc=$?
    "$ROOT/Scripts/acceptance/m2-snapshot-diff.sh" >"$mut_tmp/row3.log" 2>&1
    local row3_rc=$?
    set -e

    cp "$backup_file" "$target_abs"
    local restored_sha
    restored_sha="$(shasum -a 256 "$target_abs" | awk '{print $1}')"
    if [[ "$restored_sha" != "$orig_sha" ]]; then
        echo "FAIL: SHA-256 mismatch restoring $rel_file after $mut_name!" >&2
        exit 1
    fi
    if ! git diff --quiet -- "$rel_file"; then
        echo "FAIL: git diff not clean on $rel_file after restoring $mut_name!" >&2
        exit 1
    fi

    echo "==> [Mutation $mut_num: $mut_name] Rebuilding clean LaunchLens binary after restore..."
    swift build --product LaunchLens >/dev/null

    local row1_fail_line=""
    local row3_fail_line=""
    row1_fail_line="$(grep -E '✘ Test |FAIL:' "$mut_tmp/row1.log" | head -n 2 | tr '\n' ' ' || true)"
    row3_fail_line="$(grep -E '^FAIL ' "$mut_tmp/row3.log" | head -n 2 | tr '\n' ' ' || true)"

    trap - EXIT INT TERM
    rm -rf "$mut_tmp"

    local row3_killed=0
    if [[ "${LAUNCHLENS_REAL_LAUNCHD:-0}" == "1" && "$row3_rc" -ne 0 ]]; then
        row3_killed=1
    fi

    if [[ "$row1_rc" -eq 0 && "$row3_killed" -eq 0 ]]; then
        echo "FAIL: Mutation $mut_num ($mut_name) SURVIVED (Row 1 exit=$row1_rc, Row 3 exit=$row3_rc)!" >&2
        exit 1
    fi

    [[ -n "$row1_fail_line" ]] && echo "    Row 1 failure detail: $row1_fail_line"
    [[ -n "$row3_fail_line" ]] && echo "    Row 3 failure detail: $row3_fail_line"
    echo "[M2 Row 7 Mutation $mut_num PASS] $mut_name killed (row1_unit_exit=$row1_rc, row3_script_exit=$row3_rc, real_launchd=${LAUNCHLENS_REAL_LAUNCHD:-0}; $rel_file restored & clean)."
}

if [[ -n "$MUTATION_ID" ]]; then
    if [[ "$MUTATION_ID" == "all" ]]; then
        for m in 1 2 3; do
            run_single_mutation "$m"
        done
    else
        run_single_mutation "$MUTATION_ID"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Gate on LAUNCHLENS_REAL_LAUNCHD=1 (Acceptance Row 3 & Row 8)
# ---------------------------------------------------------------------------
if [[ "${LAUNCHLENS_REAL_LAUNCHD:-0}" != "1" ]]; then
    echo "[M2 Row 3 SKIPPED] Real launchd fake-agent snapshot/diff round-trip is OFF by default (set LAUNCHLENS_REAL_LAUNCHD=1): 没跑"
    echo "[M2 Row 6 SKIPPED] Live fake-orphan sensitive argument redaction check is OFF by default (set LAUNCHLENS_REAL_LAUNCHD=1): 没跑"
    echo "[M2 Row 9 SKIPPED] Live host LaunchAgents & zero-residue round-trip check is OFF by default (set LAUNCHLENS_REAL_LAUNCHD=1): 没跑"
    exit 2
fi

UID_NUM="$(id -u)"
SCRIPT_PID="$$"
REPORT_FILE="$ROOT/reports/m2-snapshot-diff.txt"

make_clean_tmpdir() {
    local prefix="$1"
    python3 - "$prefix" <<'PYEOF'
import os, shutil, sys, tempfile

prefix = sys.argv[1]
base = os.environ.get("TMPDIR") or "/tmp"
for _ in range(20):
    d = tempfile.mkdtemp(prefix=f"{prefix}.", dir=base)
    low = d.lower()
    if "abc123" not in low and "xyz" not in low:
        print(d)
        sys.exit(0)
    shutil.rmtree(d, ignore_errors=True)
sys.stderr.write("FAIL: Could not allocate temporary directory without secret substrings\n")
sys.exit(1)
PYEOF
}

TMP_WORK_DIR="$(make_clean_tmpdir "ll-m2-work")"
TMP_AGENT_DIR="$(make_clean_tmpdir "ll-m2-agent")"
SPAWNED_PIDS_FILE="$TMP_WORK_DIR/spawned_pids.txt"
touch "$SPAWNED_PIDS_FILE"

RAND_HEX="$(python3 -c '
import uuid
while True:
    h = uuid.uuid4().hex[:10]
    if "abc123" not in h:
        print(h)
        break
')"
LABEL="com.launchlens.acceptance.${RAND_HEX}"
PLIST_PATH="$TMP_AGENT_DIR/${LABEL}.plist"
REAL_TMP_AGENT_DIR="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$TMP_AGENT_DIR")"
REAL_PLIST_PATH="${REAL_TMP_AGENT_DIR}/${LABEL}.plist"

safe_terminate_recorded_pids() {
    if [[ -f "$SPAWNED_PIDS_FILE" ]]; then
        python3 - "$SPAWNED_PIDS_FILE" "$UID_NUM" "$TMP_AGENT_DIR" "$REAL_TMP_AGENT_DIR" <<'PYEOF'
import os, pathlib, signal, subprocess, sys, time

pids_file = pathlib.Path(sys.argv[1])
expected_uid = str(sys.argv[2])
markers = [sys.argv[3], sys.argv[4]]

if not pids_file.exists():
    sys.exit(0)

raw_pids = []
for line in pids_file.read_text(encoding="utf-8").splitlines():
    s = line.strip()
    if s.isdigit() and int(s) > 1:
        raw_pids.append(int(s))

def owns_pid(pid: int) -> bool:
    res = subprocess.run(
        ["/bin/ps", "-o", "uid=,args=", "-p", str(pid)],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        return False
    out = res.stdout.strip()
    if not out:
        return False
    parts = out.split(None, 1)
    if len(parts) < 2 or parts[0] != expected_uid:
        return False
    return any(m and m in parts[1] for m in markers)

for sig in (signal.SIGTERM, signal.SIGKILL):
    any_alive = False
    for pid in raw_pids:
        if owns_pid(pid):
            any_alive = True
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
    if not any_alive:
        break
    deadline = time.time() + 1.5
    while time.time() < deadline:
        if not any(owns_pid(p) for p in raw_pids):
            break
        time.sleep(0.05)
PYEOF
    fi
}

cleanup() {
    local exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
        echo "[Diagnostic] m2-snapshot-diff.sh failed (exit=$exit_code); host uptime: $(/usr/bin/uptime 2>&1 || true)" >&2
    fi
    /bin/launchctl bootout "gui/$UID_NUM" "$PLIST_PATH" >/dev/null 2>&1 || true
    /bin/launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
    safe_terminate_recorded_pids
    rm -rf "$TMP_AGENT_DIR" 2>/dev/null || true
    rm -rf "$TMP_WORK_DIR" 2>/dev/null || true
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

snapshot_host_launch_agents() {
    local out_json="$1"
    python3 - "$out_json" <<'PYEOF'
import hashlib, json, os, pwd, sys

out_path = sys.argv[1]
pw_dir = pwd.getpwuid(os.getuid()).pw_dir
agents_dir = os.path.join(pw_dir, "Library/LaunchAgents")

entries = []
if os.path.isdir(agents_dir):
    for fn in sorted(os.listdir(agents_dir)):
        fp = os.path.join(agents_dir, fn)
        st = os.lstat(fp)
        digest = None
        if os.path.isfile(fp) and not os.path.islink(fp):
            with open(fp, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
        entries.append({
            "name_sha256": hashlib.sha256(fn.encode("utf-8")).hexdigest(),
            "mode": st.st_mode,
            "size": st.st_size,
            "mtime_ns": st.st_mtime_ns,
            "sha256": digest,
        })

with open(out_path, "w", encoding="utf-8") as f:
    json.dump({
        "agents_exists": os.path.isdir(agents_dir),
        "agents_count": len(entries),
        "entries": entries,
    }, f, indent=2, sort_keys=True)
PYEOF
}

run_ll() {
    perl -e 'alarm 60; exec @ARGV' "$BIN_PATH" "$@"
}

RAW_REPORT="$TMP_WORK_DIR/m2-snapshot-diff.raw.txt"
SANITIZED_REPORT="$TMP_WORK_DIR/m2-snapshot-diff.sanitized.txt"
HOST_BEFORE="$TMP_WORK_DIR/host_agents_before.json"
HOST_AFTER="$TMP_WORK_DIR/host_agents_after.json"

{
    echo "================================================================"
    echo "LaunchLens M2 Real-launchd Snapshot & Diff Acceptance Suite"
    echo "Date: $(date +%Y-%m-%d)"
    echo "Host Uptime: $(/usr/bin/uptime)"
    echo "================================================================"

    snapshot_host_launch_agents "$HOST_BEFORE"
    AGENTS_BEFORE_COUNT="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["agents_count"])' "$HOST_BEFORE")"
    echo "[Setup] Recorded pre-run ~/Library/LaunchAgents state (files=$AGENTS_BEFORE_COUNT, 0 private labels logged)."

    echo "[Setup] Building LaunchLens CLI executable (headless, zero GUI)..."
    swift build --product LaunchLens >/dev/null
    BIN_PATH="$(swift build --show-bin-path)/LaunchLens"
    if [[ ! -x "$BIN_PATH" ]]; then
        echo "FAIL: Built LaunchLens binary not found at $BIN_PATH" >&2
        exit 1
    fi

    SNAP_A="$TMP_WORK_DIR/snap_a.json"
    SNAP_B="$TMP_WORK_DIR/snap_b.json"
    SNAP_C="$TMP_WORK_DIR/snap_c.json"
    PS_A="$TMP_WORK_DIR/ps_a.txt"
    PS_B="$TMP_WORK_DIR/ps_b.txt"
    PS_C="$TMP_WORK_DIR/ps_c.txt"
    STATE_JSON="$TMP_WORK_DIR/fake_agent_state.json"

    echo ""
    echo "==> [Step 1/6] Capturing baseline Snapshot A..."
    /bin/ps -axo pid,ppid,uid,lstart,args > "$PS_A"
    SNAP_A_OUT="$(run_ll snapshot "$SNAP_A" --lang en)"
    echo "    $SNAP_A_OUT"

    echo ""
    echo "==> [Step 2/6] Running simulated agent session (temporary LaunchAgent + 127.0.0.1 listener + PPID=1 orphan with secrets)..."
    python3 - "$TMP_AGENT_DIR" "$TMP_WORK_DIR" "$LABEL" "$PLIST_PATH" "$UID_NUM" "$SPAWNED_PIDS_FILE" "$STATE_JSON" <<'PYEOF'
import json
import os
import pathlib
import subprocess
import sys
import time

agent_dir = pathlib.Path(sys.argv[1])
work_dir = pathlib.Path(sys.argv[2])
label = sys.argv[3]
plist_path = pathlib.Path(sys.argv[4])
uid_num = int(sys.argv[5])
pids_file = pathlib.Path(sys.argv[6])
state_json = pathlib.Path(sys.argv[7])

# 1. Temporary LaunchAgent plist running /bin/sleep 300 (outside ~/Library/LaunchAgents)
plist_path.write_text(
    f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sleep</string>
        <string>300</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
""",
    encoding="utf-8",
)

# 2. Detached 127.0.0.1 random high-port listener script
listener_script = agent_dir / "fake_listener.py"
listener_script.write_text(
    """import pathlib, socket, sys, time
port_file = pathlib.Path(sys.argv[1])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(8)
bound_port = srv.getsockname()[1]
port_file.write_text(str(bound_port), encoding="utf-8")
deadline = time.time() + 300.0
while time.time() < deadline:
    time.sleep(0.5)
""",
    encoding="utf-8",
)

# 3. Detached non-listening orphan script (invoked with --token=abc123 and API_KEY=xyz)
orphan_script = agent_dir / "fake_orphan.py"
orphan_script.write_text(
    """import pathlib, sys, time
ready_file = pathlib.Path(sys.argv[1])
ready_file.write_text("ready", encoding="utf-8")
deadline = time.time() + 300.0
while time.time() < deadline:
    time.sleep(0.5)
""",
    encoding="utf-8",
)

# Run a short-lived fake-agent parent process so when it exits, both children are reparented to PPID 1.
fake_runner = work_dir / "run_fake_agent_parent.py"
fake_runner.write_text(
    """import json, os, pathlib, subprocess, sys, time

listener_script, orphan_script, plist_path, uid_num, pids_file, state_json, work_dir, label = sys.argv[1:9]
work_p = pathlib.Path(work_dir)
port_file = work_p / "listener_port.txt"
orphan_ready = work_p / "orphan_ready.txt"

listener_proc = subprocess.Popen(
    [sys.executable, listener_script, str(port_file)],
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
with open(pids_file, "a", encoding="utf-8") as f:
    f.write(f"{listener_proc.pid}\\n")

orphan_proc = subprocess.Popen(
    [
        sys.executable,
        orphan_script,
        str(orphan_ready),
        "--token=abc123",
        "API_KEY=xyz",
        f"--secret=sec_{label.rsplit('.', 1)[-1]}",
    ],
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
with open(pids_file, "a", encoding="utf-8") as f:
    f.write(f"{orphan_proc.pid}\\n")

boot_res = subprocess.run(
    ["/bin/launchctl", "bootstrap", f"gui/{uid_num}", plist_path],
    capture_output=True,
    text=True,
)
if boot_res.returncode != 0:
    sys.stderr.write(f"FAIL: launchctl bootstrap exited {boot_res.returncode}: {boot_res.stderr}\\n")
    sys.exit(1)

deadline = time.time() + 5.0
while time.time() < deadline:
    if port_file.exists() and orphan_ready.exists():
        break
    time.sleep(0.05)

if not port_file.exists() or not orphan_ready.exists():
    sys.stderr.write("FAIL: Fake agent children did not report readiness within 5s\\n")
    sys.exit(1)

port_num = int(port_file.read_text(encoding="utf-8").strip())
pathlib.Path(state_json).write_text(
    json.dumps({
        "label": label,
        "plist_path": plist_path,
        "real_plist_path": os.path.realpath(plist_path),
        "fake_agent_parent_pid": os.getpid(),
        "listener_pid": listener_proc.pid,
        "listener_port": port_num,
        "orphan_pid": orphan_proc.pid,
    }, indent=2),
    encoding="utf-8",
)
""",
    encoding="utf-8",
)

res = subprocess.run(
    [
        sys.executable,
        str(fake_runner),
        str(listener_script),
        str(orphan_script),
        str(plist_path),
        str(uid_num),
        str(pids_file),
        str(state_json),
        str(work_dir),
        label,
    ],
    capture_output=True,
    text=True,
)
if res.returncode != 0:
    sys.stderr.write(res.stderr)
    sys.exit(1)

st = json.loads(state_json.read_text(encoding="utf-8"))
l_pid = st["listener_pid"]
l_port = st["listener_port"]
o_pid = st["orphan_pid"]

# Poll until both children are reparented to PPID == 1, launchctl print sees the job, and lsof sees TCP LISTEN.
service_pid = None
ready_ok = False
deadline = time.time() + 5.0
while time.time() < deadline:
    ps1 = subprocess.run(["/bin/ps", "-o", "ppid=", "-p", str(l_pid)], capture_output=True, text=True)
    ps2 = subprocess.run(["/bin/ps", "-o", "ppid=", "-p", str(o_pid)], capture_output=True, text=True)
    l_ppid = ps1.stdout.strip()
    o_ppid = ps2.stdout.strip()
    pr = subprocess.run(["/bin/launchctl", "print", f"gui/{uid_num}/{label}"], capture_output=True, text=True)
    ls = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(l_pid), f"-iTCP:{l_port}", "-sTCP:LISTEN"],
        capture_output=True,
        text=True,
    )
    if l_ppid == "1" and o_ppid == "1" and pr.returncode == 0 and ls.returncode == 0 and str(l_port) in ls.stdout:
        for line in pr.stdout.splitlines():
            t = line.strip()
            if t.startswith("pid = "):
                val = t[len("pid = "):].strip()
                if val.isdigit():
                    service_pid = int(val)
                break
        ready_ok = True
        break
    time.sleep(0.05)

if not ready_ok:
    sys.stderr.write("FAIL: Timed out waiting for PPID==1 reparenting / launchctl print / lsof LISTEN readiness.\n")
    sys.exit(1)

st["service_pid"] = service_pid
state_json.write_text(json.dumps(st, indent=2), encoding="utf-8")
print(f"    Spawned fake agent artifacts: label={label} service_pid={service_pid} listener=127.0.0.1:{l_port}(PID {l_pid}, ppid=1) orphan=PID {o_pid}(ppid=1)")
PYEOF

    echo ""
    echo "==> [Step 3/6] Capturing post-session Snapshot B and running diff A -> B..."
    /bin/ps -axo pid,ppid,uid,lstart,args > "$PS_B"
    SNAP_B_OUT="$(run_ll snapshot "$SNAP_B" --lang en)"
    echo "    $SNAP_B_OUT"

    DIFF_AB_EN="$TMP_WORK_DIR/diff_ab_en.txt"
    DIFF_AB_ZH="$TMP_WORK_DIR/diff_ab_zh.txt"
    DIFF_AB_JSON="$TMP_WORK_DIR/diff_ab.json"
    DIFF_AB_FAIL="$TMP_WORK_DIR/diff_ab_fail.txt"
    DIFF_AB_JSON_FAIL="$TMP_WORK_DIR/diff_ab_fail.json"

    run_ll diff "$SNAP_A" "$SNAP_B" --lang en > "$DIFF_AB_EN"
    run_ll diff "$SNAP_A" "$SNAP_B" --lang zh > "$DIFF_AB_ZH"
    run_ll diff "$SNAP_A" "$SNAP_B" --json > "$DIFF_AB_JSON"

    set +e
    run_ll diff "$SNAP_A" "$SNAP_B" --fail-on-added --lang en > "$DIFF_AB_FAIL"
    FAIL_TEXT_RC=$?
    run_ll diff "$SNAP_A" "$SNAP_B" --json --fail-on-added > "$DIFF_AB_JSON_FAIL"
    FAIL_JSON_RC=$?
    set -e

    if [[ "$FAIL_TEXT_RC" -ne 3 || "$FAIL_JSON_RC" -ne 3 ]]; then
        echo "FAIL: Expected --fail-on-added exit code 3 on diff A B, got text=$FAIL_TEXT_RC json=$FAIL_JSON_RC" >&2
        exit 1
    fi
    echo "    Verified --fail-on-added exit codes: text=$FAIL_TEXT_RC, json=$FAIL_JSON_RC"

    echo ""
    echo "==> [Step 4/6] Validating diff A -> B (services, ports, orphans, bilingual text, JSON, and secret redaction)..."
    python3 - "$STATE_JSON" "$SCRIPT_PID" "$TMP_AGENT_DIR" "$REAL_TMP_AGENT_DIR" "$TMP_WORK_DIR" "$SNAP_A" "$SNAP_B" "$DIFF_AB_EN" "$DIFF_AB_ZH" "$DIFF_AB_JSON" "$PS_A" "$PS_B" <<'PYEOF'
import json
import pathlib
import subprocess
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
script_pid = int(sys.argv[2])
tmp_agent_dir = sys.argv[3]
real_tmp_agent_dir = sys.argv[4]
tmp_work_dir = sys.argv[5]
snap_a_path = pathlib.Path(sys.argv[6])
snap_b_path = pathlib.Path(sys.argv[7])
diff_en_path = pathlib.Path(sys.argv[8])
diff_zh_path = pathlib.Path(sys.argv[9])
diff_json_path = pathlib.Path(sys.argv[10])
ps_a_path = pathlib.Path(sys.argv[11])
ps_b_path = pathlib.Path(sys.argv[12])

label = state["label"]
real_plist_path = state["real_plist_path"]
listener_pid = int(state["listener_pid"])
listener_port = int(state["listener_port"])
orphan_pid = int(state["orphan_pid"])
fake_parent_pid = int(state["fake_agent_parent_pid"])
service_pid = state.get("service_pid")

our_pids = {script_pid, fake_parent_pid, listener_pid, orphan_pid}
if service_pid:
    our_pids.add(int(service_pid))
our_markers = [m for m in [tmp_agent_dir, real_tmp_agent_dir, tmp_work_dir, label] if m]

# 1. Row 6 Secret Redaction Verification across Snapshot files and Diff outputs
dyn_secret = f"sec_{label.rsplit('.', 1)[-1]}"

# 1a. Assignment forms and the per-run dynamic secret MUST NEVER appear anywhere in any snapshot or diff output.
for path_obj in [snap_a_path, snap_b_path, diff_en_path, diff_zh_path, diff_json_path]:
    raw_txt = path_obj.read_text(encoding="utf-8")
    for forbidden in ("--token=abc123", "API_KEY=xyz", dyn_secret):
        if forbidden in raw_txt:
            sys.stderr.write(f"FAIL [Row 6]: Unredacted secret '{forbidden}' leaked into {path_obj.name}!\n")
            sys.exit(1)

# 1b. Bare 'abc123' and 'xyz' MUST NEVER appear anywhere in diff outputs (text EN, text ZH, --json).
for path_obj in [diff_en_path, diff_zh_path, diff_json_path]:
    raw_txt = path_obj.read_text(encoding="utf-8")
    for secret in ("abc123", "xyz"):
        if secret in raw_txt:
            sys.stderr.write(f"FAIL [Row 6]: Bare secret '{secret}' leaked into {path_obj.name}!\n")
            sys.exit(1)

# 1c. In snap_b.json, inspect every entry; only a pre-existing process already present with identical (pid, lstart)
# in snap_a.json (e.g. an outer headless runner whose own -p prompt prose mentions the literal words) may carry
# pre-existing prose; our newly spawned fake orphan and every new entry in snap_b.json must have zero 'abc123'/'xyz'.
snap_a_obj = json.loads(snap_a_path.read_text(encoding="utf-8"))
snap_b_obj = json.loads(snap_b_path.read_text(encoding="utf-8"))
preexisting_prose_keys = set()
for sec_name in ("listeners", "orphans"):
    for item in snap_a_obj.get(sec_name, []):
        blob = json.dumps(item, ensure_ascii=False)
        if "abc123" in blob or "xyz" in blob:
            preexisting_prose_keys.add((sec_name, int(item["pid"]), item.get("lstart", "")))

for sec_name in ("services", "listeners", "orphans"):
    for item in snap_b_obj.get(sec_name, []):
        blob = json.dumps(item, ensure_ascii=False)
        key = (sec_name, int(item.get("pid") or -1), item.get("lstart", ""))
        if key in preexisting_prose_keys:
            continue
        for secret in ("abc123", "xyz"):
            if secret in blob:
                sys.stderr.write(f"FAIL [Row 6]: Bare secret '{secret}' leaked into snap_b.json {sec_name} entry (pid={item.get('pid')})!\n")
                sys.exit(1)

snap_b_orphans = [o for o in snap_b_obj.get("orphans", []) if int(o["pid"]) == orphan_pid]
if len(snap_b_orphans) != 1:
    sys.stderr.write(f"FAIL [Row 6]: Expected fake orphan PID {orphan_pid} in snap_b.json orphans, found {len(snap_b_orphans)}\n")
    sys.exit(1)

for path_obj in [snap_b_path, diff_en_path, diff_zh_path, diff_json_path]:
    raw_txt = path_obj.read_text(encoding="utf-8")
    for expected_mask in ("--token=***", "API_KEY=***", "--secret=***"):
        if expected_mask not in raw_txt:
            sys.stderr.write(f"FAIL [Row 6]: Expected redacted placeholder '{expected_mask}' in {path_obj.name}!\n")
            sys.exit(1)

print("[M2 Row 6 PASS] Unredacted secrets ('abc123', 'xyz', per-run secret) absent from snapshot entries and diff outputs; '--token=***', 'API_KEY=***', '--secret=***' verified.")

# Parse PS tables for ancestor-chain attribution of any concurrent external port
def parse_ps_table(ps_text: str) -> dict[int, tuple[int, str]]:
    table: dict[int, tuple[int, str]] = {}
    for line in ps_text.splitlines():
        s = line.strip()
        if not s or s.startswith("PID"):
            continue
        # pid ppid uid dow mon day hh:mm:ss yyyy args...
        parts = s.split(None, 8)
        if len(parts) < 9:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        table[pid] = (ppid, parts[8])
    return table

ps_merged = parse_ps_table(ps_a_path.read_text(encoding="utf-8"))
ps_merged.update(parse_ps_table(ps_b_path.read_text(encoding="utf-8")))
live_ps = subprocess.run(["/bin/ps", "-axo", "pid,ppid,uid,lstart,args"], capture_output=True, text=True)
if live_ps.returncode == 0:
    for k, v in parse_ps_table(live_ps.stdout).items():
        ps_merged.setdefault(k, v)

def build_ancestor_chain(start_pid: int, fallback_ppid: int) -> list[tuple[int, str]]:
    chain: list[tuple[int, str]] = []
    seen: set[int] = set()
    cur = start_pid
    while cur > 0 and cur not in seen:
        seen.add(cur)
        if cur in ps_merged:
            ppid, cmd = ps_merged[cur]
            chain.append((cur, cmd))
            if cur == 1 or ppid <= 0 or ppid == cur:
                break
            cur = ppid
        else:
            chain.append((cur, "<exited>"))
            if cur == start_pid and fallback_ppid > 0 and fallback_ppid not in seen:
                cur = fallback_ppid
            else:
                break
    return chain

def verify_external_listener(entry: dict, direction: str) -> None:
    epid = int(entry["pid"])
    eppid = int(entry["ppid"])
    eport = int(entry["port"])
    ecmd = entry.get("programCommand", "")
    eexe = entry.get("executable", "")
    esvc = entry.get("serviceLabel")
    chain = build_ancestor_chain(epid, eppid)
    chain_pids = {p for p, _ in chain}

    belongs_to_us = False
    if epid in our_pids or (chain_pids & our_pids):
        belongs_to_us = True
    if any(m in ecmd or m in eexe or (esvc and m in esvc) for m in our_markers):
        belongs_to_us = True
    for _, anc_cmd in chain:
        if any(m in anc_cmd for m in our_markers):
            belongs_to_us = True

    chain_fmt = " -> ".join(f"{p}({c.split()[0] if c and c != '<exited>' else c})" for p, c in chain)
    if belongs_to_us:
        sys.stderr.write(
            f"FAIL [Row 3]: Unexpected listener ({direction}) :{eport} PID={epid} belongs to this acceptance script! chain={chain_fmt}\n"
        )
        sys.exit(1)
    print(
        f"    [External Port Attribution ({direction})] :{eport} PID={epid} PPID={eppid} "
        f"service={esvc or 'none'} program={ecmd} | ancestor_chain={chain_fmt}"
    )

diff_obj = json.loads(diff_json_path.read_text(encoding="utf-8"))
diff_en = diff_en_path.read_text(encoding="utf-8")
diff_zh = diff_zh_path.read_text(encoding="utf-8")

# 2. Services: MUST be strictly +1 (ours), -0, ~0
summary = diff_obj["summary"]
if summary["servicesAdded"] != 1 or summary["servicesRemoved"] != 0 or summary["servicesModified"] != 0:
    sys.stderr.write(f"FAIL [Row 3]: Expected services +1/-0/~0 in diff A B, got summary={summary}\n{diff_en}\n")
    sys.exit(1)

svc = diff_obj["services"]["added"][0]
if (
    svc["label"] != label
    or svc["domainScope"] != "user"
    or svc["plistPath"] != real_plist_path
    or svc["isExternalPlist"] is not True
    or "/bin/sleep" not in svc["programCommand"]
):
    sys.stderr.write(f"FAIL [Row 3]: Added service mismatch: {svc}\n")
    sys.exit(1)

# 3. Orphans: MUST be strictly +1 (ours, non-listening), -0
if summary["orphansAdded"] != 1 or summary["orphansRemoved"] != 0:
    sys.stderr.write(f"FAIL [Row 3]: Expected orphans +1/-0 in diff A B, got summary={summary}\n{diff_en}\n")
    sys.exit(1)

orp = diff_obj["orphans"]["added"][0]
if int(orp["pid"]) != orphan_pid or int(orp["ppid"]) != 1:
    sys.stderr.write(f"FAIL [Row 3]: Added orphan mismatch (expected PID {orphan_pid}, ppid 1): {orp}\n")
    sys.exit(1)
if any(int(o["pid"]) == listener_pid for o in diff_obj["orphans"]["added"]):
    sys.stderr.write(f"FAIL [Row 3 / D1]: Listener PID {listener_pid} was duplicated in orphans!\n")
    sys.exit(1)

# 4. Listeners: our port/PID MUST be in added; any extra added/removed must be proven external
added_listeners = diff_obj["listeners"]["added"]
removed_listeners = diff_obj["listeners"]["removed"]
our_matches = [
    it for it in added_listeners
    if int(it["port"]) == listener_port and int(it["pid"]) == listener_pid
]
if len(our_matches) != 1:
    sys.stderr.write(
        f"FAIL [Row 3]: Expected exact match for listener 127.0.0.1:{listener_port} (PID {listener_pid}) in listeners.added, got: {added_listeners}\n"
    )
    sys.exit(1)
our_listener = our_matches[0]
if "127.0.0.1" not in our_listener["bindAddresses"] or our_listener["isOrphan"] is not True:
    sys.stderr.write(f"FAIL [Row 3]: Listener bindAddresses/isOrphan mismatch: {our_listener}\n")
    sys.exit(1)

extra_added = [
    it for it in added_listeners
    if not (int(it["port"]) == listener_port and int(it["pid"]) == listener_pid)
]
for ext in extra_added:
    verify_external_listener(ext, "+added")
for ext in removed_listeners:
    verify_external_listener(ext, "-removed")

# 5. Bilingual Text Output Checks (EN & ZH)
expected_en_substrings = [
    "Services: +1 added, -0 removed, ~0 modified",
    f"  + [user] {label} | plist: {real_plist_path} | program: /bin/sleep 300",
    f"Listening Ports: +{summary['listenersAdded']} added, -{summary['listenersRemoved']} removed",
    f"  + :{listener_port} | bind: 127.0.0.1 | PID {listener_pid} [orphan] | program:",
    "Orphan Processes: +1 added, -0 removed",
    f"  + PID {orphan_pid} | started:",
]
for needle in expected_en_substrings:
    if needle not in diff_en:
        sys.stderr.write(f"FAIL [Row 3]: Missing expected EN text substring '{needle}' in:\n{diff_en}\n")
        sys.exit(1)

expected_zh_substrings = [
    "后台服务: +1 新增, -0 删除, ~0 修改",
    f"  + [用户] {label} | plist: {real_plist_path} | 程序: /bin/sleep 300",
    f"监听端口: +{summary['listenersAdded']} 新增, -{summary['listenersRemoved']} 删除",
    f"  + :{listener_port} | 绑定: 127.0.0.1 | PID {listener_pid} [孤儿] | 程序:",
    "孤儿进程: +1 新增, -0 删除",
    f"  + PID {orphan_pid} | 启动:",
]
for needle in expected_zh_substrings:
    if needle not in diff_zh:
        sys.stderr.write(f"FAIL [Row 3]: Missing expected ZH text substring '{needle}' in:\n{diff_zh}\n")
        sys.exit(1)

print("    --- diff A -> B (EN) ---")
for ln in diff_en.strip().splitlines():
    print(f"    {ln}")
print(
    f"    Verified diff A -> B: services=+1/-0/~0, listeners=+{summary['listenersAdded']}/-{summary['listenersRemoved']} "
    f"(ours=1, external_added={len(extra_added)}, external_removed={len(removed_listeners)}), orphans=+1/-0"
)
PYEOF

    echo ""
    echo "==> [Step 5/6] Cleaning up fake agent service, listener, orphan, and temporary plist directory..."
    /bin/launchctl bootout "gui/$UID_NUM" "$PLIST_PATH" >/dev/null 2>&1 || /bin/launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
    safe_terminate_recorded_pids
    rm -rf "$TMP_AGENT_DIR"

    python3 - "$STATE_JSON" "$UID_NUM" "$TMP_AGENT_DIR" <<'PYEOF'
import json
import pathlib
import subprocess
import sys
import time

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
uid_num = int(sys.argv[2])
tmp_agent_dir = pathlib.Path(sys.argv[3])

label = state["label"]
listener_pid = int(state["listener_pid"])
listener_port = int(state["listener_port"])
orphan_pid = int(state["orphan_pid"])
service_pid = state.get("service_pid")

check_pids = [listener_pid, orphan_pid] + ([int(service_pid)] if service_pid else [])

# Wait up to 5s for kernel process table / port table teardown
deadline = time.time() + 5.0
while time.time() < deadline:
    pr = subprocess.run(["/bin/launchctl", "print", f"gui/{uid_num}/{label}"], capture_output=True, text=True)
    ls = subprocess.run(["/usr/sbin/lsof", "-nP", f"-iTCP:{listener_port}", "-sTCP:LISTEN"], capture_output=True, text=True)
    alive = [
        p for p in check_pids
        if subprocess.run(["/bin/ps", "-p", str(p)], capture_output=True).returncode == 0
    ]
    if pr.returncode != 0 and (ls.returncode != 0 or not ls.stdout.strip()) and not alive:
        break
    time.sleep(0.05)

# Hard post-cleanup OS assertions
pr = subprocess.run(["/bin/launchctl", "print", f"gui/{uid_num}/{label}"], capture_output=True, text=True)
if pr.returncode == 0:
    sys.stderr.write(f"FAIL [Row 3]: launchctl print gui/{uid_num}/{label} unexpectedly succeeded after bootout!\n")
    sys.exit(1)

lctl_list = subprocess.run(["/bin/launchctl", "list"], capture_output=True, text=True)
if label in lctl_list.stdout:
    sys.stderr.write(f"FAIL [Row 3]: Residual label {label} still present in launchctl list!\n")
    sys.exit(1)

ls = subprocess.run(["/usr/sbin/lsof", "-nP", f"-iTCP:{listener_port}", "-sTCP:LISTEN"], capture_output=True, text=True)
if ls.returncode == 0 and ls.stdout.strip():
    sys.stderr.write(f"FAIL [Row 3]: Port {listener_port} still in LISTEN state after cleanup:\n{ls.stdout}\n")
    sys.exit(1)

for p in check_pids:
    ps_chk = subprocess.run(["/bin/ps", "-p", str(p)], capture_output=True, text=True)
    if ps_chk.returncode == 0:
        sys.stderr.write(f"FAIL [Row 3]: Process PID {p} still alive after cleanup:\n{ps_chk.stdout}\n")
        sys.exit(1)

if tmp_agent_dir.exists():
    sys.stderr.write(f"FAIL [Row 3]: Temporary agent directory still exists: {tmp_agent_dir}\n")
    sys.exit(1)

print(
    f"    Verified OS cleanup: launchctl print exit={pr.returncode}, label absent from launchctl list, "
    f"port {listener_port} released, PIDs {check_pids} exited, temp dir removed."
)
PYEOF

    echo ""
    echo "==> [Step 6/6] Capturing post-cleanup Snapshot C and verifying diff A -> C & host non-mutation..."
    /bin/ps -axo pid,ppid,uid,lstart,args > "$PS_C"
    SNAP_C_OUT="$(run_ll snapshot "$SNAP_C" --lang en)"
    echo "    $SNAP_C_OUT"

    DIFF_AC_EN="$TMP_WORK_DIR/diff_ac_en.txt"
    DIFF_AC_JSON="$TMP_WORK_DIR/diff_ac.json"
    run_ll diff "$SNAP_A" "$SNAP_C" --lang en > "$DIFF_AC_EN"
    run_ll diff "$SNAP_A" "$SNAP_C" --json > "$DIFF_AC_JSON"

    python3 - "$STATE_JSON" "$SCRIPT_PID" "$TMP_AGENT_DIR" "$REAL_TMP_AGENT_DIR" "$TMP_WORK_DIR" "$DIFF_AC_EN" "$DIFF_AC_JSON" "$PS_A" "$PS_C" "$BIN_PATH" "$SNAP_A" "$SNAP_C" <<'PYEOF'
import json
import pathlib
import subprocess
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
script_pid = int(sys.argv[2])
tmp_agent_dir = sys.argv[3]
real_tmp_agent_dir = sys.argv[4]
tmp_work_dir = sys.argv[5]
diff_en_path = pathlib.Path(sys.argv[6])
diff_json_path = pathlib.Path(sys.argv[7])
ps_a_path = pathlib.Path(sys.argv[8])
ps_c_path = pathlib.Path(sys.argv[9])
bin_path = sys.argv[10]
snap_a_path = sys.argv[11]
snap_c_path = sys.argv[12]

label = state["label"]
listener_pid = int(state["listener_pid"])
listener_port = int(state["listener_port"])
orphan_pid = int(state["orphan_pid"])
fake_parent_pid = int(state["fake_agent_parent_pid"])
service_pid = state.get("service_pid")

our_pids = {script_pid, fake_parent_pid, listener_pid, orphan_pid}
if service_pid:
    our_pids.add(int(service_pid))
our_markers = [m for m in [tmp_agent_dir, real_tmp_agent_dir, tmp_work_dir, label] if m]

def parse_ps_table(ps_text: str) -> dict[int, tuple[int, str]]:
    table: dict[int, tuple[int, str]] = {}
    for line in ps_text.splitlines():
        s = line.strip()
        if not s or s.startswith("PID"):
            continue
        parts = s.split(None, 8)
        if len(parts) < 9:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        table[pid] = (ppid, parts[8])
    return table

ps_merged = parse_ps_table(ps_a_path.read_text(encoding="utf-8"))
ps_merged.update(parse_ps_table(ps_c_path.read_text(encoding="utf-8")))
live_ps = subprocess.run(["/bin/ps", "-axo", "pid,ppid,uid,lstart,args"], capture_output=True, text=True)
if live_ps.returncode == 0:
    for k, v in parse_ps_table(live_ps.stdout).items():
        ps_merged.setdefault(k, v)

def build_ancestor_chain(start_pid: int, fallback_ppid: int) -> list[tuple[int, str]]:
    chain: list[tuple[int, str]] = []
    seen: set[int] = set()
    cur = start_pid
    while cur > 0 and cur not in seen:
        seen.add(cur)
        if cur in ps_merged:
            ppid, cmd = ps_merged[cur]
            chain.append((cur, cmd))
            if cur == 1 or ppid <= 0 or ppid == cur:
                break
            cur = ppid
        else:
            chain.append((cur, "<exited>"))
            if cur == start_pid and fallback_ppid > 0 and fallback_ppid not in seen:
                cur = fallback_ppid
            else:
                break
    return chain

diff_obj = json.loads(diff_json_path.read_text(encoding="utf-8"))
diff_en = diff_en_path.read_text(encoding="utf-8")
summary = diff_obj["summary"]

if summary["servicesAdded"] != 0 or summary["servicesRemoved"] != 0 or summary["servicesModified"] != 0:
    sys.stderr.write(f"FAIL [Row 3]: Expected 0 service diffs in diff A C, got summary={summary}\n{diff_en}\n")
    sys.exit(1)

if summary["orphansAdded"] != 0 or summary["orphansRemoved"] != 0:
    sys.stderr.write(f"FAIL [Row 3]: Expected 0 orphan diffs in diff A C, got summary={summary}\n{diff_en}\n")
    sys.exit(1)

for direction, items in (("+added", diff_obj["listeners"]["added"]), ("-removed", diff_obj["listeners"]["removed"])):
    for entry in items:
        epid = int(entry["pid"])
        eppid = int(entry["ppid"])
        eport = int(entry["port"])
        ecmd = entry.get("programCommand", "")
        eexe = entry.get("executable", "")
        esvc = entry.get("serviceLabel")
        chain = build_ancestor_chain(epid, eppid)
        chain_pids = {p for p, _ in chain}
        belongs_to_us = (
            eport == listener_port
            or epid in our_pids
            or bool(chain_pids & our_pids)
            or any(m in ecmd or m in eexe or (esvc and m in esvc) for m in our_markers)
            or any(any(m in anc_cmd for m in our_markers) for _, anc_cmd in chain)
        )
        chain_fmt = " -> ".join(f"{p}({c.split()[0] if c and c != '<exited>' else c})" for p, c in chain)
        if belongs_to_us:
            sys.stderr.write(
                f"FAIL [Row 3]: Residual listener ({direction}) :{eport} PID={epid} belongs to this script in diff A C! chain={chain_fmt}\n"
            )
            sys.exit(1)
        print(
            f"    [External Port Attribution in diff A->C ({direction})] :{eport} PID={epid} PPID={eppid} "
            f"service={esvc or 'none'} program={ecmd} | ancestor_chain={chain_fmt}"
        )

if not diff_obj["hasAdditions"]:
    chk = subprocess.run(
        ["perl", "-e", "alarm 60; exec @ARGV", bin_path, "diff", snap_a_path, snap_c_path, "--fail-on-added"],
        capture_output=True,
        text=True,
    )
    if chk.returncode != 0:
        sys.stderr.write(f"FAIL [Row 3]: Expected diff A C --fail-on-added exit 0 when hasAdditions=false, got {chk.returncode}\n")
        sys.exit(1)

print("    --- diff A -> C (EN) ---")
for ln in diff_en.strip().splitlines():
    print(f"    {ln}")
PYEOF

    snapshot_host_launch_agents "$HOST_AFTER"
    if ! cmp -s "$HOST_BEFORE" "$HOST_AFTER"; then
        echo "FAIL [Row 9]: ~/Library/LaunchAgents changed during m2-snapshot-diff.sh!" >&2
        diff -u "$HOST_BEFORE" "$HOST_AFTER" >&2 || true
        exit 1
    fi

    echo "[M2 Row 3 PASS] Fake-agent snapshot/diff round-trip (+1 service, +1 port, +1 orphan; --fail-on-added exit 3; post-cleanup diff A->C verified)."
    echo "[M2 Row 9 PASS] ~/Library/LaunchAgents ($AGENTS_BEFORE_COUNT files) unchanged and zero residual processes/ports/plists."
    echo "================================================================"
    echo "M2 REAL-LAUNCHD SNAPSHOT & DIFF ACCEPTANCE PASSED (EXIT 0)"
    echo "================================================================"
} > "$RAW_REPORT"

python3 - "$RAW_REPORT" "$SANITIZED_REPORT" "$ROOT" "$TMP_WORK_DIR" "$TMP_AGENT_DIR" "$REAL_TMP_AGENT_DIR" "$HOME" <<'PYEOF'
import os, pathlib, pwd, re, sys

raw_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
repo_root, tmp_work, tmp_agent, real_tmp_agent, home_dir = sys.argv[3:8]

text = raw_path.read_text(encoding="utf-8")
for val, token in [
    (real_tmp_agent, "<TMP_AGENT_DIR>"),
    (tmp_agent, "<TMP_AGENT_DIR>"),
    (str(pathlib.Path(tmp_work).resolve()), "<TMP_WORK_DIR>"),
    (tmp_work, "<TMP_WORK_DIR>"),
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
    echo "[Record] Wrote sanitized report to reports/m2-snapshot-diff.txt"
fi
