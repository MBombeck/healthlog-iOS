#!/usr/bin/env bash

# Fail-closed SwiftLint ratchet for release builds.
#
# Every error fails. Warnings pass only when their complete machine-readable
# fingerprint is present exactly once in the checked baseline. A removed or
# moved warning makes the baseline stale and also fails, forcing the baseline
# to shrink with the code instead of silently accumulating debt.
#
# `--refresh` rewrites the baseline from the current tree. It stays fail-closed:
# a single error-severity violation refuses the rewrite, so a refresh can never
# launder an error into the accepted set. The refresh prints the exact new and
# stale fingerprints it is about to record; the owning plan attests them in its
# phase documentation, which is where a reviewer checks the drift.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_PATH="${SWIFTLINT_BASELINE_PATH:-$SCRIPT_DIR/swiftlint-warning-baseline.json}"
SWIFTLINT_BIN="${SWIFTLINT_BIN:-swiftlint}"

fail() {
    printf 'lint-strict-baseline: FAIL: %s\n' "$1" >&2
    exit 1
}

run_lint() {
    local output_path="$1"
    (
        cd "$REPO_ROOT"
        "$SWIFTLINT_BIN" lint --reporter json --quiet >"$output_path"
    )
}

# The version of the tool that produced the findings being compared. It is read
# from `$SWIFTLINT_BIN`, not from a hard-coded `swiftlint`, so the self-test's
# mock reports the mock's version instead of the machine's real one.
lint_tool_version() {
    "$SWIFTLINT_BIN" version 2>/dev/null | tr -d '\n'
}

refresh_baseline() {
    local output_path="$1"
    ruby -rjson -rdigest -e '
      baseline_path, output_path, repo_root, config_path, tool_version = ARGV
      findings = JSON.parse(File.read(output_path))
      canonical = ->(entry) { [entry["file"], entry["line"], entry["character"], entry["rule_id"], entry["reason"]] }
      normalized = findings.map do |entry|
        file = File.expand_path(entry.fetch("file"))
        prefix = File.expand_path(repo_root) + File::SEPARATOR
        abort("SwiftLint reported a file outside the repository") unless file.start_with?(prefix)
        {
          "file" => file.delete_prefix(prefix),
          "line" => entry.fetch("line"),
          "character" => entry.fetch("character"),
          "rule_id" => entry.fetch("rule_id"),
          "reason" => entry.fetch("reason"),
          "severity" => entry.fetch("severity").downcase
        }
      end

      # Fail-closed: a refresh may never launder an error into the baseline.
      errors = normalized.select { |entry| entry["severity"] == "error" }
      unless errors.empty?
        errors.each { |entry| warn("ERROR #{entry["file"]}:#{entry["line"]}:#{entry["character"]} [#{entry["rule_id"]}]") }
        abort("refusing to refresh: SwiftLint emitted #{errors.length} error(s)")
      end

      warnings = normalized.select { |entry| entry["severity"] == "warning" }
      keys = warnings.map(&canonical)
      abort("SwiftLint emitted duplicate warning records") unless keys.uniq.length == keys.length

      previous = File.file?(baseline_path) ? JSON.parse(File.read(baseline_path)).fetch("warnings", []) : []
      previous_keys = previous.map(&canonical)
      (keys - previous_keys).each { |k| warn("RECORD-NEW #{k[0]}:#{k[1]}:#{k[2]} [#{k[3]}]") }
      (previous_keys - keys).each { |k| warn("DROP-STALE #{k[0]}:#{k[1]}:#{k[2]} [#{k[3]}]") }

      refreshed = {
        "schema" => 1,
        "swiftlint_version" => tool_version,
        "config_sha256" => Digest::SHA256.hexdigest(File.read(config_path)),
        "warnings" => warnings.sort_by(&canonical)
      }
      File.write(baseline_path, JSON.pretty_generate(refreshed) + "\n")
      puts("lint-strict-baseline: REFRESHED (#{warnings.length} warning(s) recorded, 0 errors)")
    ' "$BASELINE_PATH" "$output_path" "$REPO_ROOT" "$REPO_ROOT/.swiftlint.yml" "$(lint_tool_version)"
}

compare_results() {
    local output_path="$1"
    ruby -rjson -rdigest -e '
      baseline_path, output_path, repo_root, config_path, tool_version = ARGV
      abort("baseline missing: #{baseline_path}") unless File.file?(baseline_path)
      baseline = JSON.parse(File.read(baseline_path))
      abort("unsupported baseline schema") unless baseline["schema"] == 1
      expected_config = Digest::SHA256.file(config_path).hexdigest
      abort("baseline config_sha256 is stale") unless baseline["config_sha256"] == expected_config

      # A tool-version drift changes the finding set on its own. Without this
      # clause the diff arrives as NEW and STALE fingerprints and reads as new
      # debt or a stale ratchet — a wrong cause, reported confidently. Name it
      # instead, so the refresh that follows is attested as a version bump.
      abort("baseline swiftlint_version is stale: recorded #{baseline["swiftlint_version"].inspect}, tool reports #{tool_version.inspect}") unless baseline["swiftlint_version"] == tool_version

      keys = %w[file line character rule_id reason]
      canonical = lambda do |entry|
        keys.map { |key| entry.fetch(key) }
      end
      warnings = baseline.fetch("warnings")
      abort("baseline contains a non-warning entry") unless warnings.all? { |entry| entry["severity"] == "warning" }
      warning_keys = warnings.map(&canonical)
      abort("baseline contains duplicate entries") unless warning_keys.uniq.length == warning_keys.length

      findings = JSON.parse(File.read(output_path))
      normalized = findings.map do |entry|
        file = File.expand_path(entry.fetch("file"))
        prefix = File.expand_path(repo_root) + File::SEPARATOR
        abort("SwiftLint reported a file outside the repository") unless file.start_with?(prefix)
        {
          "file" => file.delete_prefix(prefix),
          "line" => entry.fetch("line"),
          "character" => entry.fetch("character"),
          "rule_id" => entry.fetch("rule_id"),
          "reason" => entry.fetch("reason"),
          "severity" => entry.fetch("severity").downcase
        }
      end
      errors = normalized.select { |entry| entry["severity"] == "error" }
      unless errors.empty?
        errors.each { |entry| warn("ERROR #{entry["file"]}:#{entry["line"]}:#{entry["character"]} [#{entry["rule_id"]}]") }
        abort("SwiftLint emitted #{errors.length} error(s)")
      end

      actual_warnings = normalized.select { |entry| entry["severity"] == "warning" }
      actual_keys = actual_warnings.map(&canonical)
      abort("SwiftLint emitted duplicate warning records") unless actual_keys.uniq.length == actual_keys.length

      unexpected = actual_keys - warning_keys
      stale = warning_keys - actual_keys
      unexpected.each { |entry| warn("NEW #{entry[0]}:#{entry[1]}:#{entry[2]} [#{entry[3]}]") }
      stale.each { |entry| warn("STALE #{entry[0]}:#{entry[1]}:#{entry[2]} [#{entry[3]}]") }
      abort("warning baseline mismatch: #{unexpected.length} new, #{stale.length} stale") unless unexpected.empty? && stale.empty?
      puts("lint-strict-baseline: PASS (#{actual_warnings.length} checked warning(s), 0 errors)")
    ' "$BASELINE_PATH" "$output_path" "$REPO_ROOT" "$REPO_ROOT/.swiftlint.yml" "$(lint_tool_version)"
}

self_test() {
    local fixture_dir
    fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/healthlog-lint-self-test.XXXXXX")"
    # Expand the local path now; it no longer exists when the EXIT trap runs.
    # shellcheck disable=SC2064
    trap "rm -rf '$fixture_dir'" EXIT

    mkdir -p "$fixture_dir/repo" "$fixture_dir/bin"
    cp "$REPO_ROOT/.swiftlint.yml" "$fixture_dir/repo/.swiftlint.yml"
    touch "$fixture_dir/repo/Foo.swift"
    local config_hash
    config_hash="$(shasum -a 256 "$fixture_dir/repo/.swiftlint.yml" | awk '{print $1}')"
    cat >"$fixture_dir/baseline.json" <<EOF
{"schema":1,"swiftlint_version":"0.0.0-mock","config_sha256":"$config_hash","warnings":[{"file":"Foo.swift","line":1,"character":1,"rule_id":"fixture_warning","reason":"fixture","severity":"warning"}]}
EOF
    cat >"$fixture_dir/bin/swiftlint" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" ]]; then
    printf '%s\n' "${MOCK_SWIFTLINT_VERSION:-0.0.0-mock}"
    exit 0
fi
printf '%s\n' "${MOCK_SWIFTLINT_JSON:?}"
EOF
    chmod +x "$fixture_dir/bin/swiftlint"

    local saved_root="$REPO_ROOT"
    local saved_baseline="$BASELINE_PATH"
    local saved_bin="$SWIFTLINT_BIN"
    REPO_ROOT="$fixture_dir/repo"
    BASELINE_PATH="$fixture_dir/baseline.json"
    SWIFTLINT_BIN="$fixture_dir/bin/swiftlint"
    local output="$fixture_dir/output.json"
    local file="$fixture_dir/repo/Foo.swift"

    MOCK_SWIFTLINT_JSON="[{\"file\":\"$file\",\"line\":1,\"character\":1,\"rule_id\":\"fixture_warning\",\"reason\":\"fixture\",\"severity\":\"Warning\"}]" run_lint "$output"
    compare_results "$output" >/dev/null

    MOCK_SWIFTLINT_JSON="[{\"file\":\"$file\",\"line\":2,\"character\":1,\"rule_id\":\"new_warning\",\"reason\":\"new\",\"severity\":\"Warning\"}]" run_lint "$output"
    if compare_results "$output" >/dev/null 2>&1; then
        fail "self-test accepted a new warning"
    fi

    MOCK_SWIFTLINT_JSON="[{\"file\":\"$file\",\"line\":1,\"character\":1,\"rule_id\":\"fixture_error\",\"reason\":\"error\",\"severity\":\"Error\"}]" run_lint "$output"
    if compare_results "$output" >/dev/null 2>&1; then
        fail "self-test accepted an error"
    fi

    # A refresh may never launder an error into the accepted set.
    if refresh_baseline "$output" >/dev/null 2>&1; then
        fail "self-test refreshed the baseline while an error was present"
    fi
    if ! grep -q '"rule_id":"fixture_warning"' "$BASELINE_PATH"; then
        fail "self-test refused refresh but still rewrote the baseline"
    fi

    # A refresh records a moved warning and drops the stale fingerprint.
    MOCK_SWIFTLINT_JSON="[{\"file\":\"$file\",\"line\":9,\"character\":1,\"rule_id\":\"fixture_warning\",\"reason\":\"fixture\",\"severity\":\"Warning\"}]" run_lint "$output"
    refresh_baseline "$output" >/dev/null
    compare_results "$output" >/dev/null

    ruby -rjson -e 'p=JSON.parse(File.read(ARGV[0])); p["warnings"] << p["warnings"].first; File.write(ARGV[0], JSON.generate(p))' "$BASELINE_PATH"
    MOCK_SWIFTLINT_JSON="[{\"file\":\"$file\",\"line\":1,\"character\":1,\"rule_id\":\"fixture_warning\",\"reason\":\"fixture\",\"severity\":\"Warning\"}]" run_lint "$output"
    if compare_results "$output" >/dev/null 2>&1; then
        fail "self-test accepted a duplicate baseline entry"
    fi

    # A tool-version drift is named as a version drift, not as new debt.
    MOCK_SWIFTLINT_JSON="[{\"file\":\"$file\",\"line\":9,\"character\":1,\"rule_id\":\"fixture_warning\",\"reason\":\"fixture\",\"severity\":\"Warning\"}]" run_lint "$output"
    refresh_baseline "$output" >/dev/null
    compare_results "$output" >/dev/null
    local drift
    drift="$(MOCK_SWIFTLINT_VERSION="9.9.9-mock" compare_results "$output" 2>&1 || true)"
    if ! printf '%s' "$drift" | grep -Fq "baseline swiftlint_version is stale"; then
        fail "self-test accepted a SwiftLint version drift: $drift"
    fi
    if printf '%s' "$drift" | grep -Fq "warning baseline mismatch"; then
        fail "self-test reported a version drift as baseline debt"
    fi

    REPO_ROOT="$saved_root"
    BASELINE_PATH="$saved_baseline"
    SWIFTLINT_BIN="$saved_bin"
    printf 'lint-strict-baseline: self-test PASS\n'
}

if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
fi
MODE="check"
if [[ "${1:-}" == "--refresh" ]]; then
    MODE="refresh"
    shift
fi
if [[ $# -ne 0 ]]; then
    fail "usage: lint-strict-baseline.sh [--self-test | --refresh]"
fi
command -v "$SWIFTLINT_BIN" >/dev/null 2>&1 || fail "SwiftLint executable not found: $SWIFTLINT_BIN"
[[ -f "$REPO_ROOT/.swiftlint.yml" ]] || fail ".swiftlint.yml is missing"

output_path="$(mktemp "${TMPDIR:-/tmp}/healthlog-swiftlint.XXXXXX.json")"
trap 'rm -f "$output_path"' EXIT
run_lint "$output_path"
if [[ "$MODE" == "refresh" ]]; then
    refresh_baseline "$output_path"
else
    compare_results "$output_path"
fi
