#!/usr/bin/env bash

# Fail-closed contract for the `function_body_length` quality floor (09-08).
#
# Phase 9 replaced a *global* `function_body_length` suppression with an
# audited, non-growing debt ledger. A global disable is the failure mode this
# script exists to make impossible: it is one line in `.swiftlint.yml`, it is
# invisible in every downstream gate, and it silently re-permits every function
# body in the repository at once.
#
# The numbers below are frozen HERE, in the checker — not in the files it
# reads. A document cannot weaken a budget it does not own. Lowering a ceiling
# is a one-line edit in this file with the phase attestation next to it;
# raising one is the same edit, and shows up in review as exactly that.
#
# Exit codes are load-bearing, because "the script was unhappy" and "the
# contract was broken" are different facts:
#
#   0  PASS      — every clause holds.
#   1  FINDING   — a named contract violation. The message names which.
#   2  TOOLFAIL  — the checker could not run (missing/malformed input, bad
#                  usage). Never reported as a contract finding.
#
# `--self-test` proves both of those, hermetically, against fixture trees.

set -euo pipefail

FBL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FBL_SELF_PATH="$FBL_SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FBL_REPO_ROOT="${FBL_REPO_ROOT:-$(cd "$FBL_SCRIPT_DIR/.." && pwd)}"

# --- Frozen contract -------------------------------------------------------
# Owner: 09-08. Attested in 09-08-SUMMARY.md.
#
# WARNING/ERROR: the SwiftLint thresholds the rule must keep. A config that
# relaxes either is how "the rule is enabled" becomes true and meaningless.
FBL_FROZEN_WARNING=60
FBL_FROZEN_ERROR=120
# BASELINE_CEILING: accepted pre-existing `function_body_length` warnings in
# scripts/swiftlint-warning-baseline.json. 09-08 landed 60. It may shrink.
FBL_BASELINE_CEILING=60
# EXCEPTION_CEILING: narrow local `swiftlint:disable` directives for this rule.
# 09-08 landed 7, all of them bodies over the 120-line error threshold that are
# exhaustive mapping tables or composition-root wiring.
FBL_EXCEPTION_CEILING=7

# Reusable chart assets. 09-08 deleted exactly one proven-unreachable host
# (HealthLog/Screens/Charts/ChartDetailScreen.swift); everything reusable that
# lived beside it stays, and a later "cleanup" may not take these with it.
FBL_REUSABLE_ASSETS=(
    "HealthLog/Screens/Charts/ChartDetailComponents.swift"
    "HealthLog/Screens/Charts/ChartDetailDrillDownRow.swift"
    "HealthLog/Screens/Charts/ChartDetailHeroTrend.swift"
    "HealthLog/Screens/Charts/ChartDetailSourcesRow.swift"
    "HealthLog/Screens/Charts/ChartsAccessibility.swift"
    "HealthLog/Screens/Charts/FullscreenChartCover.swift"
    "HealthLog/Screens/Charts/HLTileMetricChart.swift"
    "HealthLog/Screens/Charts/InsufficientDataCard.swift"
    "HealthLog/Screens/Charts/MetricChartContent.swift"
    "HealthLog/Screens/Charts/MetricChartMath.swift"
    "HealthLog/Screens/Charts/SelectedPointCallout.swift"
    "HealthLog/Screens/Charts/TrendsOverlayCard.swift"
    "HealthLog/Stores/ChartDetailStore.swift"
    "HealthLog/Stores/ChartDetailStore+Loading.swift"
)

fbl_toolfail() {
    printf 'verify-function-body-baseline: TOOLFAIL: %s\n' "$1" >&2
    exit 2
}

fbl_finding() {
    printf 'verify-function-body-baseline: FINDING: %s\n' "$1" >&2
    exit 1
}

# --- Clauses ---------------------------------------------------------------

fbl_check_rule_is_enabled() {
    local config="$1"
    local disabled
    disabled="$(
        /usr/bin/awk '
            /^disabled_rules:[[:space:]]*$/ { inside = 1; next }
            inside && /^[^[:space:]#]/ { inside = 0 }
            inside && /^[[:space:]]*-[[:space:]]*function_body_length([[:space:]]|#|$)/ { found = 1 }
            END { print found + 0 }
        ' "$config"
    )"
    [[ "$disabled" == "0" ]] ||
        fbl_finding "function_body_length is globally disabled in .swiftlint.yml"
}

fbl_check_thresholds() {
    local config="$1"
    local parsed
    parsed="$(
        /usr/bin/awk '
            /^function_body_length:[[:space:]]*$/ { inside = 1; next }
            inside && /^[^[:space:]#]/ { inside = 0 }
            inside && /^[[:space:]]*warning:[[:space:]]*[0-9]+[[:space:]]*$/ { gsub(/[^0-9]/, "", $0); w = $0 }
            inside && /^[[:space:]]*error:[[:space:]]*[0-9]+[[:space:]]*$/ { gsub(/[^0-9]/, "", $0); e = $0 }
            END { printf "%s %s\n", (w == "" ? "none" : w), (e == "" ? "none" : e) }
        ' "$config"
    )"
    local warning="${parsed% *}"
    local error="${parsed#* }"
    [[ "$warning" != "none" && "$error" != "none" ]] ||
        fbl_finding "function_body_length has no explicit warning/error thresholds in .swiftlint.yml"
    if ((warning > FBL_FROZEN_WARNING || error > FBL_FROZEN_ERROR)); then
        fbl_finding "function_body_length thresholds are weaker than the frozen floor (${warning}/${error} > ${FBL_FROZEN_WARNING}/${FBL_FROZEN_ERROR})"
    fi
}

fbl_check_baseline_did_not_grow() {
    local baseline="$1"
    local count
    count="$(
        /usr/bin/ruby -rjson -e '
          begin
            doc = JSON.parse(File.read(ARGV[0]))
          rescue StandardError => error
            warn(error.message)
            exit(3)
          end
          warnings = doc["warnings"]
          unless warnings.is_a?(Array)
            warn("baseline has no warnings array")
            exit(3)
          end
          puts(warnings.count { |entry| entry["rule_id"] == "function_body_length" })
        ' "$baseline"
    )" || fbl_toolfail "could not read the SwiftLint warning baseline: $baseline"
    if ((count > FBL_BASELINE_CEILING)); then
        fbl_finding "function_body_length baseline grew: $count accepted warning(s) exceed the frozen ceiling of $FBL_BASELINE_CEILING"
    fi
    printf 'verify-function-body-baseline: %d/%d accepted function_body_length warning(s)\n' \
        "$count" "$FBL_BASELINE_CEILING"
}

# Every narrow local disable must carry its reason and its owner on the line
# directly above it. An unattributed `swiftlint:disable` is indistinguishable
# from the global disable this whole script replaced — it is just smaller.
fbl_check_exceptions_are_attested() {
    local root="$1"
    local report
    report="$(
        cd "$root" && /usr/bin/ruby -e '
          form =/\A\/\/\s*function_body_length exception \(owner: \d{2}-\d{2}\): \S.{19,}\z/
          directive = /swiftlint:disable(?::(?:next|this|previous))?[^\n]*\bfunction_body_length\b/
          scoped = /swiftlint:disable:(?:next|this|previous)\b/
          reopen = /swiftlint:enable[^\n]*\bfunction_body_length\b/
          unattested = []
          unclosed = []
          total = 0
          Dir.glob("**/*.swift").reject { |path| path.split("/").any? { |part| part.start_with?(".") } }.sort.each do |path|
            lines = File.readlines(path, chomp: true)
            open_at = nil
            lines.each_with_index do |line, i|
              if open_at && line =~ reopen
                open_at = nil
                next
              end
              next unless line =~ directive
              total += 1
              previous = i.zero? ? "" : lines[i - 1].strip
              unattested << "#{path}:#{i + 1}" unless previous =~ form
              # A region disable that is never re-enabled is a file-wide
              # suppression wearing a local disguise — the exact shape this
              # contract replaced, one file at a time instead of all at once.
              open_at = i + 1 unless line =~ scoped
            end
            unclosed << "#{path}:#{open_at}" if open_at
          end
          puts(total)
          puts(unattested.join(", "))
          puts(unclosed.join(", "))
        '
    )" || fbl_toolfail "could not scan Swift sources for function_body_length exceptions"

    local total unattested unclosed
    total="$(printf '%s\n' "$report" | /usr/bin/sed -n '1p')"
    unattested="$(printf '%s\n' "$report" | /usr/bin/sed -n '2p')"
    unclosed="$(printf '%s\n' "$report" | /usr/bin/sed -n '3p')"
    [[ "$total" =~ ^[0-9]+$ ]] || fbl_toolfail "exception scan produced no count"

    if [[ -n "$unattested" ]]; then
        fbl_finding "function_body_length exception lacks an adjacent rationale and owner: $unattested"
    fi
    if [[ -n "$unclosed" ]]; then
        fbl_finding "function_body_length region disable is never re-enabled: $unclosed"
    fi
    if ((total > FBL_EXCEPTION_CEILING)); then
        fbl_finding "function_body_length exceptions grew: $total exceed the frozen ceiling of $FBL_EXCEPTION_CEILING"
    fi
    printf 'verify-function-body-baseline: %d/%d attested function_body_length exception(s)\n' \
        "$total" "$FBL_EXCEPTION_CEILING"
}

fbl_check_reusable_assets_survive() {
    local root="$1"
    local missing=()
    local asset
    for asset in "${FBL_REUSABLE_ASSETS[@]}"; do
        [[ -f "$root/$asset" ]] || missing+=("$asset")
    done
    if ((${#missing[@]} > 0)); then
        fbl_finding "reusable chart asset missing: ${missing[*]}"
    fi
}

fbl_verify() {
    local root="$1"
    local config="$root/.swiftlint.yml"
    local baseline="$root/scripts/swiftlint-warning-baseline.json"
    command -v /usr/bin/ruby >/dev/null 2>&1 || fbl_toolfail "ruby is unavailable"
    [[ -d "$root" ]] || fbl_toolfail "repository root does not exist: $root"
    [[ -f "$config" ]] || fbl_toolfail ".swiftlint.yml is missing: $config"
    [[ -f "$baseline" ]] || fbl_toolfail "SwiftLint warning baseline is missing: $baseline"

    fbl_check_rule_is_enabled "$config"
    fbl_check_thresholds "$config"
    fbl_check_baseline_did_not_grow "$baseline"
    fbl_check_exceptions_are_attested "$root"
    fbl_check_reusable_assets_survive "$root"
    printf 'verify-function-body-baseline: PASS\n'
}

# --- Self-test -------------------------------------------------------------

fbl_self_fail() {
    printf 'verify-function-body-baseline: self-test FAIL: %s\n' "$1" >&2
    exit 2
}

# Runs this script against a fixture root and asserts the exact outcome.
# `expected_status` and `expected_message` are both checked: a clause that
# fails for the right reason and a clause that fails for any reason are not
# the same evidence.
fbl_expect() {
    local label="$1" root="$2" expected_status="$3" expected_message="$4"
    local output status
    set +e
    output="$(FBL_REPO_ROOT="$root" "$FBL_SELF_PATH" 2>&1)"
    status=$?
    set -e
    [[ "$status" -eq "$expected_status" ]] ||
        fbl_self_fail "$label: expected exit $expected_status, got $status — $output"
    if [[ -n "$expected_message" ]] && ! printf '%s' "$output" | grep -Fq "$expected_message"; then
        fbl_self_fail "$label: expected message '$expected_message', got — $output"
    fi
    printf '%s' "$output"
}

fbl_make_fixture() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/HealthLog/Screens/Charts" "$root/HealthLog/Stores" "$root/Sources"
    local asset
    for asset in "${FBL_REUSABLE_ASSETS[@]}"; do
        mkdir -p "$root/$(dirname "$asset")"
        printf '// fixture\n' >"$root/$asset"
    done
    cat >"$root/.swiftlint.yml" <<'EOF'
disabled_rules:
  - todo
  - function_parameter_count
function_body_length:
  warning: 60
  error: 120
EOF
    /usr/bin/ruby -rjson -e '
      ceiling = Integer(ARGV[1])
      warnings = (1..ceiling).map do |i|
        { "file" => "Sources/F#{i}.swift", "line" => i, "character" => 1,
          "rule_id" => "function_body_length", "reason" => "fixture", "severity" => "warning" }
      end
      warnings << { "file" => "Sources/Other.swift", "line" => 1, "character" => 1,
                    "rule_id" => "line_length", "reason" => "fixture", "severity" => "warning" }
      File.write(ARGV[0], JSON.pretty_generate({ "schema" => 1, "warnings" => warnings }))
    ' "$root/scripts/swiftlint-warning-baseline.json" "$FBL_BASELINE_CEILING"
    local i
    for ((i = 1; i <= FBL_EXCEPTION_CEILING; i++)); do
        cat >"$root/Sources/Exception$i.swift" <<EOF
// function_body_length exception (owner: 09-08): fixture rationale number $i, long enough to be a sentence.
// swiftlint:disable:next function_body_length
func fixture$i() {}
EOF
    done
}

fbl_self_test() {
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/healthlog-fbl-self-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT

    local clean="$work/clean"
    fbl_make_fixture "$clean"
    fbl_expect "clean fixture" "$clean" 0 "verify-function-body-baseline: PASS" >/dev/null

    # The named global-disable finding.
    local disabled="$work/disabled"
    cp -R "$clean" "$disabled"
    /usr/bin/ruby -e '
      path = ARGV[0]
      File.write(path, File.read(path).sub(/^  - todo$/, "  - todo\n  - function_body_length        # pragmatic for now"))
    ' "$disabled/.swiftlint.yml"
    fbl_expect "global disable" "$disabled" 1 \
        "FINDING: function_body_length is globally disabled in .swiftlint.yml" >/dev/null

    # …which must be distinguishable from the checker simply not running. A
    # missing config is TOOLFAIL, and must NOT report the global-disable
    # finding — otherwise a broken checkout would read as an audited pass or as
    # a violation that nobody committed.
    local broken="$work/broken"
    cp -R "$clean" "$broken"
    rm -f "$broken/.swiftlint.yml"
    local broken_output
    broken_output="$(fbl_expect "missing config" "$broken" 2 "TOOLFAIL: .swiftlint.yml is missing")"
    if printf '%s' "$broken_output" | grep -Fq "globally disabled"; then
        fbl_self_fail "tool failure was reported as the global-disable finding"
    fi
    if printf '%s' "$broken_output" | grep -Fq "FINDING:"; then
        fbl_self_fail "tool failure was reported as a contract finding"
    fi

    local malformed="$work/malformed"
    cp -R "$clean" "$malformed"
    printf 'not json' >"$malformed/scripts/swiftlint-warning-baseline.json"
    fbl_expect "malformed baseline" "$malformed" 2 "TOOLFAIL: could not read the SwiftLint warning baseline" >/dev/null

    local weakened="$work/weakened"
    cp -R "$clean" "$weakened"
    /usr/bin/ruby -e '
      path = ARGV[0]
      File.write(path, File.read(path).sub(/^  warning: 60$/, "  warning: 200"))
    ' "$weakened/.swiftlint.yml"
    fbl_expect "weakened threshold" "$weakened" 1 "FINDING: function_body_length thresholds are weaker" >/dev/null

    local grown="$work/grown"
    cp -R "$clean" "$grown"
    /usr/bin/ruby -rjson -e '
      doc = JSON.parse(File.read(ARGV[0]))
      doc["warnings"] << { "file" => "Sources/Extra.swift", "line" => 1, "character" => 1,
                           "rule_id" => "function_body_length", "reason" => "new debt", "severity" => "warning" }
      File.write(ARGV[0], JSON.pretty_generate(doc))
    ' "$grown/scripts/swiftlint-warning-baseline.json"
    fbl_expect "baseline growth" "$grown" 1 "FINDING: function_body_length baseline grew" >/dev/null

    local unattested="$work/unattested"
    cp -R "$clean" "$unattested"
    printf '// swiftlint:disable:next function_body_length\nfunc sneaky() {}\n' \
        >"$unattested/Sources/Sneaky.swift"
    fbl_expect "unattested exception" "$unattested" 1 \
        "FINDING: function_body_length exception lacks an adjacent rationale and owner" >/dev/null

    # An attested-but-extra exception is still growth.
    local extra="$work/extra"
    cp -R "$clean" "$extra"
    cat >"$extra/Sources/Extra.swift" <<'EOF'
// function_body_length exception (owner: 09-08): attested, but one more than the frozen ceiling allows.
// swiftlint:disable:next function_body_length
func extra() {}
EOF
    fbl_expect "exception growth" "$extra" 1 "FINDING: function_body_length exceptions grew" >/dev/null

    # A region disable that never re-enables is a file-wide suppression.
    local leaking="$work/leaking"
    cp -R "$clean" "$leaking"
    cat >"$leaking/Sources/Leaking.swift" <<'EOF'
// function_body_length exception (owner: 09-08): attested, but the region is never closed again.
// swiftlint:disable function_body_length
func leaking() {}
EOF
    fbl_expect "unclosed region" "$leaking" 1 \
        "FINDING: function_body_length region disable is never re-enabled" >/dev/null

    # …and the same file with its matching enable is accepted.
    local closed="$work/closed"
    cp -R "$clean" "$closed"
    rm -f "$closed/Sources/Exception7.swift"
    cat >"$closed/Sources/Exception7.swift" <<'EOF'
// function_body_length exception (owner: 09-08): attested region, closed again immediately after.
// swiftlint:disable function_body_length
func closedRegion() {}
// swiftlint:enable function_body_length
EOF
    fbl_expect "closed region" "$closed" 0 "verify-function-body-baseline: PASS" >/dev/null

    local stripped="$work/stripped"
    cp -R "$clean" "$stripped"
    rm -f "$stripped/HealthLog/Screens/Charts/MetricChartMath.swift"
    fbl_expect "reusable asset removed" "$stripped" 1 \
        "FINDING: reusable chart asset missing: HealthLog/Screens/Charts/MetricChartMath.swift" >/dev/null

    printf 'verify-function-body-baseline: self-test PASS (11 fixtures)\n'
}

# --- Entry point -----------------------------------------------------------

case "${1:-}" in
    --self-test)
        [[ $# -eq 1 ]] || fbl_toolfail "usage: verify-function-body-baseline.sh [--self-test]"
        fbl_self_test
        ;;
    "")
        fbl_verify "$FBL_REPO_ROOT"
        ;;
    *)
        fbl_toolfail "usage: verify-function-body-baseline.sh [--self-test]"
        ;;
esac
