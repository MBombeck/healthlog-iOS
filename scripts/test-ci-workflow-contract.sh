#!/usr/bin/env bash

# Structural regression test for release-critical GitHub Actions gates.
#
# The test parses the workflow as YAML rather than relying only on text search,
# then mutates a temporary copy to prove that stale Xcode and raw SwiftLint
# strict invocations are rejected by the contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_PATH="${1:-$REPO_ROOT/.github/workflows/ci.yml}"

fail() {
    printf 'ci-workflow-contract: FAIL: %s\n' "$1" >&2
    exit 1
}

check_workflow() {
    local workflow_path="$1"
    ruby -ryaml -e '
      workflow_path = ARGV.fetch(0)
      workflow = YAML.safe_load(File.read(workflow_path), aliases: false)
      steps = workflow.fetch("jobs").fetch("build-test").fetch("steps")

      xcode_steps = steps.select { |step| step["uses"] == "maxim-lobanov/setup-xcode@v1" }
      abort("expected exactly one setup-xcode step") unless xcode_steps.length == 1
      xcode_version = xcode_steps.first.fetch("with").fetch("xcode-version").to_s
      abort("expected Xcode 26.6, found #{xcode_version.inspect}") unless xcode_version == "26.6"

      lint_step = steps.find { |step| step["name"] == "Lint" }
      abort("Lint step is missing") unless lint_step
      lint_lines = lint_step.fetch("run").lines.map(&:strip).reject do |line|
        line.empty? || line.start_with?("#")
      end

      required_commands = [
        "swiftformat --lint .",
        "bash scripts/lint-strict-baseline.sh --self-test",
        "bash scripts/lint-strict-baseline.sh",
        "python3 scripts/i18n-guard.py HealthLog",
        "scripts/check-strings.sh"
      ]
      required_commands.each do |command|
        count = lint_lines.count(command)
        abort("expected exactly one #{command.inspect}, found #{count}") unless count == 1
      end

      self_test_index = lint_lines.index("bash scripts/lint-strict-baseline.sh --self-test")
      live_gate_index = lint_lines.index("bash scripts/lint-strict-baseline.sh")
      abort("baseline self-test must run before the live baseline gate") unless self_test_index < live_gate_index

      run_source = steps.map { |step| step["run"] }.compact.join("\n")
      contract_invocations = run_source.lines.map(&:strip).count("scripts/test-ci-workflow-contract.sh")
      abort("expected exactly one CI contract self-check, found #{contract_invocations}") unless contract_invocations == 1
      if run_source.match?(/^\s*swiftlint\s+lint\b[^\n]*--strict\b/)
        abort("raw swiftlint lint --strict bypasses the audited warning baseline")
      end

      # 09-15 — the SPM step is the module-purity gate. Invoked raw it was red
      # from a617af3f onwards with nothing noticing, and the manifest error
      # aborted before a file was compiled, so the claim it exists to enforce
      # had never been checked. A raw `swift build` here is a bypass in exactly
      # the same sense as a raw `swiftlint lint --strict` above: it reads only
      # an exit code, and it cannot see an `Invalid Source` warning or a build
      # that compiled nothing.
      run_lines = run_source.lines.map(&:strip).reject do |line|
        line.empty? || line.start_with?("#")
      end
      spm_self_test = run_lines.count("bash scripts/verify-spm-core-build.sh --self-test")
      spm_gate = run_lines.count("bash scripts/verify-spm-core-build.sh")
      abort("expected exactly one SPM core-build self-test, found #{spm_self_test}") unless spm_self_test == 1
      abort("expected exactly one SPM core-build gate, found #{spm_gate}") unless spm_gate == 1
      spm_self_test_index = run_lines.index("bash scripts/verify-spm-core-build.sh --self-test")
      spm_gate_index = run_lines.index("bash scripts/verify-spm-core-build.sh")
      abort("SPM self-test must run before the live SPM gate") unless spm_self_test_index < spm_gate_index
      raw_spm = run_lines.count { |line| line.match?(/\Aswift\s+build\b/) }
      abort("raw swift build bypasses the SPM core-build gate") unless raw_spm.zero?
    ' "$workflow_path"
}

[[ $# -le 1 ]] || fail "usage: test-ci-workflow-contract.sh [workflow-path]"
[[ -f "$WORKFLOW_PATH" ]] || fail "workflow is missing: $WORKFLOW_PATH"

check_workflow "$WORKFLOW_PATH"

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/healthlog-ci-contract.XXXXXX")"
# Expand the local path now; it no longer exists when the EXIT trap runs.
# shellcheck disable=SC2064
trap "rm -rf '$fixture_dir'" EXIT

awk '{ sub(/xcode-version: "26\.6"/, "xcode-version: \"26.5\""); print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/stale-xcode.yml"
if check_workflow "$fixture_dir/stale-xcode.yml" >/dev/null 2>&1; then
    fail "contract accepted stale Xcode 26.5"
fi

awk '
  { print }
  !changed && /bash scripts\/lint-strict-baseline\.sh$/ {
    sub(/bash scripts\/lint-strict-baseline\.sh$/, "swiftlint lint --strict")
    print
    changed = 1
  }
' "$WORKFLOW_PATH" >"$fixture_dir/raw-strict.yml"
if check_workflow "$fixture_dir/raw-strict.yml" >/dev/null 2>&1; then
    fail "contract accepted raw swiftlint lint --strict"
fi

# 09-15 — the regression this file now also guards: the SPM step going back to
# a bare `swift build`, whose exit code is the only thing it can report and
# which was red for months with nobody reading it.
awk '{ sub(/bash scripts\/verify-spm-core-build\.sh$/, "swift build"); print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/raw-spm.yml"
if check_workflow "$fixture_dir/raw-spm.yml" >/dev/null 2>&1; then
    fail "contract accepted a raw swift build in place of the SPM core-build gate"
fi

awk '{ if ($0 !~ /bash scripts\/verify-spm-core-build\.sh --self-test$/) print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/no-spm-self-test.yml"
if check_workflow "$fixture_dir/no-spm-self-test.yml" >/dev/null 2>&1; then
    fail "contract accepted an SPM gate with no self-test in front of it"
fi

printf 'ci-workflow-contract: PASS\n'
