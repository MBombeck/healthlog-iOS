#!/usr/bin/env bash

# Repo-side owner of CI's SPM step.
#
# `.github/workflows/ci.yml` ends with `swift build`, which exists to enforce
# ONE architectural claim: "HealthLogCore compiles iOS-free (no UIKit/HealthKit/
# Spezi/FHIR)". That claim is only enforced if the build actually compiles the
# module. From `a617af3f` (phase 3) until 09-15 it did not: the manifest failed
# with `manifest property 'defaultLocalization' not set` before a single file
# was handed to the compiler, so the step was red on every push while the Xcode
# build of the app stayed green — and once the manifest was fixed, six symbols
# turned out to have been missing from the `sources:` allowlist all along.
#
# A gate that reads only an exit code cannot tell those states apart, and it
# cannot see the OTHER way the allowlist rots: `Invalid Source '<path>': File
# not found.` is a WARNING, so an allowlist entry pointing at a deleted file
# (`DesignSystem/Tokens+Tint.swift`, removed by `6eae69dc`) survived unnoticed.
#
# This gate therefore asserts four things and fails closed on any of them:
#
#   1. `swift build` exited 0.
#   2. It emitted no `Invalid Source … File not found.` warning — every path in
#      the `sources:` allowlist resolves.
#   3. It emitted no `error:` line.
#   4. It emitted at least `--min-compiled` `Compiling <target> …` lines — the
#      POSITIVE assertion, the one that distinguishes a real green from a build
#      that succeeded without doing the work.
#
# The build runs into a scratch directory under `TMPDIR` that is removed
# afterwards, so the verdict never depends on (and never pollutes) a warm
# `.build`, and two consecutive runs give the same answer.
#
# `--self-test` proves each rejection against hermetic fixture packages rather
# than against this repository; the fixtures declare no dependencies, so nothing
# reaches the network and nothing is written outside a `mktemp -d`.
#
# Usage:
#   scripts/verify-spm-core-build.sh
#   scripts/verify-spm-core-build.sh --self-test
#   scripts/verify-spm-core-build.sh --package-path DIR --target NAME --min-compiled N

set -euo pipefail

SPM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPM_REPO_ROOT="$(cd "$SPM_SCRIPT_DIR/.." && pwd)"

# The repository's own expectations. `HealthLogCore` compiles 335 files at
# 09-15; 100 is a deliberately loose FLOOR whose only job is to reject a build
# that compiled nothing or nearly nothing. It is never raised to track the real
# number — that would turn a fail-closed gate into a churn generator.
SPM_DEFAULT_TARGET="HealthLogCore"
SPM_DEFAULT_MIN_COMPILED=100

_spm_fail() {
    printf 'verify-spm-core-build: FAIL: %s\n' "$1" >&2
    exit 1
}

_spm_usage() {
    printf 'usage: %s [--self-test] [--package-path DIR] [--target NAME] [--min-compiled N]\n' \
        "$0" >&2
    exit 2
}

# Run `swift build` for one package and assert the four properties above.
# Prints the four measured numbers on success so a green run leaves a receipt
# rather than a bare word. Returns 1 (never aborts) so the self-test can assert
# a rejection.
_spm_check_package() {
    local package_path="$1"
    local target="$2"
    local min_compiled="$3"
    local label="$4"

    [[ -f "$package_path/Package.swift" ]] ||
        { printf 'verify-spm-core-build: no Package.swift at %s\n' "$package_path" >&2; return 1; }

    local scratch log status
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/spm-core-build.XXXXXX")"
    log="$scratch/build.log"

    # Never pipe the build into a filter: the exit code is one of the four
    # things being asserted, and a pipe under `pipefail` reports the filter's.
    set +e
    swift build --package-path "$package_path" --scratch-path "$scratch/.build" \
        >"$log" 2>&1
    status=$?
    set -e

    # `grep -c`, never `grep -q`: under `set -o pipefail` a `-q` exits on its
    # first match and SIGPIPEs the producer, which has silently dropped long
    # files from a derivation three separate times in this phase's tooling.
    local invalid_source error_lines compiled
    invalid_source="$(grep -c 'Invalid Source' "$log" || true)"
    error_lines="$(grep -c 'error:' "$log" || true)"
    compiled="$(grep -c "Compiling ${target} " "$log" || true)"

    local verdict=0
    local reasons=()
    [[ $status -eq 0 ]] || { verdict=1; reasons+=("swift build exited $status"); }
    [[ "$invalid_source" -eq 0 ]] || {
        verdict=1
        reasons+=("$invalid_source unresolved sources: entry/entries (Invalid Source)")
    }
    [[ "$error_lines" -eq 0 ]] || { verdict=1; reasons+=("$error_lines error: line(s)"); }
    [[ "$compiled" -ge "$min_compiled" ]] || {
        verdict=1
        reasons+=("compiled $compiled ${target} file(s), require >= $min_compiled")
    }

    if [[ $verdict -ne 0 ]]; then
        printf 'verify-spm-core-build: %s REJECTED\n' "$label" >&2
        local reason
        for reason in "${reasons[@]}"; do
            printf '  - %s\n' "$reason" >&2
        done
        # Surface the first few build lines so a CI log is actionable without
        # a re-run; the whole log is not echoed because a compile failure in
        # this package runs to four figures of lines.
        sed -n '1,40p' "$log" >&2
    else
        printf 'verify-spm-core-build: %s PASS — exit-code 0, invalid-source 0, error-lines 0, compiled %s %s file(s)\n' \
            "$label" "$compiled" "$target"
    fi

    rm -rf "$scratch"
    return $verdict
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

# Writes a minimal, dependency-free package into $1 and echoes nothing.
_spm_fixture_healthy() {
    local dir="$1"
    mkdir -p "$dir/Sources/FixtureCore"
    cat >"$dir/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FixtureCore",
    targets: [
        .target(name: "FixtureCore", path: "Sources/FixtureCore")
    ]
)
MANIFEST
    printf 'public enum FixtureAlpha { public static let value = 1 }\n' \
        >"$dir/Sources/FixtureCore/Alpha.swift"
    printf 'public enum FixtureBeta { public static let value = 2 }\n' \
        >"$dir/Sources/FixtureCore/Beta.swift"
}

# The real 09-15 defect: a localized resource inside the target path with no
# `defaultLocalization`. SwiftPM hard-errors before compiling anything.
_spm_fixture_localized() {
    local dir="$1"
    _spm_fixture_healthy "$dir"
    mkdir -p "$dir/Sources/FixtureCore/en.lproj"
    printf '"KEY" = "value";\n' >"$dir/Sources/FixtureCore/en.lproj/InfoPlist.strings"
}

# The OTHER half of the 09-15 defect: an allowlist entry pointing at a file that
# does not exist. `swift build` warns and still exits 0, so only assertion 2
# catches it.
_spm_fixture_stale_source() {
    local dir="$1"
    _spm_fixture_healthy "$dir"
    cat >"$dir/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FixtureCore",
    targets: [
        .target(
            name: "FixtureCore",
            path: "Sources/FixtureCore",
            sources: ["Alpha.swift", "Beta.swift", "Deleted.swift"]
        )
    ]
)
MANIFEST
}

_spm_fixture_broken_code() {
    local dir="$1"
    _spm_fixture_healthy "$dir"
    printf 'public enum FixtureGamma { public static let value: Int = "not an Int" }\n' \
        >"$dir/Sources/FixtureCore/Gamma.swift"
}

_spm_self_test() {
    local root
    root="$(mktemp -d "${TMPDIR:-/tmp}/spm-core-build-selftest.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$root'" EXIT

    local failures=0
    local passed=0

    # 1 — a healthy package MUST be accepted, or the gate proves nothing by
    #     rejecting the broken ones.
    _spm_fixture_healthy "$root/healthy"
    if _spm_check_package "$root/healthy" "FixtureCore" 2 "self-test/healthy" >/dev/null 2>&1; then
        passed=$((passed + 1))
    else
        failures=$((failures + 1))
        printf 'verify-spm-core-build: SELF-TEST FAIL: healthy fixture was rejected\n' >&2
    fi

    # 2 — manifest error (the `defaultLocalization` shape).
    _spm_fixture_localized "$root/localized"
    if _spm_check_package "$root/localized" "FixtureCore" 2 "self-test/localized" >/dev/null 2>&1; then
        failures=$((failures + 1))
        printf 'verify-spm-core-build: SELF-TEST FAIL: accepted a manifest error\n' >&2
    else
        passed=$((passed + 1))
    fi

    # 3 — stale `sources:` entry. This one exits 0; only the Invalid Source
    #     assertion rejects it.
    _spm_fixture_stale_source "$root/stale"
    if _spm_check_package "$root/stale" "FixtureCore" 2 "self-test/stale-source" >/dev/null 2>&1; then
        failures=$((failures + 1))
        printf 'verify-spm-core-build: SELF-TEST FAIL: accepted an unresolved sources: entry\n' >&2
    else
        passed=$((passed + 1))
    fi

    # 4 — a compile error.
    _spm_fixture_broken_code "$root/broken"
    if _spm_check_package "$root/broken" "FixtureCore" 2 "self-test/broken-code" >/dev/null 2>&1; then
        failures=$((failures + 1))
        printf 'verify-spm-core-build: SELF-TEST FAIL: accepted a compile error\n' >&2
    else
        passed=$((passed + 1))
    fi

    # 5 — the zero-work green: a build that exits 0 with no warning and no
    #     error, but never compiled the module the gate is about. This is the
    #     assertion the 2026-08 defect needed and nobody had.
    if _spm_check_package "$root/healthy" "GhostCore" 1 "self-test/zero-work" >/dev/null 2>&1; then
        failures=$((failures + 1))
        printf 'verify-spm-core-build: SELF-TEST FAIL: accepted a build that compiled zero target files\n' >&2
    else
        passed=$((passed + 1))
    fi

    if [[ $failures -ne 0 ]]; then
        _spm_fail "self-test: $passed passed, $failures failed"
    fi
    printf 'verify-spm-core-build: SELF-TEST PASS (%s fixtures)\n' "$passed"
}

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

spm_self_test=0
spm_package_path="$SPM_REPO_ROOT"
spm_target="$SPM_DEFAULT_TARGET"
spm_min_compiled="$SPM_DEFAULT_MIN_COMPILED"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --self-test)
            spm_self_test=1
            shift
            ;;
        --package-path)
            [[ $# -ge 2 ]] || _spm_usage
            spm_package_path="$2"
            shift 2
            ;;
        --target)
            [[ $# -ge 2 ]] || _spm_usage
            spm_target="$2"
            shift 2
            ;;
        --min-compiled)
            [[ $# -ge 2 ]] || _spm_usage
            spm_min_compiled="$2"
            [[ "$spm_min_compiled" =~ ^[0-9]+$ ]] || _spm_fail "--min-compiled must be an integer"
            shift 2
            ;;
        *)
            _spm_usage
            ;;
    esac
done

command -v swift >/dev/null 2>&1 || _spm_fail "swift is not on PATH"

if [[ $spm_self_test -eq 1 ]]; then
    _spm_self_test
    exit 0
fi

_spm_check_package "$spm_package_path" "$spm_target" "$spm_min_compiled" \
    "$(basename "$spm_package_path")" ||
    _spm_fail "SPM core build gate rejected $spm_package_path"
