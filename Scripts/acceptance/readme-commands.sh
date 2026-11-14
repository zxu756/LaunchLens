#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

MODE="milestone0"
RECORD="${LAUNCHLENS_RECORD:-0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            if [[ $# -lt 2 ]]; then
                echo "Error: --mode requires milestone0 or release" >&2
                exit 2
            fi
            MODE="$2"
            shift 2
            continue
            ;;
        --mode=*)
            MODE="${1#--mode=}"
            ;;
        --record)
            RECORD=1
            ;;
        *)
            echo "Usage: Scripts/acceptance/readme-commands.sh [--mode milestone0|release] [--record]" >&2
            exit 2
            ;;
    esac
    shift
done

if [[ "$MODE" != "milestone0" && "$MODE" != "release" ]]; then
    echo "Error: Invalid --mode '$MODE' (expected milestone0 or release)" >&2
    exit 2
fi

REPORT_FILE="$ROOT/reports/readme-commands.txt"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/launchlens-readme.XXXXXX")"
cleanup() {
    chmod -R u+rwx "$TMP_ROOT" 2>/dev/null || true
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

RAW_REPORT="$TMP_ROOT/readme-commands.raw.txt"
SANITIZED_REPORT="$TMP_ROOT/readme-commands.sanitized.txt"

{
    echo "================================================================"
    echo "LaunchLens README.md & README.zh-CN.md Command Verification (mode=$MODE)"
    echo "================================================================"

    python3 - "$ROOT" "$TMP_ROOT" "$MODE" <<'PYEOF'
import os
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
tmp_root = pathlib.Path(sys.argv[2])
mode = sys.argv[3]

def extract_fenced_bash_commands(md_path: pathlib.Path) -> list[str]:
    text = md_path.read_text(encoding="utf-8")
    blocks = re.findall(r"```(?:bash|sh)\n(.*?)```", text, flags=re.DOTALL)
    cmds: list[str] = []
    for block in blocks:
        for raw_line in block.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            cmds.append(line)
    return cmds

en_cmds = extract_fenced_bash_commands(root / "README.md")
zh_cmds = extract_fenced_bash_commands(root / "README.zh-CN.md")

if not en_cmds:
    sys.stderr.write("FAIL: Zero executable commands extracted from README.md\n")
    sys.exit(1)

if en_cmds != zh_cmds:
    sys.stderr.write("FAIL: Fenced bash/sh commands in README.md and README.zh-CN.md do NOT match!\n")
    sys.stderr.write(f"README.md ({len(en_cmds)}): {en_cmds}\n")
    sys.stderr.write(f"README.zh-CN.md ({len(zh_cmds)}): {zh_cmds}\n")
    sys.exit(1)

print(f"[Parity OK] Extracted {len(en_cmds)} identical commands from README.md and README.zh-CN.md.")

# Set up isolated fixture LaunchAgents & Vault directories so milestone 0 never touches ~/Library/LaunchAgents (L15)
agents_dir = tmp_root / "fixture_agents"
ledger_dir = tmp_root / "fixture_vault"
agents_dir.mkdir(parents=True, exist_ok=True)
ledger_dir.mkdir(parents=True, exist_ok=True)

fixture_plist = agents_dir / "io.fixture.readme-agent.plist"
fixture_plist.write_text(
    """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.fixture.readme-agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/true</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
""",
    encoding="utf-8",
)

env = os.environ.copy()
env["AGENTS_DIR"] = str(agents_dir)
env["LEDGER_DIR"] = str(ledger_dir)

def expected_assertion_for(cmd: str):
    if cmd == "./Scripts/test.sh scope Freeze Scanner CLI UI":
        return ("exact_all", ["Test run with", "passed"])
    if cmd == "./Scripts/build-app.sh":
        return ("exact_all", ["✓ Built ", "build/LaunchLens.app"])
    if "--cli list" in cmd and "--agents-dir" in cmd and "--lang en" in cmd:
        return ("exact_all", ["Total Non-Apple Background RSS", "io.fixture.readme-agent", "[User agent]"])
    if "--cli list" in cmd and "--agents-dir" in cmd and "--lang zh" in cmd:
        return ("exact_all", ["非 Apple 后台常驻内存总计", "io.fixture.readme-agent", "[用户代理]"])
    if "--cli orphans" in cmd and "--agents-dir" in cmd and "--lang en" in cmd:
        return ("regex", r"(No orphaned developer/AI daemons detected\.|PID \d+)")
    if "--cli orphans" in cmd and "--agents-dir" in cmd and "--lang zh" in cmd:
        return ("regex", r"(未检测到脱离终端的开发/AI 孤儿守护进程。|PID \d+)")
    if "--cli frozen" in cmd and "--ledger-dir" in cmd and "--lang en" in cmd:
        return ("exact_all", ["No frozen LaunchAgents in snapshot vault."])
    if "--cli frozen" in cmd and "--ledger-dir" in cmd and "--lang zh" in cmd:
        return ("exact_all", ["快照保险库中暂无已冻结的 LaunchAgents。"])
    if "--cli audit" in cmd and "--ledger-dir" in cmd and "--lang en" in cmd:
        return ("exact_all", ["Ledger audit OK: 0 interrupted transactions, 0 orphaned backups."])
    if "--cli audit" in cmd and "--ledger-dir" in cmd and "--lang zh" in cmd:
        return ("exact_all", ["台账完整性检查通过：0 条中断事务，0 个孤儿备份文件。"])
    if "--help" in cmd and "--lang en" in cmd:
        return ("exact_all", ["Usage: LaunchLens --cli [list|orphans|frozen|audit]"])
    if "--help" in cmd and "--lang zh" in cmd:
        return ("exact_all", ["用法：LaunchLens --cli [list|orphans|frozen|audit]"])
    if cmd == "build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang en":
        return ("exact_all", ["Total Non-Apple Background RSS"])
    if cmd == "build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang zh":
        return ("exact_all", ["非 Apple 后台常驻内存总计"])
    return None

executed_count = 0
skipped_count = 0

for idx, cmd in enumerate(en_cmds, start=1):
    print("")
    print(f"==> [{idx}/{len(en_cmds)}] {cmd}")

    if cmd.startswith("brew install "):
        print(f"SKIPPED (external Homebrew Cask install requires network and modifies /Applications): {cmd}")
        skipped_count += 1
        continue

    reads_host_launch_agents = (
        "--cli" in cmd
        and (" list" in cmd or " orphans" in cmd)
        and "--agents-dir" not in cmd
    )
    if reads_host_launch_agents and mode == "milestone0":
        print(f"SKIPPED in milestone 0 (reads host ~/Library/LaunchAgents; runs in release mode only): {cmd}")
        skipped_count += 1
        continue

    rule = expected_assertion_for(cmd)
    if rule is None:
        sys.stderr.write(f"FAIL: Unhandled README command missing explicit output assertion: {cmd}\n")
        sys.exit(1)

    proc = subprocess.run(
        ["bash", "-c", cmd],
        cwd=str(root),
        env=env,
        capture_output=True,
        text=True,
    )
    combined = proc.stdout + (("\n" + proc.stderr) if proc.stderr else "")
    all_lines = combined.strip().splitlines()
    if len(all_lines) <= 14:
        for out_line in all_lines:
            print(f"    {out_line}")
    else:
        for out_line in all_lines[:5]:
            print(f"    {out_line}")
        print(f"    ... ({len(all_lines) - 10} lines omitted) ...")
        for out_line in all_lines[-5:]:
            print(f"    {out_line}")

    if proc.returncode != 0:
        sys.stderr.write(f"FAIL: Command exited {proc.returncode} (expected 0): {cmd}\n{combined}\n")
        sys.exit(1)

    kind, target = rule
    if kind == "exact_all":
        for needle in target:
            if needle not in combined:
                sys.stderr.write(f"FAIL: Output for '{cmd}' missing expected substring '{needle}'. Got:\n{combined}\n")
                sys.exit(1)
    elif kind == "regex":
        if not re.search(target, combined):
            sys.stderr.write(f"FAIL: Output for '{cmd}' did not match regex '{target}'. Got:\n{combined}\n")
            sys.exit(1)

    print(f"    [ASSERT PASS] exit=0, verified output pattern ({kind})")
    executed_count += 1

print("")
print(f"[Summary] mode={mode} total={len(en_cmds)} passed={executed_count} skipped={skipped_count}")
PYEOF

    echo "================================================================"
    echo "EXECUTED README COMMAND CHECKS PASSED; SKIPPED CHECKS COUNTED SEPARATELY (EXIT 0)"
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
    echo "[Record] Wrote sanitized report to reports/readme-commands.txt"
fi
