#!/usr/bin/env bash
# Build 274 (public #2). Refuses a Mach-O that carries a NON-weak reference to a
# HealthKit symbol newer than the app's deployment target (iOS 26.0). dyld
# resolves such a reference at load time and aborts the launch on an older OS
# ("Symbol not found: _HKMedicationGeneralFormCapsule", build 273, iPhone16,1 /
# iOS 18.7.8, while the target was 18.0). An availability annotation on the
# CALL does not weaken the LINK; only an un-referenced or weakly-imported symbol
# survives an older dyld. The script keeps its name so CI and the producer need
# no rewiring.
#
# Usage:
#   scripts/verify-no-strong-ios26-symbols.sh <mach-o binary>
#   scripts/verify-no-strong-ios26-symbols.sh --self-test
#
# Exit 0 PASS, 1 FINDING (a strong post-floor import), 2 TOOLFAIL.
set -euo pipefail

# HealthKit API surface newer than iOS 26.0 that the app touches (from 1.5 the
# iOS 27 limited-history call). The iOS 26.0 medication symbols left the list
# with the 26.0 floor: every supported OS exports them. Extend when a newer
# HealthKit symbol is adopted. `earliestAuthorizedSampleDate` matches the Swift
# overlay symbol `$sSo13HKHealthStoreC9HealthKitE28earliestAuthorizedSampleDate...`
# that HealthKit exports from iOS 27; the app's typed call goes through the
# Objective-C method and links nothing, but a strong reference to the overlay
# would abort the launch on iOS 26. HRV as RMSSD (iOS 27) is read through its
# raw identifier string and links nothing; the typed constant would link
# `_HKQuantityTypeIdentifierHeartRateVariabilityRMSSD`.
PATTERN='earliestAuthorizedSampleDate|_HKQuantityTypeIdentifierHeartRateVariabilityRMSSD'

finding() { printf 'verify-no-strong-ios26-symbols: FINDING: %s\n' "$1" >&2; exit 1; }
toolfail() { printf 'verify-no-strong-ios26-symbols: TOOLFAIL: %s\n' "$1" >&2; exit 2; }

strong_matches() {
    # stdin: nm -m listing. stdout: the non-weak lines that match the pattern.
    grep -E 'from HealthKit' | grep -v ' weak ' | grep -E "$PATTERN" || true
}

# A failing self-test means the CHECKER is broken, not that a binary is bad, so
# every self-test failure exits 2 (TOOLFAIL). Exit 1 is reserved for a real
# finding in a real binary; a broken checker that exited 1 would read to the
# release gate as "this candidate links a post-floor symbol strongly" and send
# someone hunting a defect that is not in the app.
if [[ "${1:-}" == "--self-test" ]]; then
    ios26='                 (undefined) external _HKMedicationGeneralFormCapsule (from HealthKit)'
    [[ -z "$(printf '%s\n' "$ios26" | strong_matches)" ]] || toolfail "self-test: a strong iOS-26.0 symbol was flagged at the 26.0 floor"
    [[ -z "$(printf '%s\n' '(undefined) external _HKQuantityTypeIdentifierHeartRate (from HealthKit)' | strong_matches)" ]] || toolfail "self-test: an iOS-8 symbol was flagged"
    ios27='                 (undefined) external _$sSo13HKHealthStoreC9HealthKitE28earliestAuthorizedSampleDate3forSDySo12HKObjectTypeC10Foundation0H0VGShyAGG_tYaKF (from HealthKit)'
    [[ -n "$(printf '%s\n' "$ios27" | strong_matches)" ]] || toolfail "self-test: the strong iOS-27 fixture was not detected"
    [[ -z "$(printf '%s\n' "${ios27/external/weak external}" | strong_matches)" ]] || toolfail "self-test: the weak iOS-27 fixture was flagged"
    rmssd='                 (undefined) external _HKQuantityTypeIdentifierHeartRateVariabilityRMSSD (from HealthKit)'
    [[ -n "$(printf '%s\n' "$rmssd" | strong_matches)" ]] || toolfail "self-test: the strong iOS-27 RMSSD fixture was not detected"
    [[ -z "$(printf '%s\n' "${rmssd/external/weak external}" | strong_matches)" ]] || toolfail "self-test: the weak iOS-27 RMSSD fixture was flagged"
    [[ -z "$(printf '%s\n' '(undefined) external _HKQuantityTypeIdentifierHeartRateVariabilitySDNN (from HealthKit)' | strong_matches)" ]] || toolfail "self-test: the iOS-11 SDNN symbol was flagged"
    printf 'verify-no-strong-ios26-symbols: self-test PASS\n'
    exit 0
fi

binary="${1:-}"
[[ -n "$binary" ]] || toolfail "usage: $0 <mach-o binary> | --self-test"
[[ -f "$binary" ]] || toolfail "no file at $binary"
command -v nm >/dev/null || toolfail "nm not on PATH"

listing="$(nm -m "$binary" 2>/dev/null | grep -E 'from HealthKit' || true)"
[[ -n "$listing" ]] || toolfail "nm listed no HealthKit imports for $binary — wrong binary?"

strong="$(printf '%s\n' "$listing" | strong_matches)"
if [[ -n "$strong" ]]; then
    printf '%s\n' "$strong" >&2
    finding "non-weak post-iOS-26.0 HealthKit symbol(s) in $binary — the app would not launch on iOS 26"
fi

total="$(printf '%s\n' "$listing" | wc -l | tr -d ' ')"
weak_count="$(printf '%s\n' "$listing" | grep -c ' weak ' || true)"
printf 'verify-no-strong-ios26-symbols: PASS binary=%s healthkit_imports=%s weak=%s strong_ios26=0\n' "$binary" "$total" "$weak_count"
