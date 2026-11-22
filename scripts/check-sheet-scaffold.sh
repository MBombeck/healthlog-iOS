#!/usr/bin/env bash

# Sheet scaffold check (C0 design foundation, section 5.2).
#
# Every `struct ...Sheet...: View` under HealthLog/Screens (pattern B4) either
# calls HLSheetScaffold( in its body or an extension of it, or is listed with a
# reason in scripts/check-sheet-scaffold-exceptions.json. Lists the open types
# per package. The number of open types is held by design-ratchet.sh, so the
# default run fails only on an invalid exception list; --strict also fails on
# open types and stale exceptions (the follow-up after C1 to C4).
#
# Exit: 0 holds, 1 finding, 2 usage or setup.

set -euo pipefail
exec python3 -B "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/design-ratchet.py" sheets "$@"
