#!/usr/bin/env bash

set -euo pipefail

_gate_fail() {
    printf 'run-serialized-xcode-gate: %s\n' "$1" >&2
    exit 2
}

_gate_usage() {
    _gate_fail "usage: $0 <safe-suffix> [--physical-device <UDID>] -- <build|test|...> [xcodebuild arguments]"
}

[[ $# -ge 3 ]] || _gate_usage

gate_suffix="$1"
shift
[[ "$gate_suffix" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,79}$ ]] ||
    _gate_fail "suffix must be 1-80 alphanumeric/hyphen characters"

physical_udid=""
if [[ "${1:-}" == "--physical-device" ]]; then
    [[ $# -ge 3 ]] || _gate_usage
    physical_udid="$2"
    shift 2
    [[ -n "$physical_udid" ]] || _gate_fail "physical-device UDID must not be empty"
    [[ "$physical_udid" =~ ^[A-Za-z0-9][A-Za-z0-9-]{7,79}$ ]] ||
        _gate_fail "physical-device UDID must be one exact identifier, not a destination alias"
fi

[[ "${1:-}" == "--" ]] || _gate_usage
shift
[[ $# -ge 1 ]] || _gate_usage

for gate_arg in "$@"; do
    case "$gate_arg" in
        -destination | -derivedDataPath | -resultBundlePath | -project | -scheme)
            _gate_fail "caller may not override $gate_arg"
            ;;
    esac
done

gate_action="$1"
gate_lock_dir="${HEALTHLOG_XCODE_GATE_LOCK_DIR:-/tmp/healthlog-xcode-gate.lock}"
gate_lock_owner="$gate_lock_dir/owner-pid"
gate_wait_seconds="${HEALTHLOG_XCODE_GATE_WAIT_SECONDS:-1800}"
[[ "$gate_wait_seconds" =~ ^[0-9]+$ ]] || _gate_fail "HEALTHLOG_XCODE_GATE_WAIT_SECONDS must be a non-negative integer"

gate_acquired=0
gate_started=$SECONDS

_gate_test_census() {
    xcrun xcresulttool get test-results summary \
        --path "$1" --format json 2>/dev/null |
        /usr/bin/python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("totalTestCount", "unreadable"))
except Exception:
    print("unreadable")' 2>/dev/null
}

# Every suite that actually contributed a case, by type name. A Swift Testing
# suite reports its *display* name at suite level, so the type is recovered
# from each case identifier instead.
_gate_executed_suites() {
    xcrun xcresulttool get test-results tests --path "$1" 2>/dev/null |
        /usr/bin/python3 -c 'import json,sys
seen = set()
def walk(n):
    if n.get("nodeType") == "Test Case" and n.get("nodeIdentifier"):
        seen.add(n["nodeIdentifier"].split("/")[0])
    for c in n.get("children", []):
        walk(c)
try:
    for n in json.load(sys.stdin).get("testNodes", []):
        walk(n)
except Exception:
    raise SystemExit
print("\n".join(sorted(seen)))' 2>/dev/null
}

_gate_release() {
    if [[ "$gate_acquired" -eq 1 && -d "$gate_lock_dir" ]]; then
        local recorded_owner=""
        recorded_owner="$(cat "$gate_lock_owner" 2>/dev/null || true)"
        if [[ "$recorded_owner" == "$$" ]]; then
            rm -f -- "$gate_lock_owner"
            rmdir -- "$gate_lock_dir" 2>/dev/null || true
        fi
    fi
}
trap _gate_release EXIT
trap '_gate_release; exit 130' INT
trap '_gate_release; exit 143' TERM

gate_ownerless_since=""
while ! mkdir -- "$gate_lock_dir" 2>/dev/null; do
    [[ -d "$gate_lock_dir" ]] || continue
    if [[ ! -f "$gate_lock_owner" ]]; then
        # 2026-09-09 — a second gate user (the CI runners share this lock with
        # the release producer) may have created the directory a moment ago and
        # not yet written its owner record. Give it a few seconds before
        # treating the lock as ambiguous; the refusal itself is unchanged.
        [[ -n "$gate_ownerless_since" ]] || gate_ownerless_since="$SECONDS"
        if ((SECONDS - gate_ownerless_since >= 5)); then
            _gate_fail "lock exists without an owner record; refusing ambiguous cleanup: $gate_lock_dir"
        fi
        sleep 0.1
        continue
    fi
    gate_owner="$(cat "$gate_lock_owner" 2>/dev/null || true)"
    if [[ ! "$gate_owner" =~ ^[1-9][0-9]*$ ]]; then
        # Same window as above, one step later: the record file exists but its
        # PID has not been written yet (a reader can see the empty file).
        [[ -n "$gate_ownerless_since" ]] || gate_ownerless_since="$SECONDS"
        if ((SECONDS - gate_ownerless_since >= 5)); then
            _gate_fail "lock has an invalid owner record; refusing ambiguous cleanup: $gate_lock_dir"
        fi
        sleep 0.1
        continue
    fi
    gate_ownerless_since=""

    if ! kill -0 "$gate_owner" 2>/dev/null; then
        gate_confirmed_owner="$(cat "$gate_lock_owner" 2>/dev/null || true)"
        [[ "$gate_confirmed_owner" == "$gate_owner" ]] || continue
        rm -f -- "$gate_lock_owner"
        rmdir -- "$gate_lock_dir" 2>/dev/null ||
            _gate_fail "stale lock contains unexpected files; refusing recursive cleanup: $gate_lock_dir"
        continue
    fi

    if ((SECONDS - gate_started >= gate_wait_seconds)); then
        _gate_fail "timed out waiting for live Xcode gate owner PID $gate_owner"
    fi
    sleep 0.1
done

gate_acquired=1
printf '%s\n' "$$" >"$gate_lock_owner"

command -v xcodegen >/dev/null 2>&1 || _gate_fail "xcodegen is unavailable"
command -v xcodebuild >/dev/null 2>&1 || _gate_fail "xcodebuild is unavailable"
xcodegen generate

if [[ -n "$physical_udid" ]]; then
    GATE_DESTINATION="platform=iOS,id=$physical_udid"
    export GATE_DESTINATION
else
    # shellcheck source=resolve-gate-destination.sh
    source "$(cd "$(dirname "$0")" && pwd)/resolve-gate-destination.sh"
    [[ "$GATE_DESTINATION" == platform=iOS\ Simulator,* ]] ||
        _gate_fail "simulator mode resolved a non-simulator destination"
fi

gate_derived_data="/tmp/dd-hl-$gate_suffix"
gate_result_bundle="/tmp/xcresult-hl-$gate_suffix.xcresult"

if [[ "$gate_action" == "test" ]]; then
    case "$gate_result_bundle" in
        /tmp/xcresult-hl-*.xcresult) ;;
        *) _gate_fail "refusing unsafe result-bundle path" ;;
    esac
    if [[ -e "$gate_result_bundle" ]]; then
        rm -rf -- "$gate_result_bundle"
    fi
fi

gate_command=(
    xcodebuild
    -project "${PROJECT:-HealthLog.xcodeproj}"
    -scheme "${SCHEME:-HealthLog}"
    -destination "$GATE_DESTINATION"
    -derivedDataPath "$gate_derived_data"
)
gate_command+=("$@")
if [[ "$gate_action" == "test" ]]; then
    gate_command+=(-resultBundlePath "$gate_result_bundle")
fi

printf 'run-serialized-xcode-gate: pid=%s suffix=%s destination=%s derivedData=%s\n' \
    "$$" "$gate_suffix" "$GATE_DESTINATION" "$gate_derived_data" >&2
if [[ "$gate_action" == "test" ]]; then
    printf 'run-serialized-xcode-gate: resultBundle=%s\n' "$gate_result_bundle" >&2
fi

"${gate_command[@]}"
gate_status=$?

# A `test` action that executed nothing is a false green, not a pass. Swift
# Testing does not address a case by bare function name, so a selector like
# `-only-testing:Target/SuiteName/caseName` silently matches nothing and
# xcodebuild still reports "Test run with 0 tests ... passed" and exits 0. The
# result bundle is the only honest witness, so a zero-test run fails here
# rather than in whatever reads the gate's exit code later.
if [[ "$gate_action" == "test" && $gate_status -eq 0 ]]; then
    # Injectable so the self-test can exercise the census itself; the default
    # is the only thing that ever runs against a real bundle.
    gate_test_total="$("${HEALTHLOG_GATE_TEST_CENSUS:-_gate_test_census}" "$gate_result_bundle")"
    case "$gate_test_total" in
        "" | unreadable)
            _gate_fail "test gate produced no readable result bundle: $gate_result_bundle"
            ;;
        0)
            _gate_fail "test gate executed 0 tests — check the -only-testing selectors (Swift Testing needs the suite, not a bare case name)"
            ;;
    esac

    # A nonzero total is not enough. In a mixed selector list one valid entry
    # carries the run while a broken one contributes nothing, so the gate would
    # pass on suites that never included the assertion it was meant to prove.
    # Each selector must therefore be traceable to a suite that actually ran.
    gate_executed_suites="$("${HEALTHLOG_GATE_SUITE_CENSUS:-_gate_executed_suites}" "$gate_result_bundle")"
    if [[ -n "$gate_executed_suites" ]]; then
        for gate_selector in "$@"; do
            case "$gate_selector" in
                -only-testing:*) ;;
                *) continue ;;
            esac
            gate_selector_path="${gate_selector#-only-testing:}"
            # A bare target selector names no suite and needs no tracing.
            [[ "$gate_selector_path" == */* ]] || continue
            gate_selector_suite="${gate_selector_path#*/}"
            gate_selector_suite="${gate_selector_suite%%/*}"
            [[ -n "$gate_selector_suite" ]] || continue
            if ! printf '%s\n' "$gate_executed_suites" | grep -Fxq "$gate_selector_suite"; then
                _gate_fail "selector $gate_selector contributed no tests — suite $gate_selector_suite never ran (a bare case name matches nothing in Swift Testing)"
            fi
        done
    fi
fi

exit $gate_status
