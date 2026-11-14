#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

mkdir -p "$ROOT/reports"
REPORT_FILE="$ROOT/reports/readme-commands.txt"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/launchlens-readme.XXXXXX")"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

{
    echo "================================================================"
    echo "LaunchLens README.md & README.zh-CN.md Command Verification"
    echo "================================================================"

    echo ""
    echo "==> 1) ./Scripts/test.sh scope Freeze Scanner CLI UI"
    ./Scripts/test.sh scope Freeze Scanner CLI UI

    echo ""
    echo "==> 2) Ensure build/LaunchLens.app exists (./Scripts/build-app.sh if missing)"
    if [[ ! -x "$ROOT/build/LaunchLens.app/Contents/MacOS/LaunchLens" ]]; then
        ./Scripts/build-app.sh
    fi

    echo ""
    echo "==> 3) Headless CLI list (--lang en & --lang zh)"
    build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang en
    build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang zh

    echo ""
    echo "==> 4) Headless CLI orphans (--lang en & --lang zh)"
    build/LaunchLens.app/Contents/MacOS/LaunchLens --cli orphans --lang en
    build/LaunchLens.app/Contents/MacOS/LaunchLens --cli orphans --lang zh

    echo ""
    echo "==> 5) Headless CLI frozen (--lang en & --lang zh)"
    build/LaunchLens.app/Contents/MacOS/LaunchLens --cli frozen --lang en
    build/LaunchLens.app/Contents/MacOS/LaunchLens --cli frozen --lang zh

    echo ""
    echo "==> 6) Headless CLI audit (--lang en & --lang zh)"
    build/LaunchLens.app/Contents/MacOS/LaunchLens --cli audit --lang en
    build/LaunchLens.app/Contents/MacOS/LaunchLens --cli audit --lang zh

    echo ""
    echo "==> 7) Headless CLI --help (--lang en & --lang zh)"
    build/LaunchLens.app/Contents/MacOS/LaunchLens --help --lang en
    build/LaunchLens.app/Contents/MacOS/LaunchLens --help --lang zh

    echo ""
    echo "==> 8) Isolated --export-screenshots check to temp directory (--lang en & --lang zh)"
    build/LaunchLens.app/Contents/MacOS/LaunchLens --export-screenshots "$TMP_ROOT/shots" --lang en | sed "s|$TMP_ROOT|<mktemp>|g"
    build/LaunchLens.app/Contents/MacOS/LaunchLens --export-screenshots "$TMP_ROOT/shots" --lang zh | sed "s|$TMP_ROOT|<mktemp>|g"
    [[ -s "$TMP_ROOT/shots/screenshot-main.png" && -s "$TMP_ROOT/shots/screenshot-main-zh.png" ]]

    echo ""
    echo "================================================================"
    echo "ALL README & README.zh-CN COMMANDS SUCCEEDED (EXIT 0)"
    echo "================================================================"
} | tee "$REPORT_FILE"
