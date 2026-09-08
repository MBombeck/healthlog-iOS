#!/usr/bin/env bash

set -euo pipefail

test_root="$(mktemp -d /tmp/test-serialized-xcode-gate.XXXXXX)"
_test_cleanup() {
    rm -rf -- "$test_root"
}
trap _test_cleanup EXIT INT TERM

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/xcodegen" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodegen %s %s\n' "$$" "$*" >>"$FAKE_TRACE"
mkdir -p "$PROJECT"
cat >"$PROJECT/project.pbxproj" <<'PBX'
// !$*UTF8*$!
archiveVersion = 1;
objects = { root = { isa = PBXProject; }; };
PBX
FAKE

cat >"$fake_bin/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodebuild %s' "$$" >>"$FAKE_TRACE"
printf ' <%s>' "$@" >>"$FAKE_TRACE"
printf '\n' >>"$FAKE_TRACE"
if [[ " $* " == *" -showBuildSettings "* ]]; then
    exit 0
fi
if [[ -n "${FAKE_ACTIVE_FILE:-}" ]]; then
    if ! (set -o noclobber; printf '%s\n' "$$" >"$FAKE_ACTIVE_FILE") 2>/dev/null; then
        printf 'overlap\n' >>"$FAKE_TRACE"
        exit 91
    fi
    sleep "${FAKE_SLEEP:-0}"
    rm -f -- "$FAKE_ACTIVE_FILE"
fi
exit "${FAKE_XCODEBUILD_STATUS:-0}"
FAKE
chmod +x "$fake_bin/xcodegen" "$fake_bin/xcodebuild"

trace="$test_root/trace"
project="$test_root/HealthLog.xcodeproj"
lock="$test_root/gate.lock"
common_env=(
    PATH="$fake_bin:$PATH"
    FAKE_TRACE="$trace"
    PROJECT="$project"
    SCHEME=HealthLog
    HEALTHLOG_XCODE_GATE_LOCK_DIR="$lock"
    HEALTHLOG_XCODE_GATE_WAIT_SECONDS=5
    # The fake xcodebuild writes no result bundle, so the zero-test census is
    # stubbed here. Its own three outcomes are asserted separately below.
    HEALTHLOG_GATE_TEST_CENSUS=fake_census
    HEALTHLOG_GATE_SUITE_CENSUS=fake_suites
)

cat >"$fake_bin/fake_census" <<'CENSUS'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_TEST_COUNT:-7}"
CENSUS
cat >"$fake_bin/fake_suites" <<'SUITES'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_SUITES:-FooTests}"
SUITES
chmod +x "$fake_bin/fake_census" "$fake_bin/fake_suites"

run_gate() {
    env "${common_env[@]}" "$repo_root/scripts/run-serialized-xcode-gate.sh" "$@"
}

GATE_DESTINATION='platform=iOS Simulator,id=SIM-123' run_gate simulator-one -- test -only-testing:HealthLogTests/FooTests
rg -F '<-destination> <platform=iOS Simulator,id=SIM-123>' "$trace" >/dev/null
rg -F '<-derivedDataPath> </tmp/dd-hl-simulator-one>' "$trace" >/dev/null
rg -F '<-resultBundlePath> </tmp/xcresult-hl-simulator-one.xcresult>' "$trace" >/dev/null
rg -F '<-only-testing:HealthLogTests/FooTests>' "$trace" >/dev/null

# A test gate that executed nothing is a false green: Swift Testing ignores a
# bare case name in `-only-testing`, so xcodebuild reports "0 tests passed".
if FAKE_TEST_COUNT=0 run_gate census-zero -- test -only-testing:HealthLogTests/FooTests/someCase >/dev/null 2>&1; then
    echo 'expected zero-test rejection' >&2
    exit 1
fi
if FAKE_TEST_COUNT=unreadable run_gate census-unreadable -- test -only-testing:HealthLogTests/FooTests >/dev/null 2>&1; then
    echo 'expected unreadable-bundle rejection' >&2
    exit 1
fi
FAKE_TEST_COUNT=3 run_gate census-positive -- test -only-testing:HealthLogTests/FooTests

# A mixed list where one selector contributed nothing is the dangerous case:
# the valid selector carries the census, so only per-selector tracing catches it.
if FAKE_TEST_COUNT=3 FAKE_SUITES=FooTests run_gate census-mixed -- test \
    -only-testing:HealthLogTests/FooTests -only-testing:HealthLogTests/BarTests/someCase >/dev/null 2>&1; then
    echo 'expected mixed-selector rejection' >&2
    exit 1
fi
FAKE_TEST_COUNT=5 FAKE_SUITES=$'BarTests\nFooTests' run_gate census-mixed-ok -- test \
    -only-testing:HealthLogTests/FooTests -only-testing:HealthLogTests/BarTests
# A bare target selector names no suite and must stay exempt.
FAKE_TEST_COUNT=9 FAKE_SUITES=FooTests run_gate census-bare-target -- test -only-testing:HealthLogTests
# A build action has no result bundle and must not be censused.
FAKE_TEST_COUNT=0 run_gate census-build-exempt -- build

run_gate physical-one --physical-device 00008110-ABCDEF1234567890 -- build
rg -F '<-destination> <platform=iOS,id=00008110-ABCDEF1234567890>' "$trace" >/dev/null
! rg -F 'platform=iOS Simulator' "$trace" | tail -1 | rg -F 'physical-one' >/dev/null

if run_gate bad-device --physical-device 'platform=iOS,name=iPhone' -- build >/dev/null 2>&1; then
    echo 'expected destination alias rejection' >&2
    exit 1
fi
if run_gate missing-device --physical-device -- build >/dev/null 2>&1; then
    echo 'expected missing UDID rejection' >&2
    exit 1
fi
if run_gate unsafe/suffix -- build >/dev/null 2>&1; then
    echo 'expected unsafe suffix rejection' >&2
    exit 1
fi
if run_gate override -- test -destination evil >/dev/null 2>&1; then
    echo 'expected injected destination rejection' >&2
    exit 1
fi

active_file="$test_root/active"
env "${common_env[@]}" GATE_DESTINATION='platform=iOS Simulator,id=SIM-123' \
    FAKE_ACTIVE_FILE="$active_file" FAKE_SLEEP=0.4 \
    "$repo_root/scripts/run-serialized-xcode-gate.sh" serial-a -- build &
first_pid=$!
sleep 0.05
env "${common_env[@]}" GATE_DESTINATION='platform=iOS Simulator,id=SIM-123' \
    FAKE_ACTIVE_FILE="$active_file" FAKE_SLEEP=0.1 \
    "$repo_root/scripts/run-serialized-xcode-gate.sh" serial-b -- build &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
! rg -F 'overlap' "$trace" >/dev/null

if env "${common_env[@]}" GATE_DESTINATION='platform=iOS Simulator,id=SIM-123' \
    FAKE_XCODEBUILD_STATUS=23 \
    "$repo_root/scripts/run-serialized-xcode-gate.sh" failure-cleanup -- build >/dev/null 2>&1
then
    echo 'expected fake xcodebuild failure' >&2
    exit 1
fi
[[ ! -e "$lock" ]]

mkdir "$lock"
printf '99999999\n' >"$lock/owner-pid"
GATE_DESTINATION='platform=iOS Simulator,id=SIM-123' run_gate stale-owner -- build
[[ ! -e "$lock" ]]

mkdir "$lock"
printf 'ambiguous\n' >"$lock/owner-pid"
if GATE_DESTINATION='platform=iOS Simulator,id=SIM-123' run_gate ambiguous-owner -- build >/dev/null 2>&1; then
    echo 'expected ambiguous lock rejection' >&2
    exit 1
fi
[[ -d "$lock" ]]
rm -rf -- "$lock"

rg -F '<-derivedDataPath> </tmp/dd-hl-serial-a>' "$trace" >/dev/null
rg -F '<-derivedDataPath> </tmp/dd-hl-serial-b>' "$trace" >/dev/null

echo 'serialized Xcode gate self-tests passed'
