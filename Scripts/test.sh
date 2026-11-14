#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
Usage:
  Scripts/test.sh scope <Module...>     # e.g. Freeze | Scanner | CLI | UI
  Scripts/test.sh milestone <0|1>
  Scripts/test.sh release
EOF
    exit 2
}

map_scope_filter() {
    local token="$1"
    case "$token" in
        Freeze|freeze|FreezeLedgerTests)
            echo "FreezeLedgerTests"
            ;;
        Scanner|scanner|ScannerCorrelationTests)
            echo "ScannerCorrelationTests"
            ;;
        CLI|cli|CLIRunnerTests)
            echo "CLIRunnerTests"
            ;;
        UI|ui|Localization|UIAndLocalizationTests)
            echo "UIAndLocalizationTests"
            ;;
        *)
            echo "$token"
            ;;
    esac
}

if [[ $# -lt 1 ]]; then
    usage
fi

MODE="$1"
shift

case "$MODE" in
    scope)
        if [[ $# -lt 1 ]]; then
            usage
        fi
        FILTERS=()
        for mod in "$@"; do
            FILTERS+=("$(map_scope_filter "$mod")")
        done
        REGEX="$(IFS='|'; echo "${FILTERS[*]}")"
        if [[ "$REGEX" == *"CLIRunnerTests"* ]]; then
            swift build --product LaunchLens >/dev/null
        fi
        echo "==> Running scoped tests (--filter $REGEX)..."
        swift test --no-parallel --filter "$REGEX"
        ;;
    milestone)
        if [[ $# -ne 1 ]]; then
            usage
        fi
        MS="$1"
        case "$MS" in
            0|M0|m0)
                swift build --product LaunchLens >/dev/null
                echo "==> [M0] Running all M0 unit test scopes (Freeze, Scanner, CLI, UI)..."
                swift test --no-parallel --filter "FreezeLedgerTests|ScannerCorrelationTests|CLIRunnerTests|UIAndLocalizationTests"
                echo "==> [M0] Running Scripts/acceptance/m0-acceptance.sh..."
                "$ROOT/Scripts/acceptance/m0-acceptance.sh"
                echo "==> [M0] Running Scripts/acceptance/readme-commands.sh..."
                "$ROOT/Scripts/acceptance/readme-commands.sh"
                ;;
            *)
                echo "Error: Milestone '$MS' is not yet implemented (only milestone 0 is available on m0/honest)." >&2
                exit 2
                ;;
        esac
        ;;
    release)
        swift build --product LaunchLens >/dev/null
        echo "==> [Release] Running full unit test suite..."
        swift test --no-parallel
        echo "==> [Release] Running Scripts/acceptance/m0-acceptance.sh..."
        "$ROOT/Scripts/acceptance/m0-acceptance.sh"
        echo "==> [Release] Running Scripts/acceptance/readme-commands.sh..."
        "$ROOT/Scripts/acceptance/readme-commands.sh"
        if [[ "${LAUNCHLENS_REAL_LAUNCHD:-0}" == "1" ]]; then
            if [[ -x "$ROOT/Scripts/acceptance/m1-real-launchd.sh" ]]; then
                "$ROOT/Scripts/acceptance/m1-real-launchd.sh"
            else
                echo "Error: LAUNCHLENS_REAL_LAUNCHD=1 requested, but M1 real-launchd test script is not implemented in M0." >&2
                exit 1
            fi
        else
            echo "Real launchd checks: SKIPPED (LAUNCHLENS_REAL_LAUNCHD!=1)"
        fi
        ;;
    *)
        usage
        ;;
esac
