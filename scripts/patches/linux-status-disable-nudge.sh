#!/usr/bin/env bash
#===============================================================================
# linux-status-disable-nudge.sh -- stop the Status renderer drawing its purple
# nudge pulsar, in the renderer bundle (.webpack/renderer/status/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# The Status renderer draws a purple pulsar over the idle bubble when a nudge
# is active (the hotkey reminder or the flow-bar move hint). On Linux the
# nudge state can stay eligible, so the pulsar remains on screen indefinitely.
# This is a personal-preference patch for this build; it removes the pulsar
# and leaves the rest of the status UI alone.
#
# THE ANCHOR
# ----------
# The pulsar is the only element rendered with
#   anchorName:"--status-bubble",size:"small",position:"center"
# (exactly once in 1.6.1209 and 1.6.1264). The call is
#   <flag>&&(0,<jsx>.jsx)(<pulsar>,{anchorName:"--status-bubble",...})
# so replacing the leading flag with !1 makes the call unreachable while
# leaving valid JavaScript.
#
# Usage: linux-status-disable-nudge.sh <path-to-.webpack/renderer/status/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_STATUS_DISABLE_NUDGE" "${1:-}"

if ! python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, re, sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    src = f.read()

pattern = (r'(?P<flag>[\w$]+)&&\(0,(?P<jsx>[\w$]+)\.jsx\)'
           r'\((?P<pulsar>[\w$]+),\{anchorName:"--status-bubble",'
           r'size:"small",position:"center"\}\)')
matches = list(re.finditer(pattern, src))
if len(matches) != 1:
    sys.exit(f"ERROR: expected one status-bubble pulsar, found {len(matches)}")

m = matches[0]
patched = (src[:m.start()] + '/*' + marker + '*/!1&&(0,' + m.group("jsx") + '.jsx)('
           + m.group("pulsar") + ',{anchorName:"--status-bubble",'
           'size:"small",position:"center"})' + src[m.end():])
if marker not in patched:
    sys.exit("ERROR: marker missing after replace.")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(patched)
print("Patched: status nudge pulsar disabled.")
PY
then
	patch_restore
	exit 1
fi

patch_verify_marker
patch_expect_shape -qF '!1&&(0,' -- 'nudge pulsar call was not disabled'
patch_finish "Status nudge pulsar disabled in $BUNDLE"
