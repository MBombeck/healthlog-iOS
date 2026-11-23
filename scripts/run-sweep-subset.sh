#!/usr/bin/env bash
# Photographs the layout-critical subset of the QA sweep on one display.
#
#   scripts/run-sweep-subset.sh <display> <simulator-udid> <gate-suffix> [--limit N] [--print]
#
# <display> is the HL_SWEEP_DISPLAY tag (iphone, iphone-dark, ipad13-portrait,
# ipad13-landscape, ipadmini, duo-outer, duo-inner, ipad13-ax5 ...); the sweep
# writes its pictures to $SWEEP_OUT/<display> (default /tmp/hl-sweep-<suffix>).
# The tests come from scripts/sweep-layout-subset.txt and go through the
# serialized Xcode gate with -only-testing. Run `build-for-testing` through the
# gate with the same suffix first. --limit N runs only the first N tests (a dry
# run of the way), --print shows the selectors without running anything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

fail() { printf 'run-sweep-subset: %s\n' "$1" >&2; exit 2; }

[[ $# -ge 3 ]] || fail "usage: $0 <display> <simulator-udid> <gate-suffix> [--limit N] [--print]"
display="$1"; udid="$2"; suffix="$3"; shift 3
[[ "$display" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || fail "display must be lowercase letters, digits and hyphens"

limit=0; print_only=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || fail "--limit needs a number"; limit="$2"; shift 2 ;;
        --print) print_only=1; shift ;;
        *) fail "unknown argument $1" ;;
    esac
done

selectors=()
count=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^[A-Za-z0-9_]+/[A-Za-z0-9_]+$ ]] || fail "bad line: $line"
    class="${line%%/*}"; method="${line##*/}"
    # The name must exist: a selector that matches nothing runs empty and passes.
    # The method must live in a file that declares or extends that class.
    found=0
    while IFS= read -r file; do
        if grep -qE "func[[:space:]]+${method}[[:space:]]*\(" "$file"; then found=1; break; fi
    done < <(grep -rlE "(class|extension)[[:space:]]+${class}\b" HealthLogUITests)
    [[ "$found" -eq 1 ]] || fail "no test ${method} in a file of class ${class}"
    count=$((count + 1))
    if [[ "$limit" -gt 0 && "$count" -gt "$limit" ]]; then continue; fi
    selectors+=("-only-testing:HealthLogUITests/${line}")
done < "${SWEEP_SUBSET_FILE:-$SCRIPT_DIR/sweep-layout-subset.txt}"

[[ ${#selectors[@]} -gt 0 ]] || fail "the subset is empty"
out="${SWEEP_OUT:-/tmp/hl-sweep-${suffix}}"

if [[ "$print_only" -eq 1 ]]; then
    printf '%s\n' "${selectors[@]}"
    exit 0
fi

export GATE_DESTINATION="platform=iOS Simulator,id=${udid}"
export HEALTHLOG_XCODE_GATE_WAIT_SECONDS="${HEALTHLOG_XCODE_GATE_WAIT_SECONDS:-14400}"
export TEST_RUNNER_HL_SWEEP_OUT="$out"
export TEST_RUNNER_HL_SWEEP_DISPLAY="$display"
[[ -z "${HL_SWEEP_LANG:-}" ]] || export TEST_RUNNER_HL_SWEEP_LANG="$HL_SWEEP_LANG"

log="${SWEEP_LOG:-/tmp/hl-sweep-${suffix}-${display}.log}"
marker="$(mktemp "${TMPDIR:-/tmp}/hl-sweep-marker.XXXXXX")"
trap 'rm -f "$marker"' EXIT
sleep 1
set +e
"$SCRIPT_DIR/run-serialized-xcode-gate.sh" "$suffix" --result-label "sweep-${display}" -- \
    test-without-building "${selectors[@]}" > "$log" 2>&1
status=$?
set -e
printf 'run-sweep-subset: gate exit %s, log %s\n' "$status" "$log"
[[ "$status" -eq 0 ]] || exit "$status"

# A green run must still have run every selector and photographed something.
for sel in "${selectors[@]}"; do
    name="${sel#-only-testing:HealthLogUITests/}"
    grep -qE "Test Case '-\[HealthLogUITests\.${name%%/*} ${name##*/}\]' passed" "$log" ||
        fail "selector ${name} did not pass in the log (missing, skipped or failed)"
done
# The number of executed tests must equal the number of selectors, with none skipped.
executed=$(grep -E "^[[:space:]]*Executed [0-9]+ tests?," "$log" | tail -1 | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')
[[ "${executed:-0}" -eq "${#selectors[@]}" ]] || fail "executed ${executed:-0} tests for ${#selectors[@]} selectors"
! grep -qE "Test Case .* skipped" "$log" || fail "a selected test was skipped"
pictures=$(find "$out/$display" -name '*.png' -newer "$marker" 2>/dev/null | wc -l | tr -d ' ')
[[ "$pictures" -ge "${#selectors[@]}" ]] || fail "only ${pictures} pictures for ${#selectors[@]} selectors in $out/$display"
printf 'run-sweep-subset: %s selectors passed, %s pictures in %s\n' "${#selectors[@]}" "$pictures" "$out/$display"
