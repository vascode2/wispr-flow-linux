#!/usr/bin/env bash
#===============================================================================
# linux-status-notification-size.sh -- grow the Linux Status window while a
# status notification is shown, in the main bundle (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# linux-status-compact.sh shrinks the Status window to 200x110 on Linux. The
# window also hosts status notification cards (MeetingStartedByMistake and
# friends have window:"status"), and a standard card is 400x154, so the card
# is clipped: only the middle of its text and half of its buttons are visible.
# Before #67 the window was 512x614 and the card fit.
#
# THE ANCHOR
# ----------
# The shim only needs the two developer strings main already sends to the
# Status renderer -- "notification:show" and "notification:clear" -- and the
# window's constructor title "Flow Status Indicator", each present exactly
# once in the pristine bundle. It is injected right after the webpack license
# banner (the same slot the other main-bundle shims use) and attaches to the
# Status window on browser-window-created.
#
# THE PATCH
# ---------
# While a notification is shown the window grows to at least 400x160 (or
# 800x420 for splash cards), anchored bottom-centre. On notification:clear it
# returns to the bounds it had when the notification appeared. The compact
# pill and the window's input handling are untouched.
#
# Verified against the pristine 1.6.1209 bundle.
#
# Usage: linux-status-notification-size.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_STATUS_NOTIFICATION_SIZE" "${1:-}"

SHIM="$PATCH_LIB_DIR/linux-status-notification-size.js"

if ! python3 - "$BUNDLE" "$MARKER" "$SHIM" <<'PY'
import io, re, sys

path, marker, shim_path = sys.argv[1], sys.argv[2], sys.argv[3]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    src = f.read()
with io.open(shim_path, "r", encoding="utf-8") as f:
    shim = f.read()

if not shim.startswith("/*" + marker + "*/"):
    sys.exit(f"ERROR: {shim_path} must open with the {marker} marker.")
if not shim.endswith("\n"):
    shim += "\n"

Q = r'[`"\']'
contract = {
    "Status notification show channel": Q + "notification:show" + Q,
    "Status notification clear channel": Q + "notification:clear" + Q,
    "Status window title": "title:" + Q + "Flow Status Indicator" + Q,
    "Status surface report channel": Q + "status:reportAlphaCatchRects" + Q,
}
for label, pattern in contract.items():
    count = len(re.findall(pattern, src))
    # The idle-unmap shim already carries the report channel string, so after
    # it runs this channel is expected at least once, not exactly once.
    if label == "Status surface report channel":
        if count < 1:
            sys.exit(f"ERROR: upstream contract changed: {label} found 0 times.")
    elif count != 1:
        sys.exit(f"ERROR: upstream contract changed: {label} found {count} times, expected 1.")

first, nl, rest = src.partition("\n")
if first.startswith("/*!") and first.rstrip().endswith("*/") and nl:
    src = first + "\n" + shim + rest
    where = "after the license banner"
else:
    src = shim + src
    where = "at the top of the bundle"

if src.count(marker) != 1:
    sys.exit("ERROR: expected the marker exactly once after injection.")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(src)
print(f"Patched: status notification-size shim injected {where}.")
PY
then
	patch_restore
	exit 1
fi

patch_verify_marker
patch_finish "Status notifications grow the window in $BUNDLE"
