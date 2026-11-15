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
    kill_spawned_probes
    chmod -R u+rwx "$TMP_ROOT" 2>/dev/null || true
    rm -rf "$TMP_ROOT"
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
    echo "Date: 2026-11-15"
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

    python3 - "$BIN_PATH" "$NODE_BIN" "$TMP_ROOT" "$SPAWNED_PIDS_FILE" <<'PYEOF'
from __future__ import annotations
import json
import os
import pathlib
import plistlib
import pwd
import signal
import subprocess
import sys
import time

bin_path = sys.argv[1]
node_bin = sys.argv[2]
tmp_root = pathlib.Path(sys.argv[3])
spawned_pids_file = pathlib.Path(sys.argv[4])

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
time.sleep(120)
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
        "time.sleep(120)",
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

# 2. Capture live system truth and LaunchLens --cli list --json back-to-back
empty_vault = tmp_root / "empty_vault"
lctl_out = subprocess.check_output(["/bin/launchctl", "list"], text=True)
ps_out = subprocess.check_output(["/bin/ps", "-axo", "pid,ppid,uid,rss,args"], text=True)
lsof_out = subprocess.check_output(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], text=True)
cli_raw = subprocess.check_output(
    [bin_path, "--cli", "list", "--json", "--ledger-dir", str(empty_vault), "--lang", "en"],
    text=True,
)

# 3. Tear down all spawned test processes immediately after capture
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

# 4. Independent reference calculation
payload = json.loads(cli_raw)
cli_services = payload["services"]
cli_orphans = payload["orphans"]

pw_dir = pwd.getpwuid(os.getuid()).pw_dir
plist_dirs = [
    ("User LaunchAgent", os.path.join(pw_dir, "Library/LaunchAgents")),
    ("Global LaunchAgent", "/Library/LaunchAgents"),
    ("System LaunchDaemon", "/Library/LaunchDaemons"),
]

ref_plists = []
domain_counts = {"User LaunchAgent": 0, "Global LaunchAgent": 0, "System LaunchDaemon": 0}
for dom, dpath in plist_dirs:
    if not os.path.isdir(dpath):
        continue
    for fn in sorted(os.listdir(dpath)):
        if fn.startswith(".") or not fn.endswith(".plist"):
            continue
        fp = os.path.join(dpath, fn)
        try:
            with open(fp, "rb") as f:
                obj = plistlib.load(f)
            if not isinstance(obj, dict):
                continue
        except Exception:
            continue
        label = obj.get("Label") if isinstance(obj.get("Label"), str) else fn[:-6]
        prog = obj.get("Program").strip() if isinstance(obj.get("Program"), str) else ""
        raw_args = [a for a in (obj.get("ProgramArguments") or []) if isinstance(a, str) and a]
        if prog:
            resolved_args = [prog] + raw_args[1:] if raw_args else [prog]
        elif raw_args:
            resolved_args = raw_args
        else:
            resolved_args = None
        ref_plists.append((dom, label, resolved_args))
        domain_counts[dom] += 1

lctl_map: dict[str, int | None] = {}
for line in lctl_out.splitlines()[1:]:
    cols = line.split()
    if len(cols) >= 3:
        pid_val = int(cols[0]) if cols[0] != "-" and cols[0].isdigit() else None
        lbl = " ".join(cols[2:])
        lctl_map[lbl] = pid_val

ps_rows: dict[int, tuple[int, int, int, str]] = {}
children_by_ppid: dict[int, list[int]] = {}
for line in ps_out.splitlines()[1:]:
    s = line.strip()
    if not s:
        continue
    cols = s.split(None, 4)
    if len(cols) < 5 or not cols[0].isdigit():
        continue
    pid, ppid, uid, rss_kb = int(cols[0]), int(cols[1]), int(cols[2]), int(cols[3])
    cmd = cols[4]
    ps_rows[pid] = (ppid, uid, rss_kb, cmd)
    children_by_ppid.setdefault(ppid, []).append(pid)

lsof_ports_by_pid: dict[int, set[int]] = {}
for line in lsof_out.splitlines()[1:]:
    cols = line.split()
    if len(cols) >= 8 and cols[1].isdigit():
        pid = int(cols[1])
        endpoint = cols[-2] if (cols[-1] == "(LISTEN)" and len(cols) >= 9) else cols[-1]
        if ":" in endpoint:
            port_str = endpoint.rsplit(":", 1)[1]
            if port_str.isdigit():
                lsof_ports_by_pid.setdefault(pid, set()).add(int(port_str))

def collect_tree(roots: set[int]) -> set[int]:
    visited: set[int] = set()
    stack = [r for r in sorted(roots) if r > 0]
    while stack:
        cur = stack.pop()
        if cur in visited:
            continue
        visited.add(cur)
        for ch in children_by_ppid.get(cur, []):
            if ch > 0 and ch not in visited:
                stack.append(ch)
    return visited

def norm_exe(path_token: str) -> str:
    if path_token.startswith("~/"):
        path_token = os.path.expanduser(path_token)
    if path_token.startswith("/"):
        return os.path.normpath(path_token)
    return path_token

claimed_lctl_roots = {p for p in lctl_map.values() if p and p > 0}
claimed_all_pids = collect_tree(claimed_lctl_roots)

ref_services: dict[tuple[str, str], tuple[bool, int, list[int], set[int]]] = {}
for dom, lbl, rargs in ref_plists:
    lctl_pid = lctl_map.get(lbl)
    if lctl_pid and lctl_pid > 0:
        roots = {lctl_pid}
    elif rargs:
        target_exe = norm_exe(rargs[0])
        roots = set()
        for rpid, (_rppid, _ruid, _rrss, rcmd) in ps_rows.items():
            if rpid in claimed_all_pids:
                continue
            first_tok = norm_exe(rcmd.split()[0]) if rcmd.split() else ""
            if first_tok == target_exe:
                roots.add(rpid)
        if roots:
            claimed_all_pids |= collect_tree(roots)
    else:
        roots = set()

    tree_pids = collect_tree(roots)
    rss_bytes = sum(max(0, ps_rows[p][2]) for p in tree_pids if p in ps_rows) * 1024
    ports = sorted({pt for p in tree_pids for pt in lsof_ports_by_pid.get(p, set())})
    ref_services[(dom, lbl)] = (bool(roots), rss_bytes, ports, tree_pids)

# --- ROW 1 ASSERTIONS: Service count 100% + RSS <= 5% ---
cli_keys = [(s["domain"], s["label"]) for s in cli_services]
ref_keys = [(dom, lbl) for dom, lbl, _ in ref_plists]
if len(cli_services) != len(ref_plists) or sorted(cli_keys) != sorted(ref_keys):
    raise AssertionError(
        f"Service count/set mismatch: cli={len(cli_services)} vs ref={len(ref_plists)}"
    )

running_service_count = 0
multi_proc_tree_count = 0
max_rss_pct_diff = 0.0
max_rss_kb_diff = 0.0

for svc in cli_services:
    key = (svc["domain"], svc["label"])
    ref_running, ref_rss, _ref_ports, tree_pids = ref_services[key]
    cli_rss = int(svc["rssBytes"])
    cli_pid = svc.get("pid")
    if (cli_pid is not None and cli_pid > 0) or ref_running:
        running_service_count += 1
        if len(tree_pids) > 1:
            multi_proc_tree_count += 1
        abs_diff = abs(cli_rss - ref_rss)
        pct_diff = (abs_diff * 100.0) / max(ref_rss, 1)
        kb_diff = abs_diff / 1024.0
        max_rss_pct_diff = max(max_rss_pct_diff, pct_diff)
        max_rss_kb_diff = max(max_rss_kb_diff, kb_diff)
        # Allow <= 5.0% (or <= 64 KB if tiny <1 MB process shifts 1-4 pages between back-to-back ps invocations)
        if pct_diff > 5.0 and not (ref_rss < 1_048_576 and abs_diff <= 65_536):
            raise AssertionError(
                f"Running service RSS diff exceeded 5%: domain={svc['domain']} "
                f"cli_rss={cli_rss} ref_rss={ref_rss} diff_pct={pct_diff:.3f}%"
            )
    else:
        if cli_rss != 0 or ref_rss != 0:
            raise AssertionError(
                f"Idle service had non-zero RSS: domain={svc['domain']} cli_rss={cli_rss} ref_rss={ref_rss}"
            )

services_rss_mb = sum(int(s["rssBytes"]) for s in cli_services if not s.get("isAppleSystem", False)) / (1024.0 * 1024.0)
orphan_rss_mb = payload["orphanRSSBytes"] / (1024.0 * 1024.0)
total_bg_mb = payload["totalBackgroundRSSBytes"] / (1024.0 * 1024.0)
print(
    f"[M1 Row 1 PASS] Services matched 100%: total={len(cli_services)} "
    f"(user={domain_counts['User LaunchAgent']}, global={domain_counts['Global LaunchAgent']}, "
    f"system={domain_counts['System LaunchDaemon']}), running={running_service_count} "
    f"(multi_pid_trees={multi_proc_tree_count}), services_rss={services_rss_mb:.2f} MB, "
    f"injected_orphan_rss={orphan_rss_mb:.2f} MB, total_non_apple_rss={total_bg_mb:.2f} MB, "
    f"max_rss_diff={max_rss_pct_diff:.4f}% ({max_rss_kb_diff:.1f} KB, threshold <= 5.0%)."
)

# --- ROW 2 ASSERTIONS: Listening TCP ports match lsof 100% ---
for svc in cli_services:
    key = (svc["domain"], svc["label"])
    _ref_running, _ref_rss, ref_ports, _tree_pids = ref_services[key]
    cli_ports = sorted(svc.get("listeningPorts", []))
    if cli_ports != ref_ports:
        raise AssertionError(
            f"Service port mismatch in {svc['domain']}: cli={cli_ports} vs lsof={ref_ports}"
        )

for orph in cli_orphans:
    opid = orph.get("pid")
    cli_oports = sorted(orph.get("listeningPorts", []))
    ref_oports = sorted(lsof_ports_by_pid.get(opid, set())) if opid else []
    if cli_oports != ref_oports:
        raise AssertionError(
            f"Orphan PID {opid} port mismatch: cli={cli_oports} vs lsof={ref_oports}"
        )

cli_all_ports = sorted(
    {pt for item in (cli_services + cli_orphans) for pt in item.get("listeningPorts", [])}
)
tracked_pids = {
    p for (_r, _rss, _pts, tpids) in ref_services.values() for p in tpids
} | {orph["pid"] for orph in cli_orphans if orph.get("pid")}
ref_tracked_ports = sorted(
    {pt for pid in tracked_pids for pt in lsof_ports_by_pid.get(pid, set())}
)
if cli_all_ports != ref_tracked_ports:
    raise AssertionError(
        f"Aggregate listening port set mismatch: cli={cli_all_ports} vs lsof={ref_tracked_ports}"
    )

def root_ancestor_pid(pid: int) -> int:
    seen: set[int] = set()
    cur = pid
    while cur in ps_rows and cur not in seen:
        seen.add(cur)
        ppid = ps_rows[cur][0]
        if ppid <= 1 or ppid not in ps_rows:
            return cur
        cur = ppid
    return pid

def is_apple_or_genuine_gui_app(cmd: str) -> bool:
    low = cmd.lower()
    if low.startswith(("/system/", "/usr/libexec/", "/usr/sbin/", "/sbin/")):
        return True
    if ".xpc/contents/" in low or ".appex/contents/" in low:
        return True
    cleaned = low.replace("/xcode.app/contents/developer/", "/_xcode_cli_developer_/")
    if ".app/contents/" in cleaned and not any(
        interp in cleaned for interp in ("python.app/contents/", "python3.app/contents/", "ruby.app/contents/")
    ):
        return True
    return False

unaccounted_lsof_pids = []
gui_or_apple_lsof_pids = 0
for lpid in sorted(lsof_ports_by_pid.keys()):
    if lpid in tracked_pids or lpid == live_child_pid:
        continue
    if lpid not in ps_rows:
        continue
    _ppid, luid, _rss, lcmd = ps_rows[lpid]
    anc = root_ancestor_pid(lpid)
    anc_cmd = ps_rows[anc][3] if anc in ps_rows else lcmd
    if luid != os.getuid() or is_apple_or_genuine_gui_app(lcmd) or is_apple_or_genuine_gui_app(anc_cmd) or lpid in claimed_all_pids:
        gui_or_apple_lsof_pids += 1
    else:
        unaccounted_lsof_pids.append(lpid)

if unaccounted_lsof_pids:
    raise AssertionError(f"Unaccounted host lsof listener PIDs outside LaunchLens: {unaccounted_lsof_pids}")

print(
    f"[M1 Row 2 PASS] Listening TCP port set matched lsof 100%: "
    f"tracked_unique_ports={len(cli_all_ports)} (ref_lsof_ports={len(ref_tracked_ports)}), "
    f"excluded_gui_or_system_listener_pids={gui_or_apple_lsof_pids}, unaccounted_listeners=0."
)

# --- ROW 3 ASSERTIONS: Orphan precision (2/2 detected, 0 false positives) ---
orphans_by_pid = {o["pid"]: o for o in cli_orphans if o.get("pid") is not None}

if node_pid not in orphans_by_pid:
    raise AssertionError(f"Detached node orphan PID {node_pid} (port {node_port}) was NOT detected!")
if orphans_by_pid[node_pid].get("listeningPorts") != [node_port]:
    raise AssertionError(
        f"Detached node orphan port mismatch: got {orphans_by_pid[node_pid].get('listeningPorts')}, expected [{node_port}]"
    )

if py_pid not in orphans_by_pid:
    raise AssertionError(f"Detached python3 orphan PID {py_pid} (port {py_port}) was NOT detected!")
if orphans_by_pid[py_pid].get("listeningPorts") != [py_port]:
    raise AssertionError(
        f"Detached python3 orphan port mismatch: got {orphans_by_pid[py_pid].get('listeningPorts')}, expected [{py_port}]"
    )

if live_child_pid in orphans_by_pid:
    raise AssertionError(
        f"False positive: live-parent node_modules worker PID {live_child_pid} (ppid={live_child_ppid}) was wrongly flagged as orphan!"
    )

my_uid = os.getuid()
gui_app_false_positives = 0
foreign_uid_false_positives = 0
live_parent_false_positives = 0

for opid, _oitem in orphans_by_pid.items():
    if opid not in ps_rows:
        continue
    oppid, ouid, _orss, ocmd = ps_rows[opid]
    if ouid != my_uid:
        foreign_uid_false_positives += 1
    if oppid != 1:
        live_parent_false_positives += 1
    if is_apple_or_genuine_gui_app(ocmd):
        gui_app_false_positives += 1

if gui_app_false_positives or foreign_uid_false_positives or live_parent_false_positives:
    raise AssertionError(
        f"Orphan false positives detected: gui_app={gui_app_false_positives}, "
        f"foreign_uid={foreign_uid_false_positives}, ppid_ne_1={live_parent_false_positives}"
    )

host_gui_app_proc_count = sum(1 for (_pp, _u, _r, c) in ps_rows.values() if ".app/contents/" in c.lower())
preexisting_orphans = len(orphans_by_pid) - 2

print(
    f"[M1 Row 3 PASS] Orphan detection verified: spawned_orphans_detected=2/2 "
    f"(node port={node_port}, python3 port={py_port}), preexisting_host_orphans={preexisting_orphans}, "
    f"live_parent_node_modules_false_positives=0 (ppid={live_child_ppid}, port={live_child_port}), "
    f"gui_app_false_positives=0 (across {host_gui_app_proc_count} live .app processes), foreign_uid_false_positives=0."
)
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
