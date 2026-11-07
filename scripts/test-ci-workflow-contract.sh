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
      job = workflow.fetch("jobs").fetch("build-test")

      # 1.5 CI-FORK — two runner paths. Fork pull requests run on GitHub-hosted
      # macos-26, everything else on the Mac mini; one condition decides both
      # runs-on and HEALTHLOG_RUNNER, so the hosted-only steps cannot drift
      # from the runner choice.
      fork_condition = "github.event_name == '"'"'pull_request'"'"' && github.event.pull_request.head.repo.full_name != github.repository"
      runs_on = job.fetch("runs-on").to_s
      expected_runs_on = "${{ (#{fork_condition}) && '"'"'macos-26'"'"' || fromJSON('"'"'[\"self-hosted\", \"macOS\", \"healthlog-mini\"]'"'"') }}"
      abort("runs-on must pick macos-26 for forks and the Mac mini otherwise, found #{runs_on.inspect}") unless runs_on == expected_runs_on
      expected_runner_env = "${{ (#{fork_condition}) && '"'"'hosted'"'"' || '"'"'mini'"'"' }}"
      runner_env = job.fetch("env", {}).fetch("HEALTHLOG_RUNNER", nil).to_s
      abort("HEALTHLOG_RUNNER must use the runs-on fork condition, found #{runner_env.inspect}") unless runner_env == expected_runner_env

      hosted_if = "env.HEALTHLOG_RUNNER == '"'"'hosted'"'"'"
      {
        "Select Xcode (hosted runner)" => ['"'"'app="/Applications/Xcode_27.2.app"'"'"', '"'"'sudo xcode-select -s "$app/Contents/Developer"'"'"', "exit 1"],
        "Install pinned tooling (hosted runner)" => [
          "XcodeGen/releases/download/2.46.0/xcodegen.zip 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
          "SwiftFormat/releases/download/0.63.0/swiftformat.zip 28c7802e11fa5ae113d903066439c6bb1be20a8ac1ad9709c42616a7e273fb0f",
          "SwiftLint/releases/download/0.65.1/portable_swiftlint.zip c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0",
          "shasum -a 256 -c -"
        ],
        "Provide Metal toolchain (hosted runner)" => ["xcodebuild -downloadComponent MetalToolchain"]
      }.each do |name, needles|
        found = job.fetch("steps").select { |step| step["name"] == name }
        abort("expected exactly one #{name} step") unless found.length == 1
        abort("#{name} must run only on the hosted runner") unless found.first["if"] == hosted_if
        needles.each { |needle| abort("#{name} lacks #{needle.inspect}") unless found.first.fetch("run").include?(needle) }
      end
      # The verify steps check both runners; they must stay unconditional.
      ["Verify Xcode", "Verify Tooling"].each do |name|
        step = job.fetch("steps").find { |s| s["name"] == name }
        abort("#{name} must run on every runner") if step.nil? || step.key?("if")
      end

      steps = workflow.fetch("jobs").fetch("build-test").fetch("steps")

      # 2026-09-08 — CI runs on the self-hosted Mac mini; the Xcode pin is a
      # verification step against the selected Xcode of the machine, not a
      # setup-xcode download. The pinned literal must read 27.2.
      xcode_steps = steps.select { |step| step["name"] == "Verify Xcode" }
      abort("expected exactly one Verify Xcode step") unless xcode_steps.length == 1
      xcode_version = xcode_steps.first.fetch("run")[/expected="Xcode ([0-9.]+)"/, 1].to_s
      abort("expected Xcode 27.2, found #{xcode_version.inspect}") unless xcode_version == "27.2"

      lint_step = steps.find { |step| step["name"] == "Lint" }
      abort("Lint step is missing") unless lint_step
      lint_lines = lint_step.fetch("run").lines.map(&:strip).reject do |line|
        line.empty? || line.start_with?("#")
      end

      required_commands = [
        "swiftformat --lint .",
        "bash scripts/lint-strict-baseline.sh --self-test",
        "bash scripts/lint-strict-baseline.sh",
        "python3 scripts/i18n-guard.py --self-test",
        "python3 scripts/i18n-guard.py HealthLog",
        "scripts/check-strings.sh",
        "python3 scripts/check-visible-punctuation.py --self-test",
        "python3 scripts/check-visible-punctuation.py",
        "bash scripts/test-xcstrings-add.sh",
        "python3 scripts/l10n/merge-xcstrings.py --self-test",
        "python3 scripts/l10n/check-catalog-format.py --self-test",
        "python3 scripts/l10n/fill-placeholders.py --self-test",
        "python3 scripts/l10n/signoff-medical.py --self-test",
        "python3 scripts/l10n/check-catalog-format.py"
      ]
      required_commands.each do |command|
        count = lint_lines.count(command)
        abort("expected exactly one #{command.inspect}, found #{count}") unless count == 1
      end

      punct_self_test_index = lint_lines.index("python3 scripts/check-visible-punctuation.py --self-test")
      punct_gate_index = lint_lines.index("python3 scripts/check-visible-punctuation.py")
      abort("punctuation self-test must run before the live punctuation gate") unless punct_self_test_index < punct_gate_index

      # 1.5 Z1 — every catalog-workbench self-test runs before the live
      # catalog format gate.
      catalog_gate_index = lint_lines.index("python3 scripts/l10n/check-catalog-format.py")
      [
        "bash scripts/test-xcstrings-add.sh",
        "python3 scripts/l10n/merge-xcstrings.py --self-test",
        "python3 scripts/l10n/check-catalog-format.py --self-test",
        "python3 scripts/l10n/fill-placeholders.py --self-test",
        "python3 scripts/l10n/signoff-medical.py --self-test"
      ].each do |command|
        abort("#{command} must run before the live catalog format gate") unless lint_lines.index(command) < catalog_gate_index
      end

      i18n_self_test_index = lint_lines.index("python3 scripts/i18n-guard.py --self-test")
      abort("i18n-guard self-test must run before the live i18n gate") unless i18n_self_test_index < lint_lines.index("python3 scripts/i18n-guard.py HealthLog")

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

      # 1.5 MATRIX — the iOS-18 launch guard (public #2). The symbol check runs
      # on the Release binary, which this step builds through the serialized
      # gate first; self-test before the live check; never runner-conditional.
      symbol_name = "Release links (no strong iOS 26 symbols)"
      symbol_steps = steps.select { |step| step["name"] == symbol_name }
      abort("expected exactly one #{symbol_name} step") unless symbol_steps.length == 1
      symbol_step = symbol_steps.first
      abort("#{symbol_name} must run on every runner") if symbol_step.key?("if")
      symbol_lines = symbol_step.fetch("run").lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
      symbol_self_test = "bash scripts/verify-no-strong-ios26-symbols.sh --self-test"
      release_build = "scripts/run-serialized-xcode-gate.sh \"ci-${{ github.run_id }}\" -- build -configuration Release -skipMacroValidation CODE_SIGN_IDENTITY=-"
      symbol_gate = "bash scripts/verify-no-strong-ios26-symbols.sh \"/tmp/dd-hl-ci-${{ github.run_id }}/Build/Products/Release-iphonesimulator/HealthLog.app/HealthLog\""
      [symbol_self_test, release_build, symbol_gate].each do |command|
        count = run_lines.count(command)
        abort("expected exactly one #{command.inspect}, found #{count}") unless count == 1
        abort("#{command.inspect} must sit in the #{symbol_name} step") unless symbol_lines.include?(command)
      end
      abort("symbol self-test must run before the Release build") unless symbol_lines.index(symbol_self_test) < symbol_lines.index(release_build)
      abort("the symbol check must read the Release build it follows") unless symbol_lines.index(release_build) < symbol_lines.index(symbol_gate)
      free_index = steps.index { |step| step["name"] == "Free the gate caches" }
      abort("the symbol check must run before the gate caches are freed") unless free_index.nil? || steps.index(symbol_step) < free_index
    ' "$workflow_path"
}

[[ $# -le 1 ]] || fail "usage: test-ci-workflow-contract.sh [workflow-path]"
[[ -f "$WORKFLOW_PATH" ]] || fail "workflow is missing: $WORKFLOW_PATH"

check_workflow "$WORKFLOW_PATH"

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/healthlog-ci-contract.XXXXXX")"
# Expand the local path now; it no longer exists when the EXIT trap runs.
# shellcheck disable=SC2064
trap "rm -rf '$fixture_dir'" EXIT

awk '{ sub(/expected="Xcode 27\.2"/, "expected=\"Xcode 26.6\""); print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/stale-xcode.yml"
if check_workflow "$fixture_dir/stale-xcode.yml" >/dev/null 2>&1; then
    fail "contract accepted stale Xcode 26.6"
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

# U5 (1.1.1) — the visible-punctuation gate must stay in the Lint step.
awk '{ if ($0 !~ /python3 scripts\/check-visible-punctuation\.py$/) print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/no-punctuation-gate.yml"
if check_workflow "$fixture_dir/no-punctuation-gate.yml" >/dev/null 2>&1; then
    fail "contract accepted a Lint step without the visible-punctuation gate"
fi

# 1.5 Z1 — the catalog format gate and its self-test must stay in the Lint step,
# in that order.
awk '{ if ($0 !~ /python3 scripts\/l10n\/check-catalog-format\.py$/) print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/no-catalog-gate.yml"
if check_workflow "$fixture_dir/no-catalog-gate.yml" >/dev/null 2>&1; then
    fail "contract accepted a Lint step without the catalog format gate"
fi

awk '{ if ($0 !~ /python3 scripts\/l10n\/merge-xcstrings\.py --self-test$/) print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/no-merge-self-test.yml"
if check_workflow "$fixture_dir/no-merge-self-test.yml" >/dev/null 2>&1; then
    fail "contract accepted a Lint step without the merge driver self-test"
fi

# 1.5 L10N-FINAL — the medical sign-off self-test stays in the Lint step.
awk '{ if ($0 !~ /python3 scripts\/l10n\/signoff-medical\.py --self-test$/) print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/no-signoff-self-test.yml"
if check_workflow "$fixture_dir/no-signoff-self-test.yml" >/dev/null 2>&1; then
    fail "contract accepted a Lint step without the medical sign-off self-test"
fi

awk '
  /python3 scripts\/l10n\/check-catalog-format\.py --self-test$/ { held = $0; next }
  { print }
  held != "" && /python3 scripts\/l10n\/check-catalog-format\.py$/ { print held; held = "" }
' "$WORKFLOW_PATH" >"$fixture_dir/catalog-self-test-late.yml"
if check_workflow "$fixture_dir/catalog-self-test-late.yml" >/dev/null 2>&1; then
    fail "contract accepted the catalog format self-test after the live gate"
fi

# 1.5 CI-FORK — both runner paths. A fork landing on the Mac mini, everything
# landing on the hosted runner, an unpinned tool download and a hosted path
# without the Xcode selection must all be rejected.
awk '{ if ($0 ~ /^    runs-on: /) print "    runs-on: [self-hosted, macOS, healthlog-mini]"; else print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/forks-on-mini.yml"
if check_workflow "$fixture_dir/forks-on-mini.yml" >/dev/null 2>&1; then
    fail "contract accepted fork pull requests on the self-hosted runner"
fi

awk '{ if ($0 ~ /^    runs-on: /) print "    runs-on: macos-26"; else print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/all-hosted.yml"
if check_workflow "$fixture_dir/all-hosted.yml" >/dev/null 2>&1; then
    fail "contract accepted own branches on the hosted runner"
fi

awk '{ if ($0 ~ /^      HEALTHLOG_RUNNER: /) print "      HEALTHLOG_RUNNER: hosted"; else print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/runner-env-drift.yml"
if check_workflow "$fixture_dir/runner-env-drift.yml" >/dev/null 2>&1; then
    fail "contract accepted HEALTHLOG_RUNNER drifting from the runs-on condition"
fi

awk '{ sub(/c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0/, ""); print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/unpinned-swiftlint.yml"
if check_workflow "$fixture_dir/unpinned-swiftlint.yml" >/dev/null 2>&1; then
    fail "contract accepted a hosted swiftlint download without its checksum"
fi

awk '{ if ($0 !~ /sudo xcode-select -s/) print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/no-xcode-select.yml"
if check_workflow "$fixture_dir/no-xcode-select.yml" >/dev/null 2>&1; then
    fail "contract accepted a hosted path that never selects Xcode 27.2"
fi

# 1.5 MATRIX — the Release symbol check: dropped, without its self-test, on a
# Debug build, or limited to one runner must all be rejected.
awk '{ if ($0 !~ /bash scripts\/verify-no-strong-ios26-symbols\.sh "\/tmp/) print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/no-symbol-gate.yml"
if check_workflow "$fixture_dir/no-symbol-gate.yml" >/dev/null 2>&1; then
    fail "contract accepted a workflow without the Release symbol check"
fi

awk '{ if ($0 !~ /bash scripts\/verify-no-strong-ios26-symbols\.sh --self-test$/) print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/no-symbol-self-test.yml"
if check_workflow "$fixture_dir/no-symbol-self-test.yml" >/dev/null 2>&1; then
    fail "contract accepted the symbol check without its self-test"
fi

awk '{ if ($0 ~ /-- build -configuration Release /) sub(/-configuration Release/, "-configuration Debug"); print }' \
    "$WORKFLOW_PATH" >"$fixture_dir/symbol-on-debug.yml"
if check_workflow "$fixture_dir/symbol-on-debug.yml" >/dev/null 2>&1; then
    fail "contract accepted the symbol check without a Release build"
fi

awk '
  { print }
  /- name: Release links \(no strong iOS 26 symbols\)$/ { print "        if: env.HEALTHLOG_RUNNER != '"'"'hosted'"'"'" }
' "$WORKFLOW_PATH" >"$fixture_dir/symbol-mini-only.yml"
if check_workflow "$fixture_dir/symbol-mini-only.yml" >/dev/null 2>&1; then
    fail "contract accepted the symbol check on one runner only"
fi

printf 'ci-workflow-contract: PASS\n'
