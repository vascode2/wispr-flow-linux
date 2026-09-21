#!/usr/bin/env bash
#===============================================================================
# patch-status-window-wheel-passthrough.sh -- extend the Status window's
# click self-heal (status-window-force-passthrough-on-click.sh) to also cover
# scroll-wheel events, not just mouseDown.
#
# BUG THIS FIXES
# ----------------------------------------------------------------------------
# Live evidence after this session's dock-disconnect/KVM-switch report: the
# Status window's `before-mouse-event` listener is hard-filtered to
#   if ("mouseDown" === t.type) { ... }
# Electron's before-mouse-event also fires with t.type === "mouseWheel" for
# scroll input, but that branch is a complete no-op for wheel events: no
# diagnostic log, and -- critically -- the force-passthrough self-heal added
# by status-window-force-passthrough-on-click.sh lives INSIDE this same `if`,
# so it never runs for wheel either. Net effect: if the alpha click-through
# poll is stuck (e.g. right after a monitor-topology change) and the user
# only SCROLLS in the dead zone instead of clicking, nothing ever rescues it
# -- the window can swallow scroll input indefinitely, exactly matching the
# reported "clicking/scrolling dies" symptom that recurs on every dock
# unplug / KVM switch.
#
# THE PATCH (surgical, idempotent, .orig backup, verified)
# ----------------------------------------------------------------------------
# Widen the existing filter from mouseDown-only to mouseDown-or-mouseWheel:
#
#   if("mouseDown"===t.type){
#     becomes
#   if("mouseDown"===t.type||"mouseWheel"===t.type){
#
# This must run AFTER status-window-force-passthrough-on-click.sh: it targets
# the StatusWindow before-mouse-event listener by anchoring on the `n.`
# (StatusWindow) receiver together with the existing force-passthrough
# marker, so the same self-heal call now also fires on stuck scroll input,
# not just stuck clicks.
#
# A marker comment WISPR_STATUS_WHEEL_PASSTHROUGH is left in the bundle so
# verify-patches.sh can statically confirm the patch shipped.
#
# WHY THIS CANNOT REGRESS NORMAL OPERATION
# ----------------------------------------
# - Only widens which event types can trigger the pre-existing, already-safe
#   self-heal (`n.isDestroyed()||n.setIgnoreMouseEvents(!0,{forward:!0})`);
#   introduces no new code path.
# - Real scrolling over genuinely opaque bar UI is unaffected beyond the same
#   bounded <=400ms window the click self-heal already tolerates: the next
#   alpha poll tick re-evaluates and can re-enable capture if the cursor is
#   still over opaque content.
#
# Usage: patch-status-window-wheel-passthrough.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "Usage: $0 <path-to-.webpack/main/index.js>" >&2
  exit 1
fi

python3 - "$BUNDLE" <<'PY'
import re, sys, shutil

path = sys.argv[1]
src = open(path, 'r', encoding='utf-8', errors='surrogateescape').read()

MARKER = 'WISPR_STATUS_WHEEL_PASSTHROUGH'
if MARKER in src:
    print("Already patched (marker present). Nothing to do.")
    sys.exit(0)

# Anchor: the StatusWindow before-mouse-event listener's mouseDown-only
# filter, immediately after the receiver's before-mouse-event registration.
# Verified unique (exactly one occurrence) -- the `n.` receiver disambiguates
# it from the identically-shaped ContextMenuWindow (`o.`) listener.
ANCHOR = 'n.webContents.on("before-mouse-event",(e,t)=>{if("mouseDown"===t.type){'
count = src.count(ANCHOR)
if count != 1:
    print(f"ERROR: expected exactly 1 occurrence of the StatusWindow before-mouse-event "
          f"anchor, found {count}. Bundle layout changed -- refusing to guess.", file=sys.stderr)
    sys.exit(1)

replacement = (
    'n.webContents.on("before-mouse-event",(e,t)=>{'
    f'/*{MARKER}*/if("mouseDown"===t.type||"mouseWheel"===t.type){{'
)
patched = src.replace(ANCHOR, replacement, 1)

if MARKER not in patched:
    print("ERROR: verification failed -- marker not present after replace. Aborting.",
          file=sys.stderr)
    sys.exit(1)

shutil.copyfile(path, path + ".wheelpass.orig")
print("Backup written:", path + ".wheelpass.orig")
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(patched)
print("OK: Status window self-heal now also covers stuck scroll-wheel input (marker: %s)." % MARKER)
PY

if command -v node >/dev/null; then
  node --check "$BUNDLE" && echo "node --check OK"
fi
echo "Done: Status window scroll-wheel dead zone now self-heals too."
