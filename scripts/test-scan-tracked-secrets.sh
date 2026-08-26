#!/usr/bin/env bash

set -euo pipefail

readonly HISTORICAL_REVIEW_REF="8814a768^"
readonly HISTORICAL_REVIEW_NOTES=".planning/audit-release/APP-REVIEW-NOTES.md"
readonly FIXTURE_NAME="retired-reviewer-fixture.swift"

repo_root="$(git rev-parse --show-toplevel)"
scanner="$repo_root/scripts/scan-tracked-secrets.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/healthlog-secret-scan-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/scripts"
cp "$scanner" "$test_root/scripts/scan-tracked-secrets.sh"

# Recover the retired value only inside the isolated fixture. Never print or
# persist it in the source tree: the scanner contract exposes filenames only.
git -C "$repo_root" show "$HISTORICAL_REVIEW_REF:$HISTORICAL_REVIEW_NOTES" |
    perl -ne '
        if (/\*\*Password:\*\*\s+`([^`]+)`/) {
            print $1;
            $found = 1;
            last;
        }
        END { exit 2 unless $found }
    ' > "$test_root/$FIXTURE_NAME"

if [[ ! -s "$test_root/$FIXTURE_NAME" ]]; then
    echo "Secret-scan self-test failed: historical fixture is empty." >&2
    exit 2
fi

git -C "$test_root" init --quiet
git -C "$test_root" add "$FIXTURE_NAME" scripts/scan-tracked-secrets.sh

stdout_file="$test_root/stdout"
stderr_file="$test_root/stderr"
scanner_status=0
(
    cd "$test_root"
    ./scripts/scan-tracked-secrets.sh
) > "$stdout_file" 2> "$stderr_file" || scanner_status=$?

if (( scanner_status != 1 )); then
    echo "Secret-scan self-test failed: expected match exit 1, got $scanner_status." >&2
    exit 1
fi

if [[ -s "$stdout_file" ]]; then
    echo "Secret-scan self-test failed: scanner wrote unexpected stdout." >&2
    exit 1
fi

expected_message="Potential tracked reviewer secret: $FIXTURE_NAME"
actual_message="$(< "$stderr_file")"
if [[ "$actual_message" != "$expected_message" ]]; then
    echo "Secret-scan self-test failed: stderr was not the filename-only contract." >&2
    exit 1
fi

exit 0
