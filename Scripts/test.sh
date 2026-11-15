#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
Usage:
  Scripts/test.sh scope <Module...>     # e.g. Freeze | Scanner | CLI | UI
  Scripts/test.sh milestone <0|1> [--record]
  Scripts/test.sh release [--record]
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

print_stage_summary() {
    local stage_label="$1"
    local unit_log="$2"
    local accept_name="$3"
    local accept_log="$4"
    local readme_log="$5"
    local real_launchd_status="$6"
    local extra_accept_name="${7:-}"
    local extra_accept_log="${8:-}"

    python3 - "$stage_label" "$unit_log" "$accept_name" "$accept_log" "$readme_log" "$real_launchd_status" "$extra_accept_name" "$extra_accept_log" <<'PYEOF'
import pathlib
import re
import sys

label, unit_path, accept_name, accept_path, readme_path, real_status, extra_name, extra_path = sys.argv[1:9]
unit_text = pathlib.Path(unit_path).read_text(encoding="utf-8")
accept_text = pathlib.Path(accept_path).read_text(encoding="utf-8")
readme_text = pathlib.Path(readme_path).read_text(encoding="utf-8")

unit_passed = len(re.findall(r'^\s*✔ Test "', unit_text, flags=re.MULTILINE))
unit_skipped = len(re.findall(r'^\s*◇ Test ".*" skipped', unit_text, flags=re.MULTILINE))

accept_passed = len(re.findall(r'^\[.*PASS\]', accept_text, flags=re.MULTILINE))
accept_skipped = len(re.findall(r'^\[.*SKIPPED\]', accept_text, flags=re.MULTILINE))

extra_passed = 0
extra_skipped = 0
extra_segment = ""
if extra_name and extra_path:
    extra_text = pathlib.Path(extra_path).read_text(encoding="utf-8")
    extra_passed = len(re.findall(r'^\[.*PASS\]', extra_text, flags=re.MULTILINE))
    extra_skipped = len(re.findall(r'^\[.*SKIPPED\]', extra_text, flags=re.MULTILINE))
    extra_segment = f"{extra_name}(passed={extra_passed}, skipped={extra_skipped}) | "

m = re.search(r'\[Summary\] mode=\S+ total=(\d+) passed=(\d+) skipped=(\d+)', readme_text)
if not m:
    sys.stderr.write("FAIL: Could not parse passed/skipped counts from readme-commands output.\n")
    sys.exit(1)
readme_passed = int(m.group(2))
readme_skipped = int(m.group(3))

# Note: m1_ledger already records [M1 Row 4 SKIPPED] when LAUNCHLENS_REAL_LAUNCHD!=1, so do not double-count.
has_m1_ledger = (accept_name == "m1_ledger" or extra_name == "m1_ledger")
standalone_real_skip = 1 if (real_status.startswith("skipped") and not has_m1_ledger) else 0

total_passed = unit_passed + accept_passed + extra_passed + readme_passed
total_skipped = unit_skipped + accept_skipped + extra_skipped + readme_skipped + standalone_real_skip

print(
    f"==> [{label} Summary] "
    f"unit_tests(passed={unit_passed}, skipped={unit_skipped}) | "
    f"{accept_name}(passed={accept_passed}, skipped={accept_skipped}) | "
    f"{extra_segment}"
    f"readme_commands(passed={readme_passed}, skipped={readme_skipped}) | "
    f"real_launchd={real_status} | "
    f"totals(passed={total_passed}, skipped={total_skipped})"
)
PYEOF
}

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
        if [[ $# -lt 1 ]]; then
            usage
        fi
        MS="$1"
        shift
        RECORD_FLAG=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --record)
                    RECORD_FLAG=("--record")
                    ;;
                *)
                    usage
                    ;;
            esac
            shift
        done
        case "$MS" in
            0|M0|m0)
                SUMMARY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/launchlens-test-summary.XXXXXX")"
                trap 'rm -rf "$SUMMARY_TMP"' EXIT
                swift build --product LaunchLens >/dev/null
                echo "==> [M0] Running all M0 unit test scopes (Freeze, Scanner, CLI, UI)..."
                swift test --no-parallel --filter "FreezeLedgerTests|ScannerCorrelationTests|CLIRunnerTests|UIAndLocalizationTests" 2>&1 | tee "$SUMMARY_TMP/unit.log"
                echo "==> [M0] Running Scripts/acceptance/m0-acceptance.sh..."
                "$ROOT/Scripts/acceptance/m0-acceptance.sh" "${RECORD_FLAG[@]+"${RECORD_FLAG[@]}"}" 2>&1 | tee "$SUMMARY_TMP/accept.log"
                echo "==> [M0] Running Scripts/acceptance/readme-commands.sh (milestone 0 isolated mode)..."
                "$ROOT/Scripts/acceptance/readme-commands.sh" --mode milestone0 "${RECORD_FLAG[@]+"${RECORD_FLAG[@]}"}" 2>&1 | tee "$SUMMARY_TMP/readme.log"
                print_stage_summary "M0" "$SUMMARY_TMP/unit.log" "m0_acceptance" "$SUMMARY_TMP/accept.log" "$SUMMARY_TMP/readme.log" "not_applicable_in_m0"
                ;;
            1|M1|m1)
                SUMMARY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/launchlens-m1-summary.XXXXXX")"
                trap 'rm -rf "$SUMMARY_TMP"' EXIT
                swift build --product LaunchLens >/dev/null
                echo "==> [M1] Running all unit test scopes (Freeze, Scanner, CLI, UI)..."
                swift test --no-parallel --filter "FreezeLedgerTests|ScannerCorrelationTests|CLIRunnerTests|UIAndLocalizationTests" 2>&1 | tee "$SUMMARY_TMP/unit.log"
                echo "==> [M1] Running Scripts/acceptance/m1-ledger.sh..."
                "$ROOT/Scripts/acceptance/m1-ledger.sh" "${RECORD_FLAG[@]+"${RECORD_FLAG[@]}"}" 2>&1 | tee "$SUMMARY_TMP/m1.log"
                echo "==> [M1] Running Scripts/acceptance/readme-commands.sh (isolated mode)..."
                "$ROOT/Scripts/acceptance/readme-commands.sh" --mode milestone0 "${RECORD_FLAG[@]+"${RECORD_FLAG[@]}"}" 2>&1 | tee "$SUMMARY_TMP/readme.log"
                if [[ "${LAUNCHLENS_REAL_LAUNCHD:-0}" == "1" ]]; then
                    REAL_STATUS="passed"
                else
                    REAL_STATUS="skipped(LAUNCHLENS_REAL_LAUNCHD!=1)"
                fi
                print_stage_summary "M1" "$SUMMARY_TMP/unit.log" "m1_ledger" "$SUMMARY_TMP/m1.log" "$SUMMARY_TMP/readme.log" "$REAL_STATUS"
                ;;
            *)
                echo "Error: Milestone '$MS' is not yet implemented (supported: 0, 1)." >&2
                exit 2
                ;;
        esac
        ;;
    release)
        RECORD_FLAG=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --record)
                    RECORD_FLAG=("--record")
                    ;;
                *)
                    usage
                    ;;
            esac
            shift
        done
        SUMMARY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/launchlens-release-summary.XXXXXX")"
        trap 'rm -rf "$SUMMARY_TMP"' EXIT
        swift build --product LaunchLens >/dev/null
        echo "==> [Release] Running full unit test suite..."
        swift test --no-parallel 2>&1 | tee "$SUMMARY_TMP/unit.log"
        echo "==> [Release] Running Scripts/acceptance/m0-acceptance.sh..."
        "$ROOT/Scripts/acceptance/m0-acceptance.sh" "${RECORD_FLAG[@]+"${RECORD_FLAG[@]}"}" 2>&1 | tee "$SUMMARY_TMP/accept.log"
        echo "==> [Release] Running Scripts/acceptance/m1-ledger.sh..."
        "$ROOT/Scripts/acceptance/m1-ledger.sh" "${RECORD_FLAG[@]+"${RECORD_FLAG[@]}"}" 2>&1 | tee "$SUMMARY_TMP/m1.log"
        echo "==> [Release] Running Scripts/acceptance/readme-commands.sh (release mode)..."
        "$ROOT/Scripts/acceptance/readme-commands.sh" --mode release "${RECORD_FLAG[@]+"${RECORD_FLAG[@]}"}" 2>&1 | tee "$SUMMARY_TMP/readme.log"
        if [[ "${LAUNCHLENS_REAL_LAUNCHD:-0}" == "1" ]]; then
            REAL_STATUS="passed"
        else
            REAL_STATUS="skipped(LAUNCHLENS_REAL_LAUNCHD!=1)"
        fi
        print_stage_summary "Release" "$SUMMARY_TMP/unit.log" "m0_acceptance" "$SUMMARY_TMP/accept.log" "$SUMMARY_TMP/readme.log" "$REAL_STATUS" "m1_ledger" "$SUMMARY_TMP/m1.log"
        ;;
    *)
        usage
        ;;
esac
