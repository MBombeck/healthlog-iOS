#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolver="$script_dir/resolve-gate-destination.sh"
fixture='{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
      {
        "state": "Booted",
        "isAvailable": true,
        "name": "iPhone Fixture",
        "udid": "00000000-0000-0000-0000-000000000001",
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Fixture"
      }
    ]
  }
}'

xcrun() {
    [[ "$*" == "simctl list devices available -j" ]] || return 64
    printf '%s\n' "$fixture"
}

fail() {
    printf 'test-resolve-gate-destination: %s\n' "$1" >&2
    exit 1
}

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
clean_project="$temporary_root/HealthLog.xcodeproj"
mkdir -p "$clean_project/project.xcworkspace/xcshareddata/swiftpm"
: >"$clean_project/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

(
    xcodebuild() { return 97; }
    unset GATE_DESTINATION
    PROJECT="$clean_project"
    source "$resolver"
    [[ "$GATE_DESTINATION" == "platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001" ]]
) || fail "tracked workspace metadata without project.pbxproj must use simctl before generation"

(
    xcodebuild() { return 97; }
    GATE_DESTINATION="platform=iOS Simulator,name=iPhone Fixture,OS=latest"
    PROJECT="$clean_project"
    source "$resolver"
    [[ "$GATE_DESTINATION" == "platform=iOS Simulator,name=iPhone Fixture,OS=latest" ]]
) || fail "a valid explicit destination must survive pre-generation validation"

if (
    xcodebuild() { return 0; }
    GATE_DESTINATION="platform=iOS Simulator,id=FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
    PROJECT="$clean_project"
    source "$resolver"
); then
    fail "an invalid explicit destination must fail closed before project generation"
fi

if (
    xcodebuild() { return 0; }
    GATE_DESTINATION="platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001,name=Wrong Fixture"
    PROJECT="$clean_project"
    source "$resolver"
); then
    fail "conflicting explicit destination fields must fail closed before project generation"
fi

zero_project="$temporary_root/Zero.xcodeproj"
mkdir "$zero_project"
: >"$zero_project/project.pbxproj"
if (
    xcodebuild() { return 0; }
    unset GATE_DESTINATION
    PROJECT="$zero_project"
    source "$resolver"
); then
    fail "a zero-byte project.pbxproj must fail closed"
fi

invalid_project="$temporary_root/Invalid.xcodeproj"
mkdir "$invalid_project"
printf 'not an Xcode project\n' >"$invalid_project/project.pbxproj"
if (
    xcodebuild() { return 0; }
    unset GATE_DESTINATION
    PROJECT="$invalid_project"
    source "$resolver"
); then
    fail "a malformed project.pbxproj must fail closed"
fi

generated_project="$temporary_root/Generated.xcodeproj"
mkdir "$generated_project"
printf '%s\n' '// !$*UTF8*$!' 'archiveVersion = 1;' 'objects = {' 'isa = PBXProject;' '};' \
    >"$generated_project/project.pbxproj"
(
    xcodebuild() {
        [[ "$*" == *"-project $generated_project"* ]]
    }
    GATE_DESTINATION="platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001"
    PROJECT="$generated_project"
    source "$resolver"
) || fail "a minimally valid generated project must use xcodebuild scheme validation"

if (
    xcodebuild() { return 65; }
    GATE_DESTINATION="platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001"
    PROJECT="$generated_project"
    source "$resolver"
); then
    fail "xcodebuild rejection must fail an explicit destination once the project exists"
fi

printf 'test-resolve-gate-destination: PASS\n'
