#!/usr/bin/env bash

# Design ratchet per package (C0 design foundation, section 5.2).
#
# Counts the C0 SwiftLint patterns R1 to R18 (read from .swiftlint.yml), the
# sheet types without HLSheetScaffold and the destructive roles outside the
# delete ladder, per package C1 to C4, and compares them with
# scripts/design-ratchets/C<n>.json. The lint baseline only says "no new
# warning"; these files show each package's progress as a number. The E3
# action-form rules are held per file in scripts/design-ratchets/E3.json.
#
#   scripts/design-ratchet.sh            a higher count fails and writes
#                                        nothing; lower counts rewrite the
#                                        package's file, to be committed
#   scripts/design-ratchet.sh --check    compare only and never write; a lower
#                                        count fails as stale (stage test,
#                                        release gates, CI)
#   ... --base <commit>                  also: no count and no stage 3 limit
#                                        may exceed the files at that commit,
#                                        so a hand-raised file fails
#   scripts/design-ratchet.sh --init     create the files that are missing
#                                        (C1 to C4, E3); --force-init
#                                        rewrites them
#                                        (C0 and the follow-up only)
#
# Exit: 0 holds, 1 grew, stale or invalid exception list, 2 usage or setup.

set -euo pipefail
exec python3 -B "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/design-ratchet.py" ratchet "$@"
