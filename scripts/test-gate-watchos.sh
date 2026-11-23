#!/usr/bin/env bash

# Self-test for the watchOS path of the serialized Xcode gate.
#
# The HealthLogWatch scheme (HealthLogWatchTests) runs through the same lock as
# every other Xcode run, on a watch simulator the caller names. The iOS paths
# must stay exactly as they were: the default resolution never picks a watch,
# and the HealthLog scheme never accepts a watch destination.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$repo_root/scripts/run-serialized-xcode-gate.sh"
resolver="$repo_root/scripts/resolve-gate-destination.sh"

test_root="$(mktemp -d /tmp/test-gate-watchos.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT INT TERM

fail() {
    printf 'test-gate-watchos: FAIL: %s\n' "$1" >&2
    exit 1
}

watch_udid="00000000-0000-0000-0000-0000000000A1"
phone_udid="00000000-0000-0000-0000-000000000001"
inventory="$test_root/inventory.json"
command cat >"$inventory" <<JSON
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.watchOS-27-2": [
      {
        "state": "Booted",
        "isAvailable": true,
        "name": "Watch Fixture",
        "udid": "$watch_udid",
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-12-46mm"
      }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
      {
        "state": "Shutdown",
        "isAvailable": true,
        "name": "iPhone Fixture",
        "udid": "$phone_udid",
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Fixture"
      }
    ]
  }
}
JSON

# --- resolver, sourced with a stubbed inventory --------------------------------

resolve() {
    (
        xcrun() {
            [[ "$*" == "simctl list devices available -j" ]] || return 64
            command cat "$inventory"
        }
        xcodebuild() { return 97; }
        PROJECT="$test_root/Absent.xcodeproj"
        if [[ $# -gt 0 ]]; then GATE_DESTINATION="$1"; else unset GATE_DESTINATION; fi
        source "$resolver" 2>/dev/null
        printf '%s\n' "$GATE_DESTINATION"
    )
}

[[ "$(resolve "platform=watchOS Simulator,id=$watch_udid")" == "platform=watchOS Simulator,id=$watch_udid" ]] ||
    fail "an explicit watch simulator must resolve"
[[ "$(resolve "platform=watchOS Simulator,name=Watch Fixture,OS=27.2")" == "platform=watchOS Simulator,name=Watch Fixture,OS=27.2" ]] ||
    fail "a watch simulator named by name and OS must resolve"
[[ "$(resolve)" == "platform=iOS Simulator,id=$phone_udid" ]] ||
    fail "the default must stay an iPhone, even when only a watch is booted"
[[ "$(resolve "platform=iOS Simulator,id=$phone_udid")" == "platform=iOS Simulator,id=$phone_udid" ]] ||
    fail "an explicit iPhone simulator must resolve as before"
if resolve "platform=watchOS Simulator,id=$phone_udid" >/dev/null; then
    fail "an iPhone UDID must not pass as a watch simulator"
fi
if resolve "platform=iOS Simulator,id=$watch_udid" >/dev/null; then
    fail "a watch UDID must not pass as an iPhone simulator"
fi
if resolve "platform=watchOS Simulator,name=Watch Fixture,OS=26.0" >/dev/null; then
    fail "a watch OS that is not installed must fail closed"
fi
if resolve "platform=watchOS,id=$watch_udid" >/dev/null; then
    fail "a physical watch destination must fail closed"
fi

# --- gate, with fake xcodegen and xcodebuild ------------------------------------

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
command cat >"$fake_bin/xcodegen" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$PROJECT"
printf '%s\n' '// !$*UTF8*$!' 'archiveVersion = 1;' 'objects = { root = { isa = PBXProject; }; };' \
    >"$PROJECT/project.pbxproj"
FAKE
command cat >"$fake_bin/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ " $* " == *" -showBuildSettings "* ]] && exit 0
printf 'xcodebuild' >>"$FAKE_TRACE"
printf ' <%s>' "$@" >>"$FAKE_TRACE"
printf '\n' >>"$FAKE_TRACE"
FAKE
command cat >"$fake_bin/fake_census" <<'FAKE'
#!/usr/bin/env bash
printf '4\n'
FAKE
command cat >"$fake_bin/fake_suites" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' WatchPayloadLogicTests WatchSnapshotStoreTests
FAKE
chmod +x "$fake_bin"/*

trace="$test_root/trace"
run_gate() {
    local scheme="$1"
    shift
    env PATH="$fake_bin:$PATH" FAKE_TRACE="$trace" \
        PROJECT="$test_root/HealthLog.xcodeproj" SCHEME="$scheme" \
        HEALTHLOG_XCODE_GATE_LOCK_DIR="$test_root/gate.lock" \
        HEALTHLOG_XCODE_GATE_WAIT_SECONDS=5 \
        HEALTHLOG_GATE_TEST_CENSUS=fake_census HEALTHLOG_GATE_SUITE_CENSUS=fake_suites \
        "$gate" "$@"
}
last_call() { tail -n 1 "$trace"; }

: >"$trace"
GATE_DESTINATION="platform=watchOS Simulator,id=$watch_udid" run_gate HealthLogWatch \
    watch-ok -- test -only-testing:HealthLogWatchTests/WatchPayloadLogicTests >/dev/null 2>&1 ||
    fail "the watch scheme must run on a named watch simulator"
[[ "$(last_call)" == "xcodebuild <-project> <$test_root/HealthLog.xcodeproj> <-scheme> <HealthLogWatch> <-destination> <platform=watchOS Simulator,id=$watch_udid> <-derivedDataPath> </tmp/dd-hl-watch-ok> <test> <-only-testing:HealthLogWatchTests/WatchPayloadLogicTests> <-resultBundlePath> </tmp/xcresult-hl-watch-ok.xcresult>" ]] ||
    fail "unexpected watch command: $(last_call)"

# The selector census guards the watch run exactly as it guards the iOS runs.
if GATE_DESTINATION="platform=watchOS Simulator,id=$watch_udid" run_gate HealthLogWatch \
    watch-ghost -- test -only-testing:HealthLogWatchTests/NoSuchTests >/dev/null 2>&1; then
    fail "a watch selector that ran nothing must fail"
fi

if (unset GATE_DESTINATION; run_gate HealthLogWatch watch-unnamed -- test) >/dev/null 2>&1; then
    fail "the watch scheme must refuse to guess a destination"
fi
if GATE_DESTINATION="platform=iOS Simulator,id=$phone_udid" run_gate HealthLogWatch \
    watch-on-phone -- test >/dev/null 2>&1; then
    fail "the watch scheme must refuse an iOS destination"
fi
if run_gate HealthLogWatch watch-device --physical-device 00008110-ABCDEF1234567890 -- test >/dev/null 2>&1; then
    fail "the watch scheme must refuse a physical device"
fi
if GATE_DESTINATION="platform=watchOS Simulator,id=$watch_udid" run_gate HealthLog \
    phone-on-watch -- build >/dev/null 2>&1; then
    fail "the HealthLog scheme must refuse a watch destination"
fi

# The iOS path stays as it was.
: >"$trace"
GATE_DESTINATION="platform=iOS Simulator,id=$phone_udid" run_gate HealthLog \
    phone-ok -- test -only-testing:HealthLogTests >/dev/null 2>&1 ||
    fail "the HealthLog scheme must still run on an iPhone simulator"
[[ "$(last_call)" == "xcodebuild <-project> <$test_root/HealthLog.xcodeproj> <-scheme> <HealthLog> <-destination> <platform=iOS Simulator,id=$phone_udid> <-derivedDataPath> </tmp/dd-hl-phone-ok> <test> <-only-testing:HealthLogTests> <-resultBundlePath> </tmp/xcresult-hl-phone-ok.xcresult>" ]] ||
    fail "unexpected iOS command: $(last_call)"
run_gate HealthLog phone-device --physical-device 00008110-ABCDEF1234567890 -- build >/dev/null 2>&1 ||
    fail "the physical iPhone path must still run"
[[ "$(last_call)" == *"<-destination> <platform=iOS,id=00008110-ABCDEF1234567890>"* ]] ||
    fail "unexpected physical command: $(last_call)"

printf 'test-gate-watchos: PASS\n'
