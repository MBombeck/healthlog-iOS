#!/usr/bin/env bash

# Delete ladder check (C0 design foundation, section 5.2).
#
# Every `role: .destructive` under HealthLog/Screens (pattern L2) sits inside
# HLDeleteButton(, HLDeleteMenuItem( or .hlSwipeDelete(, carries the stage 3
# marker on its own line or the line above,
#
#     // hl-delete-ladder: stage-3 <why this has its own confirmation screen>
#
# or is covered by scripts/check-delete-ladder-exceptions.json (path, anchor,
# reason; for red actions that delete nothing). The anchor is a text, such as
# a title key, on a line at most four lines from the one site it names. A
# marker or an exception without a reason fails, and so does an anchor that
# names more than one site. Stage 3 markers are limited per package in the
# ratchet files. The number of open sites is held by design-ratchet.sh;
# --strict also fails on open sites and stale exceptions.
#
# Exit: 0 holds, 1 finding, 2 usage or setup.

set -euo pipefail
exec python3 -B "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/design-ratchet.py" deletes "$@"
