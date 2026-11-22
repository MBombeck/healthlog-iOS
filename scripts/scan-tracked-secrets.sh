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

# One perl process for every file (one per file took 40 s on ~10,000 files).
# It prints the name of each file that carries a retired fingerprint and
# exits 2 on a file it cannot read.
fingerprint_hits="$(mktemp "${TMPDIR:-/tmp}/healthlog-tracked-secret-hits.XXXXXX")" || {
    echo "Tracked-secret scan failed: could not create the hit list." >&2
    exit "$EXIT_SCANNER_FAILURE"
}
trap 'rm -f "$tracked_candidates" "$fingerprint_hits"' EXIT
fingerprint_status=0
perl -MDigest::SHA=sha256_hex -e '
    open(my $list, "<", shift @ARGV) or exit 2;
    my %retired = map { $_ => 1 } @ARGV;
    local $/ = "\0";
    while (my $name = <$list>) {
        chomp $name;
        open(my $file, "<", $name) or do { print STDERR "$name\n"; exit 2 };
        local $/ = "\n";
        FILE: while (<$file>) {
            while (/([A-Za-z0-9][A-Za-z0-9._%+@:-]{5,})/g) {
                if ($retired{sha256_hex($1)}) { print "$name\n"; last FILE }
            }
        }
        close $file;
    }
    exit 0;
' "$tracked_candidates" "${retired_reviewer_fingerprints[@]}" >"$fingerprint_hits" || fingerprint_status=$?
if (( fingerprint_status != 0 )); then
    echo "Tracked-secret scan failed while inspecting the tracked files." >&2
    exit "$EXIT_SCANNER_FAILURE"
fi
while IFS= read -r hit; do
    echo "Potential tracked reviewer secret: $hit" >&2
    matches=1
done < "$fingerprint_hits"

review_notes=".planning/audit-release/APP-REVIEW-NOTES.md"
if [[ -f "$review_notes" ]] && git ls-files --error-unmatch -- "$review_notes" >/dev/null 2>&1; then
    placeholder_status=0
    perl -ne '
        if (/(?:password|kennwort|account identifier|reviewer (?:account|email)|username|benutzername)\s*:/i
            && !/<ASC_REVIEW_[A-Z0-9_]+>/) {
            exit 1;
        }
    ' "$review_notes" || placeholder_status=$?
    if (( placeholder_status > 1 )); then
        echo "Tracked-secret scan failed while inspecting: $review_notes" >&2
        exit "$EXIT_SCANNER_FAILURE"
    fi
    if (( placeholder_status == 1 )); then
        echo "Potential tracked reviewer secret: $review_notes" >&2
        matches=1
    fi
fi

if (( matches != 0 )); then
    exit "$EXIT_MATCH"
fi

exit 0
