#!/usr/bin/env bash
#===============================================================================
# patch-dead-zone-diagnostic-capture.sh -- add ground-truth pixel-alpha
# capture logging to both overlay windows' swallow handlers.
#
# WHY THIS PATCH EXISTS
# ----------------------------------------------------------------------------
# #77 shipped a mouseDown-or-mouseWheel self-heal for both the Status and
# Context Menu windows, on the theory that whatever causes a swallow, forcing
# click-through right after bounds it to one bad event. A live test after a
# real dock-disconnect falsified that: click AND scroll stayed dead in the
# Status window's rect until the whole process was killed -- the self-heal
# did not hold.
#
# Two things are now confirmed from main.log, but neither is conclusive on
# its own:
#   - `lastAlphaCheck: null` on every swallow ever logged does NOT mean the
#     poll is broken (retracting an earlier claim in this repo's history) --
#     the module-local value it reads is only populated when the periodic
#     alpha poll's cursor-in-bounds branch actually runs and captures
#     successfully, which may legitimately never happen during a quick
#     click/scroll that doesn't dwell in the window.
#   - `capturePage` threw `UnknownVizError` (a Chromium GPU/Viz compositor
#     failure) once, at cold start on this Intel+NVIDIA hybrid box. That
#     failure path forces click-through (safe), but the `h` one-shot log
#     guard means it will never be logged again for the rest of that
#     process's life even if it recurs silently on every tick after a
#     hotplug -- which would starve the poll of ever reaching its success
#     branch, explaining persistent `lastAlphaCheck: null`, but is unproven.
#
# Rather than ship a third guess, this patch captures GROUND TRUTH the next
# time a swallow happens: synchronously re-run the exact same 1x1
# capturePage-at-cursor the periodic poll does, independent of its mutex/
# cached state, and log the raw result (alpha value, or the capture error)
# at the moment of the swallow. This directly answers, next time:
#   - alpha reads high (genuinely opaque) -> the window's rendered content is
#     stuck non-transparent; a rendering/relayout bug, not a poll-logic bug.
#   - alpha reads low/transparent -> something other than the alpha check is
#     forcing capture (a different explicit setIgnoreMouseEvents(false) call
#     elsewhere in the codebase, e.g. drag-overlay/interactive-mode state).
#   - capturePage throws (UnknownVizError or otherwise) -> confirms a GPU/Viz
#     compositor disruption correlated with the hotplug, which is an
#     Electron/Chromium-level problem outside what a JS patch here can fix.
#
# THE PATCH (surgical, idempotent, .orig backup, verified)
# ----------------------------------------------------------------------------
# Appends a fire-and-forget diagnostic capture immediately after the existing
# force-passthrough self-heal call, for both windows. Does not change any
# existing behavior; purely additive logging.
#
# A marker comment WISPR_DEADZONE_DIAGNOSTIC is left in the bundle so
# verify-patches.sh can statically confirm the patch shipped.
#
# WHY THIS CANNOT REGRESS NORMAL OPERATION
# ----------------------------------------
# - Fire-and-forget async IIFE: never blocks or delays the synchronous
#   self-heal call it follows.
# - Wrapped in try/catch; a capture failure only logs, never throws back into
#   the event handler.
# - Adds zero new user-visible behavior -- diagnostic logging only.
#
# Usage: patch-dead-zone-diagnostic-capture.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "Usage: $0 <path-to-.webpack/main/index.js>" >&2
  exit 1
fi

python3 - "$BUNDLE" <<'PY'
import sys, shutil

path = sys.argv[1]
src = open(path, 'r', encoding='utf-8', errors='surrogateescape').read()

MARKER = 'WISPR_DEADZONE_DIAGNOSTIC'
if MARKER in src:
    print("Already patched (marker present). Nothing to do.")
    sys.exit(0)

def diag_snippet(win_var, tag):
    # Fire-and-forget: re-capture the 1x1 pixel under the current cursor for
    # THIS window right now, independent of the periodic poll's own mutex/
    # cache, and log the raw result.
    return (
        f'/*{MARKER}*/(async()=>{{try{{'
        f'const _b={win_var}.getBounds(),_c=require("electron").screen.getCursorScreenPoint(),'
        f'_img=await {win_var}.webContents.capturePage({{x:_c.x-_b.x,y:_c.y-_b.y,width:1,height:1}}),'
        f'_px=_img.toBitmap();'
        f'a().warn(`[{tag}] Diagnostic: pixel alpha at swallow = ${{_px[3]}}, cursor: (${{_c.x}}, ${{_c.y}}), bounds: ${{JSON.stringify(_b)}}`)'
        f'}}catch(_e){{a().warn(`[{tag}] Diagnostic capture threw: ${{_e&&_e.message}}`)}}}})()'
    )

# --- StatusWindow anchor: right after the #77 force-passthrough call ---
STATUS_ANCHOR = (
    'event coords: ${r}, ${i}`)'
    '/*WISPR_STATUS_FORCE_PASSTHROUGH*/,n.isDestroyed()||n.setIgnoreMouseEvents(!0,{forward:!0})'
    '}}),n.setMaxListeners(15)'
)
count = src.count(STATUS_ANCHOR)
if count != 1:
    print(f"ERROR: expected exactly 1 StatusWindow anchor, found {count}. "
          f"Bundle layout changed -- refusing to guess.", file=sys.stderr)
    sys.exit(1)
status_replacement = (
    'event coords: ${r}, ${i}`)'
    '/*WISPR_STATUS_FORCE_PASSTHROUGH*/,n.isDestroyed()||n.setIgnoreMouseEvents(!0,{forward:!0})'
    f',{diag_snippet("n", "StatusWindow")}'
    '}}),n.setMaxListeners(15)'
)
src = src.replace(STATUS_ANCHOR, status_replacement, 1)

# --- ContextMenuWindow anchor: right after the #77 force-passthrough call ---
# (the WISPR_CONTEXTMENU_FORCE_PASSTHROUGH marker sits BEFORE the `if`, not
# after warn() -- verified against the actual patched bundle.)
CTXMENU_ANCHOR = (
    'visible: ${o.isVisible()}`)'
    ',o.isDestroyed()||o.setIgnoreMouseEvents(!0,{forward:!0})'
    '}}),o.setMaxListeners(15)'
)
count = src.count(CTXMENU_ANCHOR)
if count != 1:
    print(f"ERROR: expected exactly 1 ContextMenuWindow anchor, found {count}. "
          f"Bundle layout changed -- refusing to guess.", file=sys.stderr)
    sys.exit(1)
ctxmenu_replacement = (
    'visible: ${o.isVisible()}`)'
    ',o.isDestroyed()||o.setIgnoreMouseEvents(!0,{forward:!0})'
    f',{diag_snippet("o", "ContextMenuWindow")}'
    '}}),o.setMaxListeners(15)'
)
src = src.replace(CTXMENU_ANCHOR, ctxmenu_replacement, 1)

if MARKER not in src:
    print("ERROR: verification failed -- marker not present after replace. Aborting.",
          file=sys.stderr)
    sys.exit(1)

shutil.copyfile(path, path + ".deadzonediag.orig")
print("Backup written:", path + ".deadzonediag.orig")
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(src)
print("OK: ground-truth diagnostic capture installed on both windows (marker: %s)." % MARKER)
PY

if command -v node >/dev/null; then
  node --check "$BUNDLE" && echo "node --check OK"
fi
echo "Done: next swallow will log the real pixel alpha (or capture error) at that moment."
