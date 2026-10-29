#!/usr/bin/env bash
#===============================================================================
# linux-notetaker-mic-only.sh -- skip the system-audio capture on Linux, in the
# hub renderer bundle (.webpack/renderer/hub/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# Notetaker's system audio (other participants) is captured with Web Audio in
# the hub renderer on non-Windows platforms. Linux has no equivalent capture,
# so startMeetingSystemCapture fails and the meeting recorder shows
# "Transcription error: Could not capture system audio" while the mic
# transcript continues. The app's own setup gate already calls system audio
# unsupported on Linux ("requires macOS 13 or later").
#
# THE PATCH
# ---------
# Make startMeetingSystemCapture a no-op on Linux. The mic capture is
# untouched; the meeting records and transcribes mic-only.
#
# Usage: linux-notetaker-mic-only.sh <path-to-.webpack/renderer/hub/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_NOTETAKER_MIC_ONLY" "${1:-}"

if ! python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, re, sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    src = f.read()

pattern = r'(static async startMeetingSystemCapture\([\w$]+\)\{)'
matches = list(re.finditer(pattern, src))
if len(matches) != 1:
    sys.exit(f"ERROR: expected one startMeetingSystemCapture, found {len(matches)}")

m = matches[0]
patched = (src[:m.start()] + '/*' + marker + '*/' + m.group(1)
           + 'if("linux"===process.platform)return;' + src[m.end():])
if marker not in patched:
    sys.exit("ERROR: marker missing after replace.")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(patched)
print("Patched: Notetaker system capture disabled on Linux.")
PY
then
	patch_restore
	exit 1
fi

patch_verify_marker
patch_expect_shape -qF 'if("linux"===process.platform)return;' \
	-- 'Linux mic-only guard missing'
patch_finish "Notetaker is mic-only on Linux in $BUNDLE"
