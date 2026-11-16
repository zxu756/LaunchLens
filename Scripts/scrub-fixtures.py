#!/usr/bin/env python3
"""Repeatable deterministic privacy scrubber for LaunchLens macOS host fixtures (LR3).

Usage:
  # 1. Capture live read-only raw outputs into a $TMPDIR folder (never inside the repo):
  python3 Scripts/scrub-fixtures.py --capture-live-to "$TMPDIR/launchlens-raw"

  # 2. Deterministically scrub a raw capture directory into Tests/Fixtures:
  python3 Scripts/scrub-fixtures.py \
      --raw-dir "$TMPDIR/launchlens-raw" \
      --out-dir Tests/Fixtures \
      --inject-test-orphans
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import pwd
import re
import subprocess
import sys


APPLE_LABEL_PREFIXES = ("com.apple.", "com.openssh.")
APPLE_PATH_PREFIXES = (
    "/sbin/",
    "/usr/sbin/",
    "/usr/libexec/",
    "/system/library/",
    "/system/applications/",
    "/library/apple/",
    "/library/developer/",
)
SAFE_LSOF_COMMANDS = {"launchd", "rapportd", "ControlCe", "Python", "python3", "node"}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Deterministic scrubber for LaunchLens macOS captures.")
    p.add_argument(
        "--capture-live-to",
        type=pathlib.Path,
        help="Capture live read-only launchctl/ps/lsof outputs into this external temp directory.",
    )
    p.add_argument("--raw-dir", type=pathlib.Path, help="Directory containing raw launchctl-list.txt, ps-axo.txt, lsof-listen.txt.")
    p.add_argument("--out-dir", type=pathlib.Path, help="Destination directory for scrubbed fixture files.")
    p.add_argument("--captured-at", type=str, default=None, help="ISO-8601 UTC capture timestamp (defaults to capture-meta.json or raw file mtime).")
    p.add_argument("--date-tag", type=str, default="2026-11-15", help="Date suffix for output filenames (default: 2026-11-15).")
    p.add_argument(
        "--inject-test-orphans",
        action="store_true",
        help="Append 2 documented test orphan rows (orphan_http_probe.py & orphan_mcp_probe.js) and record their exact 1-based line numbers in headers.",
    )
    return p.parse_args()


def capture_live_readonly(dest_dir: pathlib.Path, repo_root: pathlib.Path) -> None:
    dest_resolved = dest_dir.expanduser().resolve()
    repo_resolved = repo_root.resolve()
    if dest_resolved == repo_resolved or str(dest_resolved).startswith(str(repo_resolved) + os.sep):
        raise RuntimeError(f"Refusing to write raw host outputs inside repository ({repo_resolved}); use $TMPDIR.")

    dest_resolved.mkdir(parents=True, exist_ok=True)
    captured_at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    lctl_raw = subprocess.check_output(["/bin/launchctl", "list"], text=True)
    ps_raw = subprocess.check_output(["/bin/ps", "-axo", "pid,ppid,uid,rss,args"], text=True)
    lsof_raw = subprocess.check_output(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], text=True)

    (dest_resolved / "launchctl-list.txt").write_text(lctl_raw, encoding="utf-8")
    (dest_resolved / "ps-axo.txt").write_text(ps_raw, encoding="utf-8")
    (dest_resolved / "lsof-listen.txt").write_text(lsof_raw, encoding="utf-8")
    (dest_resolved / "capture-meta.json").write_text(
        json.dumps(
            {
                "captured_at": captured_at,
                "commands": {
                    "launchctl": "/bin/launchctl list",
                    "ps": "/bin/ps -axo pid,ppid,uid,rss,args",
                    "lsof": "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN",
                },
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Captured read-only raw host outputs at {captured_at} into temporary directory.")


def resolve_captured_at(raw_dir: pathlib.Path, explicit_ts: str | None) -> str:
    if explicit_ts:
        return explicit_ts.strip()
    meta_file = raw_dir / "capture-meta.json"
    if meta_file.is_file():
        meta = json.loads(meta_file.read_text(encoding="utf-8"))
        if isinstance(meta.get("captured_at"), str) and meta["captured_at"].strip():
            return meta["captured_at"].strip()
    ps_file = raw_dir / "ps-axo.txt"
    ts = dt.datetime.fromtimestamp(ps_file.stat().st_mtime, tz=dt.timezone.utc)
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def extract_apple_executable_only(cmd: str) -> str:
    """Keep only the Apple system executable path and strip runtime arguments."""
    bundle_match = re.match(
        r"^((?:/System|/Library)[^\n]*?\.(?:app|xpc|appex|bundle)/Contents/MacOS/[^/\s]+)",
        cmd,
    )
    if bundle_match:
        return bundle_match.group(1)
    first_tok = cmd.split()[0] if cmd.split() else cmd
    return first_tok


def scrub_captures(
    raw_dir: pathlib.Path,
    out_dir: pathlib.Path,
    captured_at: str,
    date_tag: str,
    inject_test_orphans: bool,
) -> None:
    lctl_in = (raw_dir / "launchctl-list.txt").read_text(encoding="utf-8")
    ps_in = (raw_dir / "ps-axo.txt").read_text(encoding="utf-8")
    lsof_in = (raw_dir / "lsof-listen.txt").read_text(encoding="utf-8")

    # 1. Scrub launchctl list and record PID -> scrubbed agent index
    desktop_label_map: dict[str, str] = {}
    agent_label_map: dict[str, str] = {}
    agent_pid_to_idx: dict[int, int] = {}
    lctl_body_lines: list[str] = ["PID\tStatus\tLabel"]

    for raw_line in lctl_in.splitlines():
        s = raw_line.strip()
        if not s or s.startswith("#") or s.startswith("PID"):
            continue
        cols = s.split(None, 2)
        if len(cols) < 3:
            continue
        pid_tok, status_tok, label = cols[0], cols[1], cols[2].strip()
        pid_val = int(pid_tok) if pid_tok.isdigit() else None

        if label.startswith(APPLE_LABEL_PREFIXES):
            scrubbed_label = label
        elif label.startswith("application.com.apple."):
            parts = label.split(".")
            app_seg = parts[3] if len(parts) > 3 else "App"
            scrubbed_label = f"application.com.apple.{app_seg}.1000.1001"
        elif label.startswith("application."):
            if label not in desktop_label_map:
                desktop_label_map[label] = f"application.com.example.desktop-app.{len(desktop_label_map) + 1:02d}"
            scrubbed_label = desktop_label_map[label]
        else:
            if label not in agent_label_map:
                idx_num = len(agent_label_map) + 1
                agent_label_map[label] = f"com.example.agent.{idx_num:02d}"
            scrubbed_label = agent_label_map[label]
            idx_num = int(scrubbed_label.rsplit(".", 1)[1])
            if pid_val is not None and pid_val > 0:
                agent_pid_to_idx[pid_val] = idx_num

        lctl_body_lines.append(f"{pid_tok}\t{status_tok}\t{scrubbed_label}")

    # 2. Parse and scrub ps -axo pid,ppid,uid,rss,args
    raw_ps_entries: list[tuple[int, int, int, int, str]] = []
    human_uids_seen: list[int] = []
    used_pids: set[int] = set()

    for raw_line in ps_in.splitlines():
        s = raw_line.strip()
        if not s or s.startswith("#") or s.upper().startswith("PID"):
            continue
        cols = s.split(None, 4)
        if len(cols) < 5 or not cols[0].isdigit():
            continue
        pid, ppid, uid, rss = int(cols[0]), int(cols[1]), int(cols[2]), int(cols[3])
        cmd = cols[4].strip()
        raw_ps_entries.append((pid, ppid, uid, rss, cmd))
        used_pids.add(pid)
        if uid >= 500 and uid not in human_uids_seen:
            human_uids_seen.append(uid)

    uid_map: dict[int, int] = {}
    if 501 in human_uids_seen:
        uid_map[501] = 501
        next_uid = 502
        for u in human_uids_seen:
            if u != 501:
                uid_map[u] = next_uid
                next_uid += 1
    else:
        for idx, u in enumerate(human_uids_seen):
            uid_map[u] = 501 + idx

    app_bundle_map: dict[str, int] = {}
    sysdaemon_map: dict[str, int] = {}
    script_map: dict[str, int] = {}
    helper_map: dict[str, int] = {}

    def map_app_idx(key: str) -> int:
        if key not in app_bundle_map:
            app_bundle_map[key] = len(app_bundle_map) + 1
        return app_bundle_map[key]

    def map_script_idx(key: str) -> int:
        if key not in script_map:
            script_map[key] = len(script_map) + 1
        return script_map[key]

    def map_helper_idx(key: str) -> int:
        if key not in helper_map:
            helper_map[key] = len(helper_map) + 1
        return helper_map[key]

    def scrub_ps_command(pid: int, ppid: int, uid: int, cmd: str) -> str:
        if pid in agent_pid_to_idx:
            return f"/opt/example/services/com-example-agent-{agent_pid_to_idx[pid]:02d}"

        low = cmd.lower()
        first_tok = cmd.split()[0] if cmd.split() else cmd
        first_base = os.path.basename(first_tok.lstrip("-")).lower()

        # Apple OS binaries & frameworks -> strip trailing arguments
        if low.startswith(APPLE_PATH_PREFIXES):
            return extract_apple_executable_only(cmd)

        # Standard shells & POSIX system utilities
        if first_tok in ("-zsh", "-bash", "-sh"):
            return first_tok
        if first_base in ("zsh", "bash", "sh", "dash", "login", "ps", "log", "perl", "sleep", "true"):
            if first_tok.startswith(("/bin/", "/usr/bin/")):
                return first_tok
            return first_base

        # Xcode toolchain binaries & Xcode Python.app
        if low.startswith("/applications/xcode.app/contents/developer/"):
            if "python.app/contents/macos/python" in low:
                s_idx = map_script_idx(cmd)
                return (
                    "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/"
                    f"Versions/3.9/Resources/Python.app/Contents/MacOS/Python /opt/example/workspace/script_{s_idx:02d}.py"
                )
            exe_only = cmd.split()[0]
            tool_base = re.sub(r"[^A-Za-z0-9._+-]", "", os.path.basename(exe_only)) or "xcode-tool"
            return (
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/"
                f"usr/bin/{tool_base}"
            )

        # Genuine GUI .app / .appex / .xpc bundles (non-Apple, non-Xcode, non-CLI Python.app/Ruby.app)
        app_m = re.search(r"([^/]+)\.app/contents/", low)
        if app_m and app_m.group(1) not in ("python", "python3", "ruby", "xcode"):
            app_num = map_app_idx(app_m.group(1))
            if ".appex/contents/" in low:
                return (
                    f"/Applications/ExampleDesktopApp{app_num:02d}.app/Contents/PlugIns/"
                    f"Extension{app_num:02d}.appex/Contents/MacOS/Extension{app_num:02d}"
                )
            if ".xpc/contents/" in low:
                return (
                    f"/Applications/ExampleDesktopApp{app_num:02d}.app/Contents/XPCServices/"
                    f"Service{app_num:02d}.xpc/Contents/MacOS/Service{app_num:02d}"
                )
            if "helper" in low:
                return (
                    f"/Applications/ExampleDesktopApp{app_num:02d}.app/Contents/Frameworks/"
                    f"ExampleDesktopApp{app_num:02d} Helper.app/Contents/MacOS/ExampleDesktopApp{app_num:02d} Helper"
                )
            return f"/Applications/ExampleDesktopApp{app_num:02d}.app/Contents/MacOS/ExampleDesktopApp{app_num:02d}"

        if ".xpc/contents/" in low:
            h_num = map_helper_idx(cmd.split(".xpc/")[0])
            return f"/Library/Application Support/ExampleVendor/Service{h_num:02d}.xpc/Contents/MacOS/Service{h_num:02d}"

        # Root third-party system daemons
        if uid == 0:
            key = cmd.split()[0]
            if key not in sysdaemon_map:
                sysdaemon_map[key] = len(sysdaemon_map) + 1
            return f"/Library/PrivilegedHelperTools/com.example.sysdaemon.{sysdaemon_map[key]:02d}"

        # CLI scripting runtimes with live parent (PPID > 1): keep runtime class, scrub script path
        if ppid > 1:
            if "python.app/contents/macos/python" in low:
                s_idx = map_script_idx(cmd)
                return (
                    "/opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/"
                    f"Resources/Python.app/Contents/MacOS/Python /opt/example/workspace/task_{s_idx:02d}.py"
                )
            if first_base in ("python", "python3") or first_base.startswith("python3."):
                s_idx = map_script_idx(cmd)
                return f"/opt/homebrew/bin/python3 /opt/example/workspace/task_{s_idx:02d}.py"
            if first_base in ("node", "npm", "npx", "bun", "deno"):
                s_idx = map_script_idx(cmd)
                return f"/opt/homebrew/bin/node /opt/example/workspace/worker_{s_idx:02d}.js"
            if first_base in ("uv", "uvx"):
                s_idx = map_script_idx(cmd)
                return f"/opt/homebrew/bin/uv run /opt/example/workspace/tool_{s_idx:02d}.py"

        # Any remaining user binary / helper path
        h_num = map_helper_idx(first_tok)
        return f"/opt/example/user-bin/helper-{h_num:02d}"

    ps_body_lines: list[str] = ["  PID  PPID   UID    RSS ARGS"]
    for pid, ppid, uid, rss, cmd in raw_ps_entries:
        mapped_uid = uid_map.get(uid, uid)
        scrubbed_cmd = scrub_ps_command(pid, ppid, mapped_uid, cmd)
        ps_body_lines.append(f"{pid:5d} {ppid:5d} {mapped_uid:5d} {rss:6d} {scrubbed_cmd}")

    # 3. Parse and scrub lsof -nP -iTCP -sTCP:LISTEN
    lsof_cmd_map: dict[str, str] = {}
    lsof_body_lines: list[str] = ["COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME"]
    for raw_line in lsof_in.splitlines():
        s = raw_line.strip()
        if not s or s.startswith("#") or s.startswith("COMMAND"):
            continue
        cols = s.split()
        if len(cols) < 9 or not cols[1].isdigit():
            continue
        raw_cmd_tok = cols[0]
        pid_tok = cols[1]
        raw_user = cols[2]
        fd_tok = cols[3]
        type_tok = cols[4]
        size_tok = cols[6]
        node_tok = cols[7]
        endpoint_tok = " ".join(cols[8:])

        if raw_user == "root" or raw_user.startswith("_"):
            mapped_user = raw_user
        else:
            mapped_user = "devuser"

        if raw_cmd_tok in SAFE_LSOF_COMMANDS:
            mapped_cmd = raw_cmd_tok
        else:
            if raw_cmd_tok not in lsof_cmd_map:
                lsof_cmd_map[raw_cmd_tok] = f"svc{len(lsof_cmd_map) + 1:02d}"
            mapped_cmd = lsof_cmd_map[raw_cmd_tok]

        lsof_body_lines.append(
            f"{mapped_cmd:<9s} {int(pid_tok):5d} {mapped_user:<7s} {fd_tok:<4s} {type_tok:<6s} "
            f"0x1000000000000000 {size_tok:>8s} {node_tok:<4s} {endpoint_tok}"
        )

    # 4. Optional deterministic test orphan rows (--inject-test-orphans)
    HEADER_LINE_COUNT = 5  # Every output file has exactly 5 '# ...' header lines before line 6 (column header)

    if inject_test_orphans:
        if 23500 not in used_pids and 23501 not in used_pids:
            probe_py_pid, probe_node_pid = 23500, 23501
        else:
            base_pid = (max(used_pids) if used_pids else 20000) + 100
            probe_py_pid, probe_node_pid = base_pid, base_pid + 1

        ps_line_py = HEADER_LINE_COUNT + len(ps_body_lines) + 1
        ps_body_lines.append(
            f"{probe_py_pid:5d}     1   501   9392 "
            "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/"
            "Versions/3.9/Resources/Python.app/Contents/MacOS/Python "
            "/opt/dev/project-a/orphan_http_probe.py --port 63767"
        )
        ps_line_node = HEADER_LINE_COUNT + len(ps_body_lines) + 1
        ps_body_lines.append(
            f"{probe_node_pid:5d}     1   501  38208 "
            "/opt/homebrew/bin/node /opt/dev/project-b/orphan_mcp_probe.js --port 63768"
        )

        lsof_line_py = HEADER_LINE_COUNT + len(lsof_body_lines) + 1
        lsof_body_lines.append(
            f"{'Python':<9s} {probe_py_pid:5d} {'devuser':<7s} {'3u':<4s} {'IPv4':<6s} "
            "0x1000000000000000      0t0 TCP  127.0.0.1:63767 (LISTEN)"
        )
        lsof_line_node = HEADER_LINE_COUNT + len(lsof_body_lines) + 1
        lsof_body_lines.append(
            f"{'node':<9s} {probe_node_pid:5d} {'devuser':<7s} {'12u':<4s} {'IPv4':<6s} "
            "0x1000000000000000      0t0 TCP  127.0.0.1:63768 (LISTEN)"
        )

        ps_added_note = (
            f"lines {ps_line_py}-{ps_line_node} (PID {probe_py_pid} orphan_http_probe.py on port 63767 and "
            f"PID {probe_node_pid} orphan_mcp_probe.js on port 63768, appended by Scripts/scrub-fixtures.py --inject-test-orphans "
            "for PPID=1 orphan correlation tests)"
        )
        lsof_added_note = (
            f"lines {lsof_line_py}-{lsof_line_node} (PID {probe_py_pid} TCP 127.0.0.1:63767 and "
            f"PID {probe_node_pid} TCP 127.0.0.1:63768, appended by Scripts/scrub-fixtures.py --inject-test-orphans "
            "to pair with the two test orphan rows in macos-ps-axo)"
        )
    else:
        ps_added_note = "none (0 lines added for testing)"
        lsof_added_note = "none (0 lines added for testing)"

    lctl_headers = [
        "# Scrubbed real-machine capture (macOS arm64, generated by Scripts/scrub-fixtures.py)",
        "# Capture command: /bin/launchctl list",
        f"# Capture timestamp: {captured_at}",
        "# Scrubbing rules: com.apple.* and com.openssh.* labels preserved; application.com.apple.* instance IDs normalized; third-party application.* labels -> application.com.example.desktop-app.NN; third-party service labels -> com.example.agent.NN",
        "# Test-added lines: none (0 lines added for testing)",
    ]
    ps_headers = [
        "# Scrubbed real-machine capture (macOS arm64, generated by Scripts/scrub-fixtures.py)",
        "# Capture command: /bin/ps -axo pid,ppid,uid,rss,args",
        f"# Capture timestamp: {captured_at}",
        "# Scrubbing rules: human UIDs >=500 -> 501+; Apple OS binaries keep executable path with user args stripped; third-party .app/.appex/.xpc bundles -> ExampleDesktopAppNN; launchctl-claimed user agents -> /opt/example/services/com-example-agent-NN; root helpers -> /Library/PrivilegedHelperTools/com.example.sysdaemon.NN; user script/helper paths -> /opt/example/{workspace,user-bin}/*",
        f"# Test-added lines: {ps_added_note}",
    ]
    lsof_headers = [
        "# Scrubbed real-machine capture (macOS arm64, generated by Scripts/scrub-fixtures.py)",
        "# Capture command: /usr/sbin/lsof -nP -iTCP -sTCP:LISTEN",
        f"# Capture timestamp: {captured_at}",
        "# Scrubbing rules: non-system USER -> devuser; kernel DEVICE pointers -> 0x1000000000000000; third-party COMMAND names -> svcNN (preserving launchd/rapportd/ControlCe/Python/python3/node); PID and TCP port endpoints preserved",
        f"# Test-added lines: {lsof_added_note}",
    ]

    assert len(lctl_headers) == HEADER_LINE_COUNT
    assert len(ps_headers) == HEADER_LINE_COUNT
    assert len(lsof_headers) == HEADER_LINE_COUNT

    outputs = {
        f"macos-launchctl-list-{date_tag}.txt": "\n".join(lctl_headers + lctl_body_lines) + "\n",
        f"macos-ps-axo-{date_tag}.txt": "\n".join(ps_headers + ps_body_lines) + "\n",
        f"macos-lsof-listen-{date_tag}.txt": "\n".join(lsof_headers + lsof_body_lines) + "\n",
    }

    # 5. Mandatory privacy verification before writing output files
    mac_home_prefix = "/" + "Users" + "/"
    host_username = pwd.getpwuid(os.getuid()).pw_name
    for fname, content in outputs.items():
        if mac_home_prefix in content:
            raise RuntimeError(f"Privacy check failed on {fname}: contains macOS home path prefix")
        if "/var/folders/" in content or "/private/var/" in content or ".agy-coder" in content:
            raise RuntimeError(f"Privacy check failed on {fname}: contains temp/job path")
        if re.search(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", content):
            raise RuntimeError(f"Privacy check failed on {fname}: contains email-like token")
        secret_prefixes = ("sk" + "-", "ghp" + "_", "AK" + "IA")
        if any(tok in content for tok in secret_prefixes):
            raise RuntimeError(f"Privacy check failed on {fname}: contains secret-like prefix")
        if len(host_username) >= 2 and re.search(rf"(?<![A-Za-z0-9]){re.escape(host_username)}(?![A-Za-z0-9])", content):
            raise RuntimeError(f"Privacy check failed on {fname}: contains host username token")

    out_dir.mkdir(parents=True, exist_ok=True)
    for fname, content in outputs.items():
        (out_dir / fname).write_text(content, encoding="utf-8")


def main() -> int:
    args = parse_args()
    repo_root = pathlib.Path(__file__).resolve().parent.parent

    if args.capture_live_to is not None:
        capture_live_readonly(args.capture_live_to, repo_root=repo_root)
        if args.out_dir is None:
            return 0
        raw_dir = args.capture_live_to
    else:
        if args.raw_dir is None:
            sys.stderr.write("Error: --raw-dir (or --capture-live-to) is required.\n")
            return 2
        raw_dir = args.raw_dir

    if args.out_dir is None:
        sys.stderr.write("Error: --out-dir is required when scrubbing.\n")
        return 2

    captured_at = resolve_captured_at(raw_dir, args.captured_at)
    scrub_captures(
        raw_dir=raw_dir,
        out_dir=args.out_dir,
        captured_at=captured_at,
        date_tag=args.date_tag,
        inject_test_orphans=args.inject_test_orphans,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
