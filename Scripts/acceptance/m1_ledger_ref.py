#!/usr/bin/env python3
"""Independent reference verifier for LaunchLens M1 live-host ledger cross-check (LR1 & LR2).

Design notes:
- LR1: Evaluates both a pre-CLI ('before') and post-CLI ('after') host snapshot bracket around
  `LaunchLens --cli list --json` for every running service AND for aggregate `orphanRSSBytes`.
  * Width cap: if any running service's or `orphanRSSBytes`'s before/after reference values differ
    by > 25.0% (and absolute difference > 64 KB small-amount exemption), that round's sample is
    discarded and the full `before -> LaunchLens -> after` triple sample is re-taken, up to 3
    retries (1 initial round + up to 3 retries = 4 rounds max). If still unstable after all retries,
    verification FAILS (exit 1, never skipped or passed) and prints every round's before/after
    reference values and host `uptime`.
  * Stable bracket evaluation: when bracket width is <= 25.0% (or <= 64 KB small-process floor),
    CLI RSS inside `[min(before, after), max(before, after)]` records 0.0000% diff, and outside
    endpoints must be within <= 5.0% (with a 64 KB floor only for < 1 MB tiny processes).
  * On ANY assertion failure, captures and prints host `uptime` load averages to stderr.
- LR2: Uses a bottom-up `ppid` ancestor-chain climb (`ancestor_chain`) from each `ps` process up
  toward PID 1 — with zero top-down child adjacency lists — so the reference algorithm is
  structurally independent from `LaunchScanner.swift`. Row 2 accounts for 100% of host `lsof`
  listening PIDs and prints both the count and explicit per-reason breakdown of excluded PIDs.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import plistlib
import shlex
import subprocess
import sys
import time
from typing import Callable, NamedTuple

MAX_BRACKET_SPAN_PCT = 25.0
MAX_ENDPOINT_DIFF_PCT = 5.0
SMALL_PROCESS_MAX_RSS_BYTES = 1_048_576  # 1 MB
SMALL_DIFF_EXEMPT_BYTES = 65_536  # 64 KB

EXACT_DEV_DAEMON_BASENAMES = frozenset(
    {
        "codex",
        "claude",
        "opencode",
        "opencode-cli",
        "vibe",
        "ollama",
        "llama-server",
        "whisper-server",
        "playwright",
        "chromium",
        "chromedriver",
        "geckodriver",
        "workerd",
        "uvicorn",
        "gunicorn",
        "celery",
        "jupyter",
        "jupyter-lab",
        "jupyter-notebook",
        "streamlit",
        "gradio",
        "vite",
        "esbuild",
        "webpack",
        "next-server",
        "mcp-proxy",
        "fastmcp",
        "ngrok",
        "cloudflared",
        "redis-server",
        "postgres",
        "mysqld",
        "mariadbd",
        "mongod",
        "caddy",
    }
)

CLI_FRAMEWORK_INTERPRETER_BUNDLES = frozenset({"python.app", "python3.app", "ruby.app"})
SHELL_BASENAMES = frozenset({"sh", "bash", "zsh", "dash", "fish"})


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
    orphans: dict[int, ServiceRef]
    orphan_rss_bytes: int


class RoundSample(NamedTuple):
    before_dir: pathlib.Path
    after_dir: pathlib.Path
    cli_json_path: pathlib.Path
    uptime_line: str


class BracketInstabilityError(AssertionError):
    """Raised when one or more reference brackets exceed the 25% width cap across all allowed rounds."""


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Verify LaunchLens --cli list --json against width-capped bracketed host snapshots."
    )
    p.add_argument("--before-dir", type=pathlib.Path, default=None)
    p.add_argument("--after-dir", type=pathlib.Path, default=None)
    p.add_argument("--cli-json", type=pathlib.Path, default=None)
    p.add_argument(
        "--round-dirs",
        type=pathlib.Path,
        nargs="+",
        default=None,
        help="Sequence of pre-captured round directories (each containing before/, after/, cli.json).",
    )
    p.add_argument(
        "--live-capture",
        action="store_true",
        help="Capture live before -> LaunchLens -> after triple samples with automatic resampling on >25% bracket drift.",
    )
    p.add_argument("--bin-path", type=pathlib.Path, default=None)
    p.add_argument("--ledger-dir", type=pathlib.Path, default=None)
    p.add_argument("--work-dir", type=pathlib.Path, default=None)
    p.add_argument(
        "--max-retries",
        type=int,
        default=None,
        help="Max retries when a bracket exceeds 25%% (default: 3 for --live-capture/--round-dirs, 0 for single --before-dir).",
    )
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
    tok = path_token.strip().strip("\"'")
    if tok.startswith("~/") or tok == "~":
        tok = os.path.expanduser(tok)
    if tok.startswith("/"):
        return os.path.normpath(tok)
    return tok


def split_exe_and_args(command: str) -> tuple[str, list[str]]:
    """Split a `ps` command line into `(executable, args)`, preserving spaces in macOS bundle/Support paths."""
    trimmed = command.strip()
    if not trimmed:
        return "", []

    if trimmed[0] in ("\"", "'"):
        q = trimmed[0]
        end_q = trimmed.find(q, 1)
        if end_q != -1:
            exe = trimmed[1:end_q]
            rest = trimmed[end_q + 1 :].strip()
            return unwrap_env(exe, tokenize_args(rest))

    if not (trimmed.startswith("/") or trimmed.startswith("~/")):
        parts = trimmed.split(None, 1)
        exe = parts[0] if parts else ""
        rest = parts[1].strip() if len(parts) > 1 else ""
        return unwrap_env(exe, tokenize_args(rest))

    markers = (".app/", ".xpc/", ".appex/", ".framework/", ".bundle/", "/contents/", "support/")
    script_exts = (".py", ".js", ".mjs", ".cjs", ".ts", ".rb", ".pl", ".sh", ".jar")
    pos = 0
    while pos < len(trimmed):
        sp = trimmed.find(" ", pos)
        if sp == -1:
            return unwrap_env(trimmed, [])
        prefix = trimmed[:sp]
        after = trimmed[sp + 1 :].lstrip(" ")
        if not after or after.startswith(("-", "/", "~/")):
            return unwrap_env(prefix, tokenize_args(after))

        boundary = len(after)
        for sep in (" -", " /"):
            idx = after.find(sep)
            if idx != -1:
                boundary = min(boundary, idx)
        cand = after[:boundary].lower()
        if any(m in cand for m in markers):
            pos = sp + 1
            continue

        low_prefix = prefix.lower()
        macos_idx = low_prefix.rfind("/contents/macos/")
        if macos_idx != -1:
            tail = low_prefix[macos_idx + len("/contents/macos/") :]
            if "/" not in tail:
                next_word = after.split(None, 1)[0].lower()
                if "/" not in next_word and not next_word.endswith(script_exts):
                    pos = sp + 1
                    continue

        return unwrap_env(prefix, tokenize_args(after))

    return unwrap_env(trimmed, [])


def tokenize_args(rest: str) -> list[str]:
    if not rest:
        return []
    try:
        return shlex.split(rest, posix=True)
    except ValueError:
        return rest.split()


def unwrap_env(exe_token: str, args: list[str]) -> tuple[str, list[str]]:
    if exe_token.startswith("-") and len(exe_token) > 1 and "/" not in exe_token:
        exe_token = exe_token[1:]
    base = os.path.basename(exe_token).lower()
    if base == "env":
        idx = 0
        while idx < len(args):
            tok = args[idx]
            if tok in ("-i", "-S", "--"):
                idx += 1
            elif tok == "-u" and idx + 1 < len(args):
                idx += 2
            elif tok.startswith("-"):
                idx += 1
            elif "=" in tok and not tok.startswith(("/", "./")):
                idx += 1
            else:
                break
        if idx < len(args):
            exe_token = args[idx]
            args = args[idx + 1 :]
    return exe_token, args


def classify_runtime(base: str) -> tuple[str, str]:
    """Return `(kind, family)` where kind is 'scripting', 'shell', or 'native'."""
    if base in ("python", "python2", "python3", "pypy", "pypy3") or (
        (base.startswith("python2.") or base.startswith("python3."))
        and all(c.isdigit() or c == "." for c in base.split("python", 1)[1])
    ):
        return "scripting", "python"
    if base in ("node", "nodejs", "tsx", "ts-node", "npx"):
        return "scripting", "node"
    if base == "deno":
        return "scripting", "deno"
    if base in ("bun", "bunx"):
        return "scripting", "bun"
    if base in ("uv", "uvx"):
        return "scripting", "uv"
    if base == "ruby" or (
        base.startswith("ruby") and len(base) > 4 and all(c.isdigit() or c == "." for c in base[4:])
    ):
        return "scripting", "ruby"
    if base == "perl" or (
        base.startswith("perl") and len(base) > 4 and all(c.isdigit() or c == "." for c in base[4:])
    ):
        return "scripting", "perl"
    if base == "java":
        return "scripting", "java"
    if base in SHELL_BASENAMES:
        return "shell", base
    return "native", base


def extract_target_key(kind: str, family: str, args: list[str]) -> tuple[str | None, bool]:
    """Return `(identity_key, shell_runs_dev_target)`."""
    if kind == "native":
        return None, False

    if kind == "scripting":
        idx = 0
        if family == "python":
            while idx < len(args):
                tok = args[idx]
                if tok == "-m" and idx + 1 < len(args):
                    return f"module:{args[idx + 1]}", False
                if tok == "-c" and idx + 1 < len(args):
                    return f"inline:{args[idx + 1][:64]}", False
                if tok in ("-W", "-X") and idx + 1 < len(args):
                    idx += 2
                    continue
                if tok == "--":
                    idx += 1
                    break
                if tok.startswith("-"):
                    idx += 1
                    continue
                return f"script:{norm_exe(tok)}", False
            if idx < len(args):
                return f"script:{norm_exe(args[idx])}", False
            return None, False

        if family == "node":
            val_flags = {"-r", "--require", "--import", "--loader", "--experimental-loader", "-p", "--package"}
            while idx < len(args):
                tok = args[idx]
                if tok in ("-e", "--eval", "--print") and idx + 1 < len(args):
                    return f"inline:{args[idx + 1][:64]}", False
                if tok in val_flags and idx + 1 < len(args):
                    idx += 2
                    continue
                if tok == "--":
                    idx += 1
                    break
                if tok.startswith("-"):
                    idx += 1
                    continue
                if "/" in tok or tok.endswith((".js", ".mjs", ".cjs", ".ts")):
                    return f"script:{norm_exe(tok)}", False
                return f"pkg:{tok}", False
            if idx < len(args):
                tok = args[idx]
                if "/" in tok or tok.endswith((".js", ".mjs", ".cjs", ".ts")):
                    return f"script:{norm_exe(tok)}", False
                return f"pkg:{tok}", False
            return None, False

        if family == "java":
            val_flags = {"-cp", "-classpath", "--class-path", "-p", "--module-path", "--add-opens", "--add-exports"}
            while idx < len(args):
                tok = args[idx]
                if tok == "-jar" and idx + 1 < len(args):
                    return f"jar:{norm_exe(args[idx + 1])}", False
                if tok in ("-m", "--module") and idx + 1 < len(args):
                    return f"module:{args[idx + 1]}", False
                if tok in val_flags and idx + 1 < len(args):
                    idx += 2
                    continue
                if tok.startswith("-"):
                    idx += 1
                    continue
                return f"module:{tok}", False
            return None, False

        while idx < len(args):
            tok = args[idx]
            if family in ("deno", "bun", "uv") and tok in ("run", "serve", "task", "x", "tool"):
                idx += 1
                continue
            if tok in ("-e", "-E") and idx + 1 < len(args):
                return f"inline:{args[idx + 1][:64]}", False
            if tok in ("--config", "-c", "--import-map", "--cwd", "--from", "--with", "--python", "-p", "--directory", "--project", "-I", "-r") and idx + 1 < len(args):
                idx += 2
                continue
            if tok.startswith("-"):
                idx += 1
                continue
            if "/" in tok or tok.endswith((".py", ".js", ".ts", ".mjs", ".rb", ".pl")):
                return f"script:{norm_exe(tok)}", False
            return f"pkg:{tok}", False
        return None, False

    if kind == "shell":
        idx = 0
        while idx < len(args):
            tok = args[idx]
            if tok in ("-c", "-lc", "-ic") and idx + 1 < len(args):
                sub_cmd = args[idx + 1]
                sub_exe, sub_args = split_exe_and_args(sub_cmd)
                sub_base = os.path.basename(norm_exe(sub_exe)).lower()
                sub_kind, _ = classify_runtime(sub_base)
                if sub_kind == "scripting" or (sub_kind == "native" and sub_base in EXACT_DEV_DAEMON_BASENAMES):
                    return f"pkg:{sub_base}", True
                return f"inline:{sub_cmd[:64]}", False
            if tok.startswith(("-", "+")):
                idx += 1
                continue
            return f"script:{norm_exe(tok)}", True
        return None, False

    return None, False


def parse_invocation_tuple(exe_token: str, args: list[str]) -> tuple[str, str, str, str | None, bool, list[str]]:
    norm = norm_exe(exe_token)
    base = os.path.basename(norm).lower()
    kind, family = classify_runtime(base)
    tkey, shell_dev = extract_target_key(kind, family, args)
    return norm, base, f"{kind}:{family}", tkey, shell_dev, args


def does_invocation_match_plist(proc_cmd: str, plist_args: list[str]) -> bool:
    if not plist_args:
        return False
    p_exe, p_rest = unwrap_env(plist_args[0], plist_args[1:])
    p_norm, p_base, p_kf, p_tkey, _, _ = parse_invocation_tuple(p_exe, p_rest)
    if not p_base:
        return False

    c_exe, c_rest = split_exe_and_args(proc_cmd)
    c_norm, c_base, c_kf, c_tkey, _, _ = parse_invocation_tuple(c_exe, c_rest)

    if p_kf.startswith("scripting:") and c_kf.startswith("scripting:"):
        return p_kf == c_kf and p_tkey is not None and p_tkey == c_tkey
    if p_kf.startswith("shell:") and c_kf.startswith("shell:"):
        return p_tkey is not None and p_tkey == c_tkey
    if p_kf.startswith("native:") and c_kf.startswith("native:"):
        if p_norm.startswith("/") and c_norm.startswith("/"):
            return p_norm == c_norm
        return p_base == c_base
    return False


def is_apple_or_genuine_gui_app_exe(exe_path: str) -> bool:
    low = exe_path.lower()
    if low.startswith(("/system/", "/usr/libexec/", "/usr/sbin/", "/sbin/")):
        return True
    if ".xpc/contents/" in low or ".appex/contents/" in low:
        return True
    cleaned = low.replace("/xcode.app/contents/developer/", "/_xcode_cli_developer_/")
    segs = [s for s in cleaned.split("/") if s]
    app_segs = [
        segs[i]
        for i in range(len(segs) - 1)
        if segs[i].endswith(".app") and segs[i + 1] == "contents"
    ]
    if not app_segs:
        return False
    return any(seg not in CLI_FRAMEWORK_INTERPRETER_BUNDLES for seg in app_segs)


def qualifies_as_orphan_daemon(exe_token: str, args: list[str], ports: set[int]) -> bool:
    if ports:
        return True
    _, base, kf, tkey, shell_dev, raw_args = parse_invocation_tuple(exe_token, args)
    if kf.startswith("scripting:"):
        return tkey is not None or len(raw_args) > 0
    if kf.startswith("shell:"):
        return shell_dev
    return base in EXACT_DEV_DAEMON_BASENAMES


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
    current_uid: int,
) -> SnapshotRef:
    lctl_map = parse_lctl((snap_dir / "launchctl-list.txt").read_text(encoding="utf-8"))
    ps_rows = parse_ps((snap_dir / "ps-axo.txt").read_text(encoding="utf-8"))
    lsof_ports_by_pid = parse_lsof((snap_dir / "lsof-listen.txt").read_text(encoding="utf-8"))

    # Bottom-up ancestor chain for every live PID (zero top-down child adjacency structures)
    chains_by_pid: dict[int, tuple[int, ...]] = {
        pid: ancestor_chain(pid, ps_rows) for pid in ps_rows
    }

    claimed_lctl_roots = {p for p in lctl_map.values() if p is not None and p > 0}
    owned_pids: set[int] = {
        pid for pid, chain in chains_by_pid.items() if claimed_lctl_roots.intersection(chain)
    }

    services: dict[tuple[str, str], ServiceRef] = {}
    for dom, lbl, rargs in ref_plists:
        if lbl in lctl_map:
            lctl_pid = lctl_map[lbl]
            service_roots = {lctl_pid} if (lctl_pid is not None and lctl_pid > 0) else set()
        elif rargs:
            matched_candidates = {
                cand_pid
                for cand_pid, proc in ps_rows.items()
                if cand_pid not in owned_pids
                and (dom != "User LaunchAgent" or proc.uid == current_uid)
                and does_invocation_match_plist(proc.cmd, rargs)
            }
            if matched_candidates:
                minimal_roots = {
                    cand_pid
                    for cand_pid in matched_candidates
                    if ps_rows[cand_pid].ppid not in matched_candidates
                }
                service_roots = minimal_roots if minimal_roots else {min(matched_candidates)}
                owned_pids |= {
                    pid for pid, chain in chains_by_pid.items() if service_roots.intersection(chain)
                }
            else:
                service_roots = set()
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

    # Bottom-up independent orphan detection & RSS aggregation (PPID == 1, owned by current_uid)
    active_plist_rargs = [rargs for _, _, rargs in ref_plists if rargs]
    orphans: dict[int, ServiceRef] = {}
    for pid in sorted(ps_rows.keys()):
        proc = ps_rows[pid]
        if proc.uid != current_uid or proc.ppid != 1 or pid in owned_pids:
            continue
        exe_token, proc_args = split_exe_and_args(proc.cmd)
        if not exe_token or is_apple_or_genuine_gui_app_exe(exe_token):
            continue
        if any(does_invocation_match_plist(proc.cmd, rargs) for rargs in active_plist_rargs):
            continue

        member_pids = {p for p, chain in chains_by_pid.items() if pid in chain}
        ports = {pt for p in member_pids for pt in lsof_ports_by_pid.get(p, set())}
        if not qualifies_as_orphan_daemon(exe_token, proc_args, ports):
            continue

        rss_bytes = sum(max(0, ps_rows[p].rss_kb) for p in member_pids) * 1024
        owned_pids |= member_pids
        orphans[pid] = ServiceRef(
            running=True,
            rss_bytes=rss_bytes,
            ports=ports,
            member_pids=member_pids,
        )

    orphan_rss_bytes = sum(o.rss_bytes for o in orphans.values())
    return SnapshotRef(
        lctl_map=lctl_map,
        ps_rows=ps_rows,
        lsof_ports_by_pid=lsof_ports_by_pid,
        services=services,
        orphans=orphans,
        orphan_rss_bytes=orphan_rss_bytes,
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
    exe_token, _ = split_exe_and_args(cmd)
    low = (exe_token or cmd).lower()
    if ".xpc/contents/" in low or ".appex/contents/" in low:
        return True
    cleaned = low.replace("/xcode.app/contents/developer/", "/_xcode_cli_developer_/")
    segs = [s for s in cleaned.split("/") if s]
    app_segs = [
        segs[i]
        for i in range(len(segs) - 1)
        if segs[i].endswith(".app") and segs[i + 1] == "contents"
    ]
    if not app_segs:
        return False
    return any(seg not in CLI_FRAMEWORK_INTERPRETER_BUNDLES for seg in app_segs)


def is_apple_or_genuine_gui_app(cmd: str) -> bool:
    return is_apple_system_cmd(cmd) or is_genuine_gui_app_cmd(cmd)


def check_bracket_span(before_rss: int, after_rss: int) -> tuple[bool, float, int]:
    """Return `(is_unstable, span_pct, span_bytes)` under the 25% width cap + 64KB small-amount exemption."""
    low_rss = min(before_rss, after_rss)
    high_rss = max(before_rss, after_rss)
    span_bytes = high_rss - low_rss
    span_pct = (span_bytes * 100.0) / max(low_rss, 1)
    exempt_small = high_rss < SMALL_PROCESS_MAX_RSS_BYTES and span_bytes <= SMALL_DIFF_EXEMPT_BYTES
    return (span_pct > MAX_BRACKET_SPAN_PCT and not exempt_small), span_pct, span_bytes


def evaluate_stable_bracket_diff(cli_rss: int, before_rss: int, after_rss: int) -> tuple[int, int, float]:
    """Evaluate `cli_rss` against a verified-stable `[min(before, after), max(before, after)]` bracket."""
    low_rss = min(before_rss, after_rss)
    high_rss = max(before_rss, after_rss)
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
    return abs_diff, anchor_rss, pct_diff


def find_unstable_brackets(
    cli_services: list[dict],
    cli_orphan_rss: int,
    snap_before: SnapshotRef,
    snap_after: SnapshotRef,
) -> list[str]:
    unstable_items: list[str] = []
    for idx, svc in enumerate(cli_services):
        key = (svc["domain"], svc["label"])
        b_ref = snap_before.services[key]
        a_ref = snap_after.services[key]
        cli_pid = svc.get("pid")
        cli_running = cli_pid is not None and int(cli_pid) > 0
        if cli_running or b_ref.running or a_ref.running:
            unstable, span_pct, span_bytes = check_bracket_span(b_ref.rss_bytes, a_ref.rss_bytes)
            if unstable:
                unstable_items.append(
                    f"service#{idx} ({svc['domain']}): ref_before={b_ref.rss_bytes} B "
                    f"({b_ref.rss_bytes / 1_048_576.0:.2f} MB), ref_after={a_ref.rss_bytes} B "
                    f"({a_ref.rss_bytes / 1_048_576.0:.2f} MB), span_pct={span_pct:.2f}% "
                    f"(span_kb={span_bytes / 1024.0:.1f} KB > {MAX_BRACKET_SPAN_PCT:.1f}% width cap)"
                )

    b_orph_rss = snap_before.orphan_rss_bytes
    a_orph_rss = snap_after.orphan_rss_bytes
    if cli_orphan_rss > 0 or b_orph_rss > 0 or a_orph_rss > 0:
        unstable_orph, orph_span_pct, orph_span_bytes = check_bracket_span(b_orph_rss, a_orph_rss)
        if unstable_orph:
            unstable_items.append(
                f"orphanRSSBytes: ref_before={b_orph_rss} B "
                f"({b_orph_rss / 1_048_576.0:.2f} MB), ref_after={a_orph_rss} B "
                f"({a_orph_rss / 1_048_576.0:.2f} MB), span_pct={orph_span_pct:.2f}% "
                f"(span_kb={orph_span_bytes / 1024.0:.1f} KB > {MAX_BRACKET_SPAN_PCT:.1f}% width cap)"
            )

    return unstable_items


def verify_stable_round(
    args: argparse.Namespace,
    ref_plists: list[tuple[str, str, list[str] | None]],
    domain_counts: dict[str, int],
    payload: dict,
    snap_before: SnapshotRef,
    snap_after: SnapshotRef,
) -> None:
    cli_services = payload["services"]
    cli_orphans = payload["orphans"]
    cli_orphan_rss = int(payload["orphanRSSBytes"])
    cli_total_bg_rss = int(payload["totalBackgroundRSSBytes"])

    # --- ROW 1 ASSERTIONS: Service count 100% + Stable Bracketed RSS <= 5% (services + orphanRSSBytes) ---
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

            abs_diff, anchor_rss, pct_diff = evaluate_stable_bracket_diff(
                cli_rss, b_ref.rss_bytes, a_ref.rss_bytes
            )
            kb_diff = abs_diff / 1024.0
            max_rss_pct_diff = max(max_rss_pct_diff, pct_diff)
            max_rss_kb_diff = max(max_rss_kb_diff, kb_diff)

            if pct_diff > MAX_ENDPOINT_DIFF_PCT and not (
                anchor_rss < SMALL_PROCESS_MAX_RSS_BYTES and abs_diff <= SMALL_DIFF_EXEMPT_BYTES
            ):
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

    # Verify aggregate orphanRSSBytes internal sum + independent before/after bracket <= 5%
    sum_cli_orphan_items = sum(int(o["rssBytes"]) for o in cli_orphans)
    if cli_orphan_rss != sum_cli_orphan_items:
        raise AssertionError(
            f"orphanRSSBytes internal sum mismatch: orphanRSSBytes={cli_orphan_rss} "
            f"vs sum(orphans.rssBytes)={sum_cli_orphan_items}"
        )

    non_apple_services_rss = sum(
        int(s["rssBytes"]) for s in cli_services if not s.get("isAppleSystem", False)
    )
    if cli_total_bg_rss != non_apple_services_rss + cli_orphan_rss:
        raise AssertionError(
            f"totalBackgroundRSSBytes mismatch: got {cli_total_bg_rss}, "
            f"expected services({non_apple_services_rss}) + orphanRSSBytes({cli_orphan_rss})"
        )

    b_orph_rss = snap_before.orphan_rss_bytes
    a_orph_rss = snap_after.orphan_rss_bytes
    if cli_orphan_rss > 0 or b_orph_rss > 0 or a_orph_rss > 0:
        if b_orph_rss == 0 and a_orph_rss == 0 and cli_orphan_rss != 0:
            raise AssertionError(
                f"orphanRSSBytes non-zero when reference had 0 orphans: "
                f"orphanRSSBytes={cli_orphan_rss} ref_before=0 ref_after=0"
            )
        orph_abs_diff, orph_anchor_rss, orph_pct_diff = evaluate_stable_bracket_diff(
            cli_orphan_rss, b_orph_rss, a_orph_rss
        )
        orph_kb_diff = orph_abs_diff / 1024.0
        max_rss_pct_diff = max(max_rss_pct_diff, orph_pct_diff)
        max_rss_kb_diff = max(max_rss_kb_diff, orph_kb_diff)

        if orph_pct_diff > MAX_ENDPOINT_DIFF_PCT and not (
            orph_anchor_rss < SMALL_PROCESS_MAX_RSS_BYTES and orph_abs_diff <= SMALL_DIFF_EXEMPT_BYTES
        ):
            raise AssertionError(
                f"Orphan aggregate RSS (orphanRSSBytes) diff exceeded 5%: "
                f"orphanRSSBytes={cli_orphan_rss} ref_before={b_orph_rss} ref_after={a_orph_rss} "
                f"diff_pct={orph_pct_diff:.3f}%"
            )

    services_rss_mb = non_apple_services_rss / (1024.0 * 1024.0)
    orphan_rss_mb = cli_orphan_rss / (1024.0 * 1024.0)
    total_bg_mb = cli_total_bg_rss / (1024.0 * 1024.0)
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
        b_oports = (
            snap_before.orphans[opid].ports
            if opid in snap_before.orphans
            else (snap_before.lsof_ports_by_pid.get(opid, set()) if opid else set())
        )
        a_oports = (
            snap_after.orphans[opid].ports
            if opid in snap_after.orphans
            else (snap_after.lsof_ports_by_pid.get(opid, set()) if opid else set())
        )
        must_oports = (
            (b_oports & a_oports)
            if (opid in snap_before.ps_rows and opid in snap_after.ps_rows)
            else set()
        )
        allow_oports = b_oports | a_oports
        if not (must_oports <= cli_oports <= allow_oports):
            raise AssertionError(
                f"Orphan PID {opid} port mismatch: cli={sorted(cli_oports)} "
                f"vs lsof_before={sorted(b_oports)} lsof_after={sorted(a_oports)}"
            )

    cli_all_ports = sorted(
        {pt for item in (cli_services + cli_orphans) for pt in item.get("listeningPorts", [])}
    )
    tracked_all_pids = (
        {
            p
            for k in snap_after.services
            for p in (snap_before.services[k].member_pids | snap_after.services[k].member_pids)
        }
        | {
            p
            for opid in (set(snap_before.orphans.keys()) | set(snap_after.orphans.keys()))
            for p in (
                (snap_before.orphans[opid].member_pids if opid in snap_before.orphans else set())
                | (snap_after.orphans[opid].member_pids if opid in snap_after.orphans else set())
            )
        }
        | {int(orph["pid"]) for orph in cli_orphans if orph.get("pid") is not None}
    )

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


def run_verification_with_retries(
    args: argparse.Namespace,
    sample_round_fn: Callable[[int], RoundSample],
    max_retries: int,
    retry_pause_sec: float = 0.0,
) -> None:
    total_allowed_rounds = 1 + max(0, max_retries)
    unstable_history: list[tuple[int, str, list[str], str]] = []

    for round_idx in range(1, total_allowed_rounds + 1):
        round_label = (
            "round 1 (initial)"
            if round_idx == 1
            else f"round {round_idx} (retry {round_idx - 1}/{max_retries})"
        )
        sample = sample_round_fn(round_idx)

        ref_plists, domain_counts = load_ref_plists(
            user_agents_dir=args.user_agents_dir,
            global_agents_dir=args.global_agents_dir,
            system_daemons_dir=args.system_daemons_dir,
        )
        payload = json.loads(sample.cli_json_path.read_text(encoding="utf-8"))
        cli_services = payload["services"]
        cli_orphan_rss = int(payload["orphanRSSBytes"])

        cli_keys = [(s["domain"], s["label"]) for s in cli_services]
        ref_keys = [(dom, lbl) for dom, lbl, _ in ref_plists]
        if len(cli_services) != len(ref_plists) or sorted(cli_keys) != sorted(ref_keys):
            raise AssertionError(
                f"Service count/set mismatch on {round_label}: cli={len(cli_services)} vs ref={len(ref_plists)}"
            )

        snap_before = compute_snapshot_reference(ref_plists, sample.before_dir, args.current_uid)
        snap_after = compute_snapshot_reference(ref_plists, sample.after_dir, args.current_uid)

        unstable_items = find_unstable_brackets(cli_services, cli_orphan_rss, snap_before, snap_after)
        if not unstable_items:
            if round_idx > 1:
                print(
                    f"[LR1 Resample] Bracket width stabilized (<= {MAX_BRACKET_SPAN_PCT:.1f}%) on {round_label} "
                    f"after discarding {round_idx - 1} unstable sample(s)."
                )
            verify_stable_round(args, ref_plists, domain_counts, payload, snap_before, snap_after)
            return

        unstable_history.append((round_idx, round_label, unstable_items, sample.uptime_line))
        if round_idx < total_allowed_rounds and retry_pause_sec > 0:
            time.sleep(retry_pause_sec)

    lines = [
        f"Reference bracket width exceeded {MAX_BRACKET_SPAN_PCT:.1f}% cap across "
        f"{len(unstable_history)} sample round(s) (max_retries={max_retries}):"
    ]
    for _, r_label, items, u_line in unstable_history:
        lines.append(f"  - [{r_label}] uptime: {u_line}")
        for item_desc in items:
            lines.append(f"      {item_desc}")
    raise BracketInstabilityError("\n".join(lines))


def capture_live_round(
    round_idx: int,
    bin_path: pathlib.Path,
    ledger_dir: pathlib.Path,
    work_dir: pathlib.Path,
) -> RoundSample:
    r_dir = work_dir / f"sample_round_{round_idx}"
    b_dir = r_dir / "before"
    a_dir = r_dir / "after"
    b_dir.mkdir(parents=True, exist_ok=True)
    a_dir.mkdir(parents=True, exist_ok=True)
    cli_path = r_dir / "cli.json"

    lctl_before = subprocess.check_output(["/bin/launchctl", "list"], text=True)
    lsof_before = subprocess.check_output(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], text=True)
    ps_before = subprocess.check_output(["/bin/ps", "-axo", "pid,ppid,uid,rss,args"], text=True)

    cli_raw = subprocess.check_output(
        [str(bin_path), "--cli", "list", "--json", "--ledger-dir", str(ledger_dir), "--lang", "en"],
        text=True,
    )

    ps_after = subprocess.check_output(["/bin/ps", "-axo", "pid,ppid,uid,rss,args"], text=True)
    lctl_after = subprocess.check_output(["/bin/launchctl", "list"], text=True)
    lsof_after = subprocess.check_output(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], text=True)
    uptime_now = read_uptime_line()

    (b_dir / "launchctl-list.txt").write_text(lctl_before, encoding="utf-8")
    (b_dir / "ps-axo.txt").write_text(ps_before, encoding="utf-8")
    (b_dir / "lsof-listen.txt").write_text(lsof_before, encoding="utf-8")

    (a_dir / "launchctl-list.txt").write_text(lctl_after, encoding="utf-8")
    (a_dir / "ps-axo.txt").write_text(ps_after, encoding="utf-8")
    (a_dir / "lsof-listen.txt").write_text(lsof_after, encoding="utf-8")

    cli_path.write_text(cli_raw, encoding="utf-8")
    return RoundSample(before_dir=b_dir, after_dir=a_dir, cli_json_path=cli_path, uptime_line=uptime_now)


def main() -> int:
    args = parse_args()
    try:
        if args.live_capture:
            if args.bin_path is None or args.ledger_dir is None or args.work_dir is None:
                raise ValueError("--live-capture requires --bin-path, --ledger-dir, and --work-dir")
            max_retries = 3 if args.max_retries is None else args.max_retries
            run_verification_with_retries(
                args=args,
                sample_round_fn=lambda r_idx: capture_live_round(
                    r_idx, args.bin_path, args.ledger_dir, args.work_dir
                ),
                max_retries=max_retries,
                retry_pause_sec=0.15,
            )
        elif args.round_dirs is not None:
            max_retries = 3 if args.max_retries is None else args.max_retries
            allowed = min(len(args.round_dirs), 1 + max(0, max_retries))
            effective_retries = allowed - 1

            def load_round(r_idx: int) -> RoundSample:
                r_dir = args.round_dirs[r_idx - 1]
                uptime_file = r_dir / "uptime.txt"
                u_line = (
                    uptime_file.read_text(encoding="utf-8").strip()
                    if uptime_file.is_file()
                    else read_uptime_line()
                )
                return RoundSample(
                    before_dir=r_dir / "before",
                    after_dir=r_dir / "after",
                    cli_json_path=r_dir / "cli.json",
                    uptime_line=u_line,
                )

            run_verification_with_retries(
                args=args,
                sample_round_fn=load_round,
                max_retries=effective_retries,
                retry_pause_sec=0.0,
            )
        elif args.before_dir is not None and args.after_dir is not None and args.cli_json is not None:
            run_verification_with_retries(
                args=args,
                sample_round_fn=lambda _: RoundSample(
                    before_dir=args.before_dir,
                    after_dir=args.after_dir,
                    cli_json_path=args.cli_json,
                    uptime_line=read_uptime_line(),
                ),
                max_retries=0,
                retry_pause_sec=0.0,
            )
        else:
            raise ValueError(
                "Must specify either (--before-dir --after-dir --cli-json), (--round-dirs ...), or --live-capture"
            )
        return 0
    except BracketInstabilityError as exc:
        sys.stderr.write(f"FAIL [m1_ledger_ref]: {exc}\n")
        return 1
    except Exception as exc:
        uptime_now = read_uptime_line()
        sys.stderr.write(f"FAIL [m1_ledger_ref]: {exc}\n")
        sys.stderr.write(f"[Diagnostic] Host uptime at assertion failure: {uptime_now}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
