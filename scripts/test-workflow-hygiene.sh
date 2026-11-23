#!/usr/bin/env bash

# Supply-chain contract for every workflow under .github/workflows.
#
# test-ci-workflow-contract.sh guards what ci.yml runs; this file guards how
# every workflow runs, ci.yml included:
#
#   1. Every remote action is pinned to a full 40-character commit SHA, with
#      the release it stands for in a trailing comment (`# v4.4.0`). A tag can
#      be moved by whoever controls the action's repository; a SHA cannot.
#   2. The workflow sets `permissions:` at the top, read-only. A job that needs
#      to write names exactly that permission itself, and only the jobs listed
#      in WRITE_ALLOWED below may.
#   3. The workflow sets `concurrency:` with a group, so a newer run of the
#      same ref can supersede an older one.
#   4. Every job carries `timeout-minutes`.
#   5. No workflow uses `pull_request_target`, which runs fork code with the
#      base repository's token and secrets.
#   6. A self-hosted runner never meets a fork pull request: a job that can
#      run on `self-hosted` in a workflow with a `pull_request` trigger must
#      route forks elsewhere in its `runs-on` expression (the ci.yml pattern)
#      or exclude pull requests in its `if`.
#
# Usage:
#   scripts/test-workflow-hygiene.sh               # check .github/workflows
#   scripts/test-workflow-hygiene.sh DIR           # check another directory
#   scripts/test-workflow-hygiene.sh --self-test   # prove each rule bites
# Exit: 0 clean, 1 a finding, 2 usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

check_dir() {
    ruby -ryaml -e '
      dir = ARGV.fetch(0)
      # job => permissions it may write. Anything else stays read-only.
      write_allowed = {
        "codeql.yml/analyze-actions" => ["security-events"],
        "codeql.yml/analyze-swift" => ["security-events"],
        "hygiene.yml/dependency-graph" => ["contents"]
      }
      fork_guard = "github.event.pull_request.head.repo.full_name != github.repository"
      findings = []
      files = Dir.glob(File.join(dir, "*.{yml,yaml}")).sort
      findings << "no workflow files in #{dir}" if files.empty?
      files.each do |path|
        name = File.basename(path)
        text = File.read(path)
        workflow = YAML.safe_load(text, aliases: false) || {}
        # Psych reads the bare key `on` as true (YAML 1.1).
        triggers = workflow.key?("on") ? workflow["on"] : workflow[true]
        trigger_names =
          case triggers
          when Hash then triggers.keys.map(&:to_s)
          when Array then triggers.map(&:to_s)
          when String then [triggers]
          else []
          end

        text.each_line.with_index(1) do |line, number|
          next unless line =~ /^\s*(?:-\s+)?uses:\s*([^\s#]+)\s*(#.*)?$/
          ref = Regexp.last_match(1)
          comment = Regexp.last_match(2).to_s
          next if ref.start_with?("./") || ref.start_with?("docker://")
          action, at = ref.split("@", 2)
          unless at.to_s =~ /\A[0-9a-f]{40}\z/
            findings << "#{name}:#{number}: #{action} is not pinned to a commit SHA (#{ref})"
            next
          end
          findings << "#{name}:#{number}: #{action} pin lacks the release comment (# vX.Y.Z)" unless comment =~ /#\s*v?\d+(\.\d+)*/
        end

        findings << "#{name}: pull_request_target runs fork code with the base token" if trigger_names.include?("pull_request_target")

        top = workflow["permissions"]
        if top.nil?
          findings << "#{name}: no top-level permissions"
        elsif top.is_a?(String)
          findings << "#{name}: top-level permissions must be read-only, found #{top}" unless %w[read-all {}].include?(top)
        elsif top.is_a?(Hash)
          top.each { |scope, level| findings << "#{name}: top-level permission #{scope}: #{level} must be read or none" unless %w[read none].include?(level.to_s) }
        end

        concurrency = workflow["concurrency"]
        group = concurrency.is_a?(Hash) ? concurrency["group"] : concurrency
        findings << "#{name}: no concurrency group" if group.to_s.strip.empty?

        (workflow["jobs"] || {}).each do |job_id, job|
          key = "#{name}/#{job_id}"
          findings << "#{key}: no timeout-minutes" unless job.key?("timeout-minutes")
          perms = job["permissions"]
          if perms.is_a?(String)
            findings << "#{key}: job permissions must name each scope, found #{perms}" unless perms == "read-all" || perms == "{}"
          elsif perms.is_a?(Hash)
            perms.each do |scope, level|
              next unless level.to_s == "write"
              allowed = write_allowed.fetch(key, [])
              findings << "#{key}: writes #{scope}, which this contract does not allow it" unless allowed.include?(scope.to_s)
            end
          end
          runs_on = job["runs-on"]
          runs_on_text = runs_on.is_a?(Array) ? runs_on.join(" ") : runs_on.to_s
          next unless runs_on_text.include?("self-hosted")
          next unless trigger_names.include?("pull_request")
          guarded_runs_on = runs_on_text.include?(fork_guard)
          job_if = job["if"].to_s
          guarded_if = job_if.include?("github.event_name != '"'"'pull_request'"'"'") ||
                       job_if.include?(fork_guard) ||
                       (job_if.include?("github.event_name == '"'"'") && !job_if.include?("pull_request"))
          findings << "#{key}: self-hosted runner reachable from a fork pull request" unless guarded_runs_on || guarded_if
        end
      end
      if findings.empty?
        puts "workflow-hygiene: PASS (#{files.length} workflows)"
      else
        findings.each { |finding| warn "workflow-hygiene: FAIL: #{finding}" }
        exit 1
      end
    ' "$1"
}

self_test() {
    local fixture
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/workflow-hygiene.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$fixture'" RETURN
    local good="$fixture/good" failures=0
    mkdir -p "$good"
    cat >"$good/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  build-test:
    runs-on: ${{ (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository) && 'macos-26' || fromJSON('["self-hosted", "macOS"]') }}
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
      - uses: ./local-action
YAML
    check_dir "$good" >/dev/null || { echo "  FAIL the clean fixture was rejected" >&2; failures=$((failures + 1)); }

    mutate() {
        local label="$1" script="$2" dir="$fixture/$3"
        mkdir -p "$dir"
        awk "$script" "$good/ci.yml" >"$dir/ci.yml"
        if check_dir "$dir" >/dev/null 2>&1; then
            echo "  FAIL accepted: $label" >&2
            failures=$((failures + 1))
        else
            echo "  ok   rejects $label"
        fi
    }
    mutate "a tag instead of a SHA" '{ sub(/@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0/, "@v4"); print }' tag
    mutate "a SHA without its release comment" '{ sub(/ # v4\.4\.0/, ""); print }' no-comment
    mutate "missing top-level permissions" '/^permissions:/ { skip = 1; next } skip && /^  contents:/ { skip = 0; next } { print }' no-perms
    mutate "top-level write permissions" '{ sub(/contents: read/, "contents: write"); print }' write-top
    mutate "write-all" '/^permissions:/ { print "permissions: write-all"; skip = 1; next } skip && /^  contents:/ { skip = 0; next } { print }' write-all
    mutate "a missing concurrency group" '/^concurrency:/ { skip = 1; next } skip && /^  / { next } { skip = 0; print }' no-concurrency
    mutate "a job without timeout-minutes" '!/timeout-minutes/ { print }' no-timeout
    mutate "pull_request_target" '{ sub(/^  pull_request:$/, "  pull_request_target:"); print }' prt
    mutate "a self-hosted runner open to fork pull requests" '{ if ($0 ~ /^    runs-on: /) print "    runs-on: [self-hosted, macOS]"; else print }' fork-self-hosted
    mutate "an unlisted job writing contents" '{ print } /^    timeout-minutes:/ { print "    permissions:\n      contents: write" }' job-write

    if [[ $failures -ne 0 ]]; then
        echo "workflow-hygiene self-test: FAIL ($failures)" >&2
        return 1
    fi
    echo "workflow-hygiene self-test: PASS"
}

case "${1:-}" in
    --self-test) [[ $# -eq 1 ]] || exit 2; self_test ;;
    "") check_dir "$REPO_ROOT/.github/workflows" ;;
    *) [[ $# -eq 1 && -d "$1" ]] || { echo "usage: test-workflow-hygiene.sh [DIR|--self-test]" >&2; exit 2; }; check_dir "$1" ;;
esac
