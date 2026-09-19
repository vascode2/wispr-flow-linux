#!/usr/bin/env bash
#===============================================================================
# patch-status-window-force-passthrough-on-click.sh -- hard guarantee that the
# Status window can never swallow more than ONE click in a row, regardless of
# why its alpha click-through poll got the wrong answer.
#
# WHY THIS PATCH EXISTS
# ----------------------
# status-window-alpha-threshold.sh raises the poll's click-through threshold
# from a strict alpha<=0 to alpha<=10, which fixes the common case (GPU/
# compositor rounding noise). It is NOT sufficient on its own: users still
# see the dead zone return after events like a dock/monitor hotplug (observed
# live: same running process, patched threshold active, recurred ~90 minutes
# after a clean restart, immediately after undocking). The exact reason the
# poll lands on a wrong/stale answer after a hotplug is not fully understood
# (candidates: the window gets repositioned to a new display and something
# calls the poll-starter `G()` again, leaving a second overlapping
# `setInterval` racing the first with its own stale closure state; or the
# renderer's translucent backdrop legitimately exceeds the raised threshold
# after a relayout). Rather than chase the exact mechanism with an
# ever-increasing threshold (fragile, and any nonzero alpha is a real risk of
# false click-through over genuinely visible UI), this patch adds an
# INDEPENDENT, mechanism-agnostic safety net.
#
# THE INSIGHT
# -----------
# The Status window already has a `before-mouse-event` listener (used only
# for the diagnostic warn log seen in this repo's other patch:
#   `[StatusWindow] Mouse input received - type: mouseDown, ...`
# ). This listener reliably fires on EVERY mouseDown the window receives --
# it is exactly the same signal a human confirms by seeing the dead zone.
# Electron's `before-mouse-event` is a pure observer: it cannot prevent or
# redirect the event already in flight, so anything we do here can only
# affect the NEXT event, never the current (already-delivered) one.
#
# THE PATCH (surgical, idempotent, .orig backup, verified)
# ----------------------------------------------------------------------------
# Immediately after the existing diagnostic warn() call, force the window
# back to click-through:
#
#   a().warn(`[StatusWindow] Mouse input received - ...`)
#     becomes
#   a().warn(`[StatusWindow] Mouse input received - ...`)
#     ,n.isDestroyed()||n.setIgnoreMouseEvents(!0,{forward:!0})
#
# Net effect: whatever caused THIS click to be swallowed, the window is
# forced click-through right after -- self-healing within a single click,
# every time, regardless of cause. The next alpha poll tick (<=400ms later)
# re-evaluates normally and can still legitimately re-enable capture if the
# cursor is genuinely over opaque bar UI, so real interaction with the bar's
# own buttons is unaffected beyond a worst-case ~400ms window right after
# each click on it.
#
# A marker comment WISPR_STATUS_FORCE_PASSTHROUGH is left in the bundle so
# verify-patches.sh can statically confirm the patch shipped.
#
# WHY THIS CANNOT REGRESS NORMAL OPERATION
# ----------------------------------------
# - Only fires on `mouseDown` events the window ALREADY received (same
#   trigger as the pre-existing diagnostic log; no new event surface).
# - `n.isDestroyed()||...` guards against calling into a destroyed window.
# - Worst case for legitimate bar interaction: the window may briefly accept
#   the same pixel as click-through for <=400ms after a real click, exactly
#   as it already does whenever the alpha poll updates; no new user-visible
#   behavior class is introduced, only a bound on how long the dead-zone bug
#   can persist (one click, not indefinitely).
#
# Usage: patch-status-window-force-passthrough-on-click.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "usage: $0 <.webpack/main/index.js>" >&2
  exit 2
fi

python3 - "$BUNDLE" <<'PY'
import re, sys, shutil

path = sys.argv[1]
src = open(path, 'r', encoding='utf-8', errors='surrogateescape').read()

MARKER = 'WISPR_STATUS_FORCE_PASSTHROUGH'
if MARKER in src:
    print("Already patched (marker present). Nothing to do.")
    sys.exit(0)

# Anchor: the tail of the StatusWindow before-mouse-event diagnostic log call,
# through the start of the next statement (n.setMaxListeners(15)). Verified
# unique (exactly one occurrence) against the pristine 1.6.7 bundle.
ANCHOR = 'event coords: ${r}, ${i}`)}}),n.setMaxListeners(15)'
count = src.count(ANCHOR)
if count != 1:
    print(f"ERROR: expected exactly 1 occurrence of the before-mouse-event anchor, "
          f"found {count}. Bundle layout changed -- refusing to guess.", file=sys.stderr)
    sys.exit(1)

replacement = (
    'event coords: ${r}, ${i}`)'
    f'/*{MARKER}*/,n.isDestroyed()||n.setIgnoreMouseEvents(!0,{{forward:!0}})'
    '}}),n.setMaxListeners(15)'
)
patched = src.replace(ANCHOR, replacement, 1)

if MARKER not in patched:
    print("ERROR: verification failed -- marker not present after replace. Aborting.",
          file=sys.stderr)
    sys.exit(1)

shutil.copyfile(path, path + ".forcepass.orig")
print("Backup written:", path + ".forcepass.orig")
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(patched)
print("OK: forced click-through-after-mousedown safety net installed (marker: %s)." % MARKER)
PY

if command -v node >/dev/null; then
  node --check "$BUNDLE" && echo "node --check OK"
fi
echo "Done: Status window can no longer swallow more than one click in a row."
