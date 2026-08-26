#!/usr/bin/env bash

set -uo pipefail

readonly EXIT_MATCH=1
readonly EXIT_SCANNER_FAILURE=2

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Tracked-secret scan failed: not inside a Git worktree." >&2
    exit "$EXIT_SCANNER_FAILURE"
}
cd "$repo_root" || {
    echo "Tracked-secret scan failed: repository root is unavailable." >&2
    exit "$EXIT_SCANNER_FAILURE"
}

tracked_candidates="$(mktemp "${TMPDIR:-/tmp}/healthlog-tracked-secrets.XXXXXX")" || {
    echo "Tracked-secret scan failed: could not create the file inventory." >&2
    exit "$EXIT_SCANNER_FAILURE"
}
trap 'rm -f "$tracked_candidates"' EXIT

if ! git ls-files -z -- '*.md' '*.swift' > "$tracked_candidates"; then
    echo "Tracked-secret scan failed: Git could not enumerate tracked Markdown and Swift." >&2
    exit "$EXIT_SCANNER_FAILURE"
fi

# SHA-256 fingerprints are deliberately irreversible. Never add a plaintext
# reviewer credential here. The current entry identifies the retired password
# that was removed from the review packet in plan 03-02.
readonly retired_reviewer_fingerprints=(
    "cb56c1e5c6e8ce08178745f1a1f0503459cdd46a97fb89faa6ec23f158d3e2d0"
)

matches=0
while IFS= read -r -d '' markdown_file; do
    fingerprint_status=0
    perl -MDigest::SHA=sha256_hex -e '
        my %retired = map { $_ => 1 } @ARGV;
        while (<STDIN>) {
            while (/([A-Za-z0-9][A-Za-z0-9._%+@:-]{5,})/g) {
                exit 1 if $retired{sha256_hex($1)};
            }
        }
        exit 0;
    ' "${retired_reviewer_fingerprints[@]}" < "$markdown_file" || fingerprint_status=$?

    if (( fingerprint_status > 1 )); then
        echo "Tracked-secret scan failed while inspecting: $markdown_file" >&2
        exit "$EXIT_SCANNER_FAILURE"
    fi

    placeholder_status=0
    if [[ "$markdown_file" == ".planning/audit-release/APP-REVIEW-NOTES.md" ]]; then
        perl -ne '
            if (/(?:password|kennwort|account identifier|reviewer (?:account|email)|username|benutzername)\s*:/i
                && !/<ASC_REVIEW_[A-Z0-9_]+>/) {
                exit 1;
            }
        ' "$markdown_file" || placeholder_status=$?
        if (( placeholder_status > 1 )); then
            echo "Tracked-secret scan failed while inspecting: $markdown_file" >&2
            exit "$EXIT_SCANNER_FAILURE"
        fi
    fi

    if (( fingerprint_status == 1 || placeholder_status == 1 )); then
        echo "Potential tracked reviewer secret: $markdown_file" >&2
        matches=1
    fi
done < "$tracked_candidates"

if (( matches != 0 )); then
    exit "$EXIT_MATCH"
fi

exit 0
