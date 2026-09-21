#!/usr/bin/env bash
#===============================================================================
# patch-context-menu-passthrough-on-click.sh -- bring the Context Menu window
# up to the same self-healing click-through guarantee already shipped for the
# Status window (status-window-force-passthrough-on-click.sh), and cover
# scroll-wheel input too.
#
# BUG THIS FIXES
# ----------------------------------------------------------------------------
# The Context Menu window shares the exact same alpha-poll click-through
# mechanism as the Status window, but its `before-mouse-event` listener never
# got the safety net:
#
#   o.webContents.on("before-mouse-event",(e,t)=>{
#     if("mouseDown"===t.type){
#       const e=o.getBounds();
#       a().warn(`[ContextMenuWindow] Mouse input received - ...`)
#     }
#   })
#
# It only logs mouseDown -- never mouseWheel -- and even for a logged
# mouseDown it takes NO corrective action, unlike the Status window's
# listener. If this window's alpha poll lands on a stale/wrong answer after
# a monitor-topology change (dock unplug, KVM switch -- same trigger already
# confirmed live for the Status window), it can swallow input indefinitely.
# This window is also the bigger risk in practice: observed live geometry is
# 2559x1079 (sized for a prior multi-monitor layout), which after undocking
# to a single 1920x1080 panel covers nearly the entire visible screen
# (x:0-1920, y:345-1080) whenever it is mapped -- a far larger dead zone than
# the Status window's fixed 440x320 rect.
#
# THE PATCH (surgical, idempotent, .orig backup, verified)
# ----------------------------------------------------------------------------
# Mirror the Status window's fix exactly: widen the filter to mouseDown OR
# mouseWheel, and force click-through right after the (now dual-purpose)
# diagnostic log, regardless of why the poll got the wrong answer:
#
#   if("mouseDown"===t.type){
#     const e=o.getBounds();
#     a().warn(`[ContextMenuWindow] Mouse input received - type: ${t.type}, bounds: ${JSON.stringify(e)}, visible: ${o.isVisible()}`)
#   }
#     becomes
#   if("mouseDown"===t.type||"mouseWheel"===t.type){
#     const e=o.getBounds();
#     a().warn(`[ContextMenuWindow] Mouse input received - type: ${t.type}, bounds: ${JSON.stringify(e)}, visible: ${o.isVisible()}`)
#     ,o.isDestroyed()||o.setIgnoreMouseEvents(!0,{forward:!0})
#   }
#
# A marker comment WISPR_CONTEXTMENU_FORCE_PASSTHROUGH is left in the bundle
# so verify-patches.sh can statically confirm the patch shipped.
#
# WHY THIS CANNOT REGRESS NORMAL OPERATION
# ----------------------------------------
# - Only fires on mouseDown/mouseWheel events the window ALREADY received
#   (before-mouse-event is a pure observer; it cannot affect the in-flight
#   event, only the next one).
# - `o.isDestroyed()||...` guards against calling into a destroyed window,
#   same guard style as the Status window patch.
# - Worst case for legitimate menu interaction: the window may briefly accept
#   the same pixel as click-through for <=400ms after a real click/scroll on
#   it, bounded by the next alpha poll tick -- identical tradeoff already
#   shipped and accepted for the Status window.
#
# Usage: patch-context-menu-passthrough-on-click.sh <path-to-.webpack/main/index.js>
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

MARKER = 'WISPR_CONTEXTMENU_FORCE_PASSTHROUGH'
if MARKER in src:
    print("Already patched (marker present). Nothing to do.")
    sys.exit(0)

# Anchor: the full ContextMenuWindow before-mouse-event listener body, through
# the start of the next statement (o.setMaxListeners(15)). Verified unique
# (exactly one occurrence) against the pristine 1.6.7 bundle.
ANCHOR = ('o.webContents.on("before-mouse-event",(e,t)=>{if("mouseDown"===t.type){'
           'const e=o.getBounds();a().warn(`[ContextMenuWindow] Mouse input received '
           '- type: ${t.type}, bounds: ${JSON.stringify(e)}, visible: ${o.isVisible()}`)'
           '}}),o.setMaxListeners(15)')
count = src.count(ANCHOR)
if count != 1:
    print(f"ERROR: expected exactly 1 occurrence of the ContextMenuWindow "
          f"before-mouse-event anchor, found {count}. Bundle layout changed -- "
          f"refusing to guess.", file=sys.stderr)
    sys.exit(1)

replacement = (
    'o.webContents.on("before-mouse-event",(e,t)=>{'
    f'/*{MARKER}*/if("mouseDown"===t.type||"mouseWheel"===t.type){{'
    'const e=o.getBounds();a().warn(`[ContextMenuWindow] Mouse input received '
    '- type: ${t.type}, bounds: ${JSON.stringify(e)}, visible: ${o.isVisible()}`)'
    ',o.isDestroyed()||o.setIgnoreMouseEvents(!0,{forward:!0})'
    '}}),o.setMaxListeners(15)'
)
patched = src.replace(ANCHOR, replacement, 1)

if MARKER not in patched:
    print("ERROR: verification failed -- marker not present after replace. Aborting.",
          file=sys.stderr)
    sys.exit(1)

shutil.copyfile(path, path + ".ctxmenupass.orig")
print("Backup written:", path + ".ctxmenupass.orig")
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(patched)
print("OK: Context Menu window can no longer swallow input indefinitely (marker: %s)." % MARKER)
PY

if command -v node >/dev/null; then
  node --check "$BUNDLE" && echo "node --check OK"
fi
echo "Done: Context Menu window now self-heals clicks and scroll, same as Status window."
