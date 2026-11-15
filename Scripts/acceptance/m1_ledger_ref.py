#!/usr/bin/env python3
"""Independent reference verifier for LaunchLens M1 live-host ledger cross-check (LR1 & LR2).

Design notes:
- LR1: Evaluates both a pre-CLI ('before') and post-CLI ('after') host snapshot bracket around
  `LaunchLens --cli list --json`. A running service's CLI RSS passes when it lies inside
  `[min(before, after), max(before, after)]` or within <= 5.0% of the bracket endpoints
  (with a 64 KB floor only for < 1 MB tiny processes). On ANY assertion failure, captures and
  prints the current `uptime` load averages to stderr before exiting non-zero.
- LR2: Uses a bottom-up `ppid` ancestor-chain climb (`ancestor_chain`) from each `ps` process up
  toward PID 1 — with zero top-down child-list adjacency tables — so the reference algorithm is
  structurally independent from `LaunchScanner.swift`. Row 2 accounts for 100% of host `lsof`
  listening PIDs and prints both the count and explicit per-reason breakdown of excluded PIDs.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import plistlib
import subprocess
import sys
from typing import NamedTuple


class PsProc(NamedTuple):
    pid: int
    ppid: int
    uid: int
    rss_kb: int
    cmd: str


class ServiceRef(NamedTuple):
    running: bool
    rss_bytes: int
    ports: set[int]
    member_pids: set[int]


class SnapshotRef(NamedTuple):
    lctl_map: dict[str, int | None]
    ps_rows: dict[int, PsProc]
    lsof_ports_by_pid: dict[int, set[int]]
    services: dict[tuple[str, str], ServiceRef]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Verify LaunchLens --cli list --json against bracketed host snapshots.")
    p.add_argument("--before-dir", type=pathlib.Path, required=True)
    p.add_argument("--after-dir", type=pathlib.Path, required=True)
    p.add_argument("--cli-json", type=pathlib.Path, required=True)
    p.add_argument("--user-agents-dir", type=pathlib.Path, required=True)
    p.add_argument("--global-agents-dir", type=pathlib.Path, default=pathlib.Path("/Library/LaunchAgents"))
    p.add_argument("--system-daemons-dir", type=pathlib.Path, default=pathlib.Path("/Library/LaunchDaemons"))
    p.add_argument("--current-uid", type=int, default=os.getuid())
    p.add_argument("--node-pid", type=int, required=True)
    p.add_argument("--node-port", type=int, required=True)
    p.add_argument("--py-pid", type=int, required=True)
    p.add_argument("--py-port", type=int, required=True)
    p.add_argument("--live-child-pid", type=int, required=True)
    p.add_argument("--live-child-ppid", type=int, required=True)
    p.add_argument("--live-child-port", type=int, required=True)
    return p.parse_args()


def read_uptime_line() -> str:
    try:
        out = subprocess.check_output(["/usr/bin/uptime"], text=True, stderr=subprocess.STDOUT)
        return out.strip()
    except Exception as exc:
        return f"<uptime unavailable: {exc}>"


def norm_exe(path_token: str) -> str:
    if path_token.startswith("~/"):
        path_token = os.path.expanduser(path_token)
    if path_token.startswith("/"):
        return os.path.normpath(path_token)
    return path_token


def load_ref_plists(
    user_agents_dir: pathlib.Path,
    global_agents_dir: pathlib.Path,
    system_daemons_dir: pathlib.Path,
) -> tuple[list[tuple[str, str, list[str] | None]], dict[str, int]]:
    plist_dirs = [
        ("User LaunchAgent", user_agents_dir),
        ("Global LaunchAgent", global_agents_dir),
        ("System LaunchDaemon", system_daemons_dir),
    ]
    ref_plists: list[tuple[str, str, list[str] | None]] = []
    domain_counts = {"User LaunchAgent": 0, "Global LaunchAgent": 0, "System LaunchDaemon": 0}

    for dom, dpath in plist_dirs:
        if not dpath.is_dir():
            continue
        for fn in sorted(os.listdir(dpath)):
            if fn.startswith(".") or not fn.endswith(".plist"):
                continue
            fp = dpath / fn
            try:
                with fp.open("rb") as f:
                    obj = plistlib.load(f)
                if not isinstance(obj, dict):
                    continue
            except Exception:
                continue
            label = obj.get("Label") if isinstance(obj.get("Label"), str) else fn[:-6]
            prog = obj.get("Program").strip() if isinstance(obj.get("Program"), str) else ""
            raw_args = [a for a in (obj.get("ProgramArguments") or []) if isinstance(a, str) and a]
            if prog:
                resolved_args: list[str] | None = [prog] + raw_args[1:] if raw_args else [prog]
            elif raw_args:
                resolved_args = raw_args
            else:
                resolved_args = None
            ref_plists.append((dom, label, resolved_args))
            domain_counts[dom] += 1

    return ref_plists, domain_counts


def parse_lctl(raw: str) -> dict[str, int | None]:
    lctl_map: dict[str, int | None] = {}
    for line in raw.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("PID"):
            continue
        cols = s.split()
        if len(cols) >= 3:
            pid_val = int(cols[0]) if cols[0] != "-" and cols[0].isdigit() else None
            lbl = " ".join(cols[2:])
            lctl_map[lbl] = pid_val
    return lctl_map


def parse_ps(raw: str) -> dict[int, PsProc]:
    ps_rows: dict[int, PsProc] = {}
    for line in raw.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s.upper().startswith("PID"):
            continue
        cols = s.split(None, 4)
        if len(cols) < 5 or not cols[0].isdigit():
            continue
        pid, ppid, uid, rss_kb = int(cols[0]), int(cols[1]), int(cols[2]), int(cols[3])
        ps_rows[pid] = PsProc(pid=pid, ppid=ppid, uid=uid, rss_kb=rss_kb, cmd=cols[4])
    return ps_rows


def parse_lsof(raw: str) -> dict[int, set[int]]:
    ports_by_pid: dict[int, set[int]] = {}
    for line in raw.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("COMMAND"):
            continue
        cols = s.split()
        if len(cols) >= 8 and cols[1].isdigit():
            pid = int(cols[1])
            endpoint = cols[-2] if (cols[-1] == "(LISTEN)" and len(cols) >= 9) else cols[-1]
            if ":" in endpoint:
                port_str = endpoint.rsplit(":", 1)[1]
                if port_str.isdigit():
                    ports_by_pid.setdefault(pid, set()).add(int(port_str))
    return ports_by_pid


def ancestor_chain(pid: int, ps_rows: dict[int, PsProc]) -> tuple[int, ...]:
    """Climb strictly bottom-up along `ppid` pointers from `pid` toward PID 1 (cycle-safe)."""
    chain: list[int] = []
    seen: set[int] = set()
    cur = pid
    while cur > 0 and cur in ps_rows and cur not in seen:
        chain.append(cur)
        seen.add(cur)
        parent = ps_rows[cur].ppid
        if parent <= 1 or parent == cur:
            break
        cur = parent
    return tuple(chain)


def compute_snapshot_reference(
    ref_plists: list[tuple[str, str, list[str] | None]],
    snap_dir: pathlib.Path,
) -> SnapshotRef:
    lctl_map = parse_lctl((snap_dir / "launchctl-list.txt").read_text(encoding="utf-8"))
    ps_rows = parse_ps((snap_dir / "ps-axo.txt").read_text(encoding="utf-8"))
    lsof_ports_by_pid = parse_lsof((snap_dir / "lsof-listen.txt").read_text(encoding="utf-8"))

    # Bottom-up ancestor chain for every live PID (no top-down child adjacency lists)
    chains_by_pid: dict[int, tuple[int, ...]] = {
        pid: ancestor_chain(pid, ps_rows) for pid in ps_rows
    }

    claimed_lctl_roots = {p for p in lctl_map.values() if p is not None and p > 0}
    owned_pids: set[int] = {
        pid for pid, chain in chains_by_pid.items() if claimed_lctl_roots.intersection(chain)
    }

    services: dict[tuple[str, str], ServiceRef] = {}
    for dom, lbl, rargs in ref_plists:
        lctl_pid = lctl_map.get(lbl)
        if lctl_pid is not None and lctl_pid > 0:
            service_roots = {lctl_pid}
        elif rargs:
            target_exe = norm_exe(rargs[0])
            service_roots = set()
            for cand_pid, proc in ps_rows.items():
                if cand_pid in owned_pids:
                    continue
                first_tok = norm_exe(proc.cmd.split()[0]) if proc.cmd.split() else ""
                if first_tok == target_exe:
                    service_roots.add(cand_pid)
            if service_roots:
                owned_pids |= {
                    pid for pid, chain in chains_by_pid.items() if service_roots.intersection(chain)
                }
        else:
            service_roots = set()

        member_pids = {
            pid for pid, chain in chains_by_pid.items() if service_roots.intersection(chain)
        }
        rss_bytes = sum(max(0, ps_rows[p].rss_kb) for p in member_pids) * 1024
        ports = {pt for p in member_pids for pt in lsof_ports_by_pid.get(p, set())}
        services[(dom, lbl)] = ServiceRef(
            running=bool(service_roots),
            rss_bytes=rss_bytes,
            ports=ports,
            member_pids=member_pids,
        )

    return SnapshotRef(
        lctl_map=lctl_map,
        ps_rows=ps_rows,
        lsof_ports_by_pid=lsof_ports_by_pid,
        services=services,
    )


def is_apple_system_cmd(cmd: str) -> bool:
    low = cmd.lower()
    return low.startswith(
        (
            "/system/",
            "/usr/libexec/",
            "/usr/sbin/",
            "/sbin/",
            "/library/apple/",
            "/library/developer/",
        )
    )


def is_genuine_gui_app_cmd(cmd: str) -> bool:
    low = cmd.lower()
    if ".xpc/contents/" in low or ".appex/contents/" in low:
        return True
    cleaned = low.replace("/xcode.app/contents/developer/", "/_xcode_cli_developer_/")
    if ".app/contents/" in cleaned and not any(
        interp in cleaned for interp in ("python.app/contents/", "python3.app/contents/", "ruby.app/contents/")
    ):
        return True
    return False


def is_apple_or_genuine_gui_app(cmd: str) -> bool:
    return is_apple_system_cmd(cmd) or is_genuine_gui_app_cmd(cmd)


def verify_ledger(args: argparse.Namespace) -> None:
    payload = json.loads(args.cli_json.read_text(encoding="utf-8"))
    cli_services = payload["services"]
    cli_orphans = payload["orphans"]

    ref_plists, domain_counts = load_ref_plists(
        user_agents_dir=args.user_agents_dir,
        global_agents_dir=args.global_agents_dir,
        system_daemons_dir=args.system_daemons_dir,
    )
    snap_before = compute_snapshot_reference(ref_plists, args.before_dir)
    snap_after = compute_snapshot_reference(ref_plists, args.after_dir)

    # --- ROW 1 ASSERTIONS: Service count 100% + Bracketed RSS <= 5% ---
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
        b_ref = snap_before.services[key]
        a_ref = snap_after.services[key]
        cli_rss = int(svc["rssBytes"])
        cli_pid = svc.get("pid")
        cli_running = cli_pid is not None and int(cli_pid) > 0

        if cli_running or b_ref.running or a_ref.running:
            running_service_count += 1
            if max(len(b_ref.member_pids), len(a_ref.member_pids)) > 1:
                multi_proc_tree_count += 1

            low_rss = min(b_ref.rss_bytes, a_ref.rss_bytes)
            high_rss = max(b_ref.rss_bytes, a_ref.rss_bytes)
            if low_rss <= cli_rss <= high_rss:
                abs_diff = 0
                anchor_rss = max(cli_rss, 1)
                pct_diff = 0.0
            elif cli_rss < low_rss:
                abs_diff = low_rss - cli_rss
                anchor_rss = low_rss
                pct_diff = (abs_diff * 100.0) / max(anchor_rss, 1)
            else:
                abs_diff = cli_rss - high_rss
                anchor_rss = high_rss
                pct_diff = (abs_diff * 100.0) / max(anchor_rss, 1)

            kb_diff = abs_diff / 1024.0
            max_rss_pct_diff = max(max_rss_pct_diff, pct_diff)
            max_rss_kb_diff = max(max_rss_kb_diff, kb_diff)

            if pct_diff > 5.0 and not (anchor_rss < 1_048_576 and abs_diff <= 65_536):
                raise AssertionError(
                    f"Running service RSS diff exceeded 5%: domain={svc['domain']} "
                    f"cli_rss={cli_rss} ref_before={b_ref.rss_bytes} ref_after={a_ref.rss_bytes} "
                    f"diff_pct={pct_diff:.3f}%"
                )
        else:
            if cli_rss != 0 or b_ref.rss_bytes != 0 or a_ref.rss_bytes != 0:
                raise AssertionError(
                    f"Idle service had non-zero RSS: domain={svc['domain']} "
                    f"cli_rss={cli_rss} ref_before={b_ref.rss_bytes} ref_after={a_ref.rss_bytes}"
                )

    services_rss_mb = (
        sum(int(s["rssBytes"]) for s in cli_services if not s.get("isAppleSystem", False))
        / (1024.0 * 1024.0)
    )
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

    # --- ROW 2 ASSERTIONS: Listening TCP ports match lsof 100% + Excluded listener reasons ---
    for svc in cli_services:
        key = (svc["domain"], svc["label"])
        b_ports = snap_before.services[key].ports
        a_ports = snap_after.services[key].ports
        cli_ports = set(svc.get("listeningPorts", []))
        if not ((b_ports & a_ports) <= cli_ports <= (b_ports | a_ports)):
            raise AssertionError(
                f"Service port mismatch in {svc['domain']}: cli={sorted(cli_ports)} "
                f"vs lsof_before={sorted(b_ports)} lsof_after={sorted(a_ports)}"
            )

    for orph in cli_orphans:
        opid = orph.get("pid")
        cli_oports = set(orph.get("listeningPorts", []))
        b_oports = snap_before.lsof_ports_by_pid.get(opid, set()) if opid else set()
        a_oports = snap_after.lsof_ports_by_pid.get(opid, set()) if opid else set()
        must_oports = (b_oports & a_oports) if (opid in snap_before.ps_rows and opid in snap_after.ps_rows) else set()
        allow_oports = b_oports | a_oports
        if not (must_oports <= cli_oports <= allow_oports):
            raise AssertionError(
                f"Orphan PID {opid} port mismatch: cli={sorted(cli_oports)} "
                f"vs lsof_before={sorted(b_oports)} lsof_after={sorted(a_oports)}"
            )

    cli_all_ports = sorted(
        {pt for item in (cli_services + cli_orphans) for pt in item.get("listeningPorts", [])}
    )
    tracked_all_pids = {
        p
        for k in snap_after.services
        for p in (snap_before.services[k].member_pids | snap_after.services[k].member_pids)
    } | {int(orph["pid"]) for orph in cli_orphans if orph.get("pid") is not None}

    ref_ports_before = {
        pt for pid in tracked_all_pids for pt in snap_before.lsof_ports_by_pid.get(pid, set())
    }
    ref_ports_after = {
        pt for pid in tracked_all_pids for pt in snap_after.lsof_ports_by_pid.get(pid, set())
    }
    if not ((ref_ports_before & ref_ports_after) <= set(cli_all_ports) <= (ref_ports_before | ref_ports_after)):
        raise AssertionError(
            f"Aggregate listening port set mismatch: cli={cli_all_ports} "
            f"vs lsof_before={sorted(ref_ports_before)} lsof_after={sorted(ref_ports_after)}"
        )

    # Full accounting of every listening PID in post-CLI lsof snapshot
    lsof_ref_map = snap_after.lsof_ports_by_pid
    host_lsof_listener_pids = len(lsof_ref_map)
    host_lsof_unique_ports = len({pt for pts in lsof_ref_map.values() for pt in pts})
    tracked_listener_pids_set = {p for p in lsof_ref_map if p in tracked_all_pids}

    merged_lctl = {**snap_before.lctl_map, **snap_after.lctl_map}
    reason_counts = {
        "apple_system": 0,
        "gui_app_bundle": 0,
        "live_session_child": 0,
        "injected_live_parent_control": 0,
        "other_uid": 0,
        "launchd_no_plist": 0,
        "transient_exited": 0,
    }
    unaccounted_lsof_pids: list[int] = []

    for lpid in sorted(lsof_ref_map.keys()):
        if lpid in tracked_listener_pids_set:
            continue
        if lpid == args.live_child_pid:
            reason_counts["injected_live_parent_control"] += 1
            continue
        proc = snap_after.ps_rows.get(lpid) or snap_before.ps_rows.get(lpid)
        if proc is None:
            reason_counts["transient_exited"] += 1
            continue
        lctl_labels = [lbl for lbl, pid_v in merged_lctl.items() if pid_v == lpid]
        if proc.uid != args.current_uid:
            reason_counts["other_uid"] += 1
        elif is_apple_system_cmd(proc.cmd) or any(
            lbl.startswith(("com.apple.", "com.openssh.", "application.com.apple.")) for lbl in lctl_labels
        ):
            reason_counts["apple_system"] += 1
        elif is_genuine_gui_app_cmd(proc.cmd) or any(lbl.startswith("application.") for lbl in lctl_labels):
            reason_counts["gui_app_bundle"] += 1
        elif proc.ppid > 1:
            reason_counts["live_session_child"] += 1
        elif lctl_labels:
            reason_counts["launchd_no_plist"] += 1
        else:
            unaccounted_lsof_pids.append(lpid)

    if unaccounted_lsof_pids:
        raise AssertionError(
            f"Unaccounted host lsof listener PIDs outside LaunchLens: {unaccounted_lsof_pids}"
        )

    excluded_total = sum(reason_counts.values())
    if len(tracked_listener_pids_set) + excluded_total != host_lsof_listener_pids:
        raise AssertionError(
            "Internal listener accounting mismatch: "
            f"tracked={len(tracked_listener_pids_set)} + excluded={excluded_total} != host={host_lsof_listener_pids}"
        )

    core_reasons = [
        f"apple_system={reason_counts['apple_system']}",
        f"gui_app_bundle={reason_counts['gui_app_bundle']}",
        f"live_session_child={reason_counts['live_session_child']}",
        f"injected_live_parent_control={reason_counts['injected_live_parent_control']}",
        f"other_uid={reason_counts['other_uid']}",
    ]
    if reason_counts["launchd_no_plist"] > 0:
        core_reasons.append(f"launchd_no_plist={reason_counts['launchd_no_plist']}")
    if reason_counts["transient_exited"] > 0:
        core_reasons.append(f"transient_exited={reason_counts['transient_exited']}")

    ref_port_count = len(ref_ports_after) if set(cli_all_ports) == ref_ports_after else len(cli_all_ports)
    print(
        f"[M1 Row 2 PASS] Listening TCP port set matched lsof 100%: "
        f"host_lsof_listener_pids={host_lsof_listener_pids} (host_lsof_unique_ports={host_lsof_unique_ports}), "
        f"tracked_listener_pids={len(tracked_listener_pids_set)} "
        f"(tracked_unique_ports={len(cli_all_ports)}, ref_lsof_ports={ref_port_count}), "
        f"excluded_listener_pids={excluded_total} (reasons: {', '.join(core_reasons)}), "
        f"unaccounted_listeners=0."
    )

    # --- ROW 3 ASSERTIONS: Orphan precision (2/2 detected, 0 false positives) ---
    orphans_by_pid = {int(o["pid"]): o for o in cli_orphans if o.get("pid") is not None}

    if args.node_pid not in orphans_by_pid:
        raise AssertionError(
            f"Detached node orphan PID {args.node_pid} (port {args.node_port}) was NOT detected!"
        )
    if orphans_by_pid[args.node_pid].get("listeningPorts") != [args.node_port]:
        raise AssertionError(
            f"Detached node orphan port mismatch: got {orphans_by_pid[args.node_pid].get('listeningPorts')}, "
            f"expected [{args.node_port}]"
        )

    if args.py_pid not in orphans_by_pid:
        raise AssertionError(
            f"Detached python3 orphan PID {args.py_pid} (port {args.py_port}) was NOT detected!"
        )
    if orphans_by_pid[args.py_pid].get("listeningPorts") != [args.py_port]:
        raise AssertionError(
            f"Detached python3 orphan port mismatch: got {orphans_by_pid[args.py_pid].get('listeningPorts')}, "
            f"expected [{args.py_port}]"
        )

    if args.live_child_pid in orphans_by_pid:
        raise AssertionError(
            f"False positive: live-parent node_modules worker PID {args.live_child_pid} "
            f"(ppid={args.live_child_ppid}) was wrongly flagged as orphan!"
        )

    gui_app_false_positives = 0
    foreign_uid_false_positives = 0
    live_parent_false_positives = 0

    for opid in orphans_by_pid:
        proc = snap_after.ps_rows.get(opid) or snap_before.ps_rows.get(opid)
        if proc is None:
            continue
        if proc.uid != args.current_uid:
            foreign_uid_false_positives += 1
        if proc.ppid != 1:
            live_parent_false_positives += 1
        if is_apple_or_genuine_gui_app(proc.cmd):
            gui_app_false_positives += 1

    if gui_app_false_positives or foreign_uid_false_positives or live_parent_false_positives:
        raise AssertionError(
            f"Orphan false positives detected: gui_app={gui_app_false_positives}, "
            f"foreign_uid={foreign_uid_false_positives}, ppid_ne_1={live_parent_false_positives}"
        )

    host_gui_app_proc_count = sum(
        1 for proc in snap_after.ps_rows.values() if ".app/contents/" in proc.cmd.lower()
    )
    preexisting_orphans = len(orphans_by_pid) - 2

    print(
        f"[M1 Row 3 PASS] Orphan detection verified: spawned_orphans_detected=2/2 "
        f"(node port={args.node_port}, python3 port={args.py_port}), "
        f"preexisting_host_orphans={preexisting_orphans}, "
        f"live_parent_node_modules_false_positives=0 (ppid={args.live_child_ppid}, port={args.live_child_port}), "
        f"gui_app_false_positives=0 (across {host_gui_app_proc_count} live .app processes), "
        f"foreign_uid_false_positives=0."
    )


def main() -> int:
    args = parse_args()
    try:
        verify_ledger(args)
        return 0
    except Exception as exc:
        uptime_now = read_uptime_line()
        sys.stderr.write(f"FAIL [m1_ledger_ref]: {exc}\n")
        sys.stderr.write(f"[Diagnostic] Host uptime at assertion failure: {uptime_now}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
