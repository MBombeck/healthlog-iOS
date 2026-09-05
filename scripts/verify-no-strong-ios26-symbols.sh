#!/usr/bin/env bash
# Build 274 (public #2). Refuses a Mach-O that carries a NON-weak reference to a
# HealthKit symbol that only exists from iOS 26, while the app's deployment
# target is 18.0. dyld resolves such a reference at load time and aborts the
# launch on iOS 18 ("Symbol not found: _HKMedicationGeneralFormCapsule",
# build 273, iPhone16,1 / iOS 18.7.8). An availability annotation on the CALL
# does not weaken the LINK; only an un-referenced or weakly-imported symbol
# survives an older dyld.
#
# Usage:
#   scripts/verify-no-strong-ios26-symbols.sh <mach-o binary>
#   scripts/verify-no-strong-ios26-symbols.sh --self-test
#
# Exit 0 PASS, 1 FINDING (a strong iOS-26 import), 2 TOOLFAIL.
set -euo pipefail

# iOS-26-only HealthKit API surface the app touches (medications). Extend when
# a new iOS-26 HealthKit type is adopted.
PATTERN='_HKMedicationGeneralForm|_HKMedicationConcept|HKUserAnnotatedMedication|HKMedicationDoseEvent|_OBJC_CLASS_\$_HKHealthConceptIdentifier|_OBJC_CLASS_\$_HKClinicalCoding'

finding() { printf 'verify-no-strong-ios26-symbols: FINDING: %s\n' "$1" >&2; exit 1; }
toolfail() { printf 'verify-no-strong-ios26-symbols: TOOLFAIL: %s\n' "$1" >&2; exit 2; }

strong_matches() {
    # stdin: nm -m listing. stdout: the non-weak lines that match the pattern.
    grep -E 'from HealthKit' | grep -v ' weak ' | grep -E "$PATTERN" || true
}

if [[ "${1:-}" == "--self-test" ]]; then
    strong='                 (undefined) external _HKMedicationGeneralFormCapsule (from HealthKit)'
    weak='                 (undefined) weak external _OBJC_CLASS_$_HKMedicationDoseEvent (from HealthKit)'
    [[ -n "$(printf '%s\n' "$strong" | strong_matches)" ]] || finding "self-test: the strong fixture was not detected"
    [[ -z "$(printf '%s\n' "$weak" | strong_matches)" ]] || finding "self-test: the weak fixture was flagged"
    [[ -z "$(printf '%s\n' '(undefined) external _HKQuantityTypeIdentifierHeartRate (from HealthKit)' | strong_matches)" ]] || finding "self-test: an iOS-8 symbol was flagged"
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
    finding "non-weak iOS-26 HealthKit symbol(s) in $binary — the app would not launch on iOS 18"
fi

total="$(printf '%s\n' "$listing" | wc -l | tr -d ' ')"
weak_count="$(printf '%s\n' "$listing" | grep -c ' weak ' || true)"
printf 'verify-no-strong-ios26-symbols: PASS binary=%s healthkit_imports=%s weak=%s strong_ios26=0\n' "$binary" "$total" "$weak_count"
