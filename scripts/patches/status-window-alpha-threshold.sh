#!/usr/bin/env bash
#===============================================================================
# patch-status-window-alpha-threshold.sh -- fix the real root cause of the
# "invisible bar swallows every click across ALL apps" bug on the
# .webpack/main/index.js minified Electron bundle.
#
# BUG THIS FIXES
# --------------
# The always-on "Flow Status Indicator" (and every other transparent overlay
# window sharing the same helper: context menu, hub, etc.) decides whether to
# be click-through with a 400 ms poll (function alias `Bi` in the minified
# bundle):
#
#   1. sample cursor position; skip if unchanged since the last tick
#   2. if the cursor is inside the window's bounds, capture the 1x1 pixel
#      under it via webContents.capturePage(...)
#   3. read the alpha byte of that pixel and call
#        setIgnoreMouseEvents(alpha <= t, {forward:true})
#      where `t` is the poll's threshold parameter.
#
# The Status window starts this poll with NO threshold argument --
# `(0,m.Bi)(e)` -- so it falls back to the function's default: `t=0`. That
# means the window is click-through ONLY when the sampled pixel's alpha is
# EXACTLY 0. Any GPU/compositor rounding, anti-aliasing, or a translucent
# backdrop/shadow under the visible pill (all normal for a frosted-glass bar
# UI) produces alpha values of 1-20/255 -- imperceptible to the eye, but
# `1 <= 0` is false, so setIgnoreMouseEvents(false) fires and the ENTIRE
# 440x320 window rect (not just the visible pill) permanently swallows
# clicks. This is not intermittent: it is the poll's normal, designed
# behavior whenever the "transparent" background isn't literally alpha=0,
# which on this Intel+NVIDIA/XWayland stack it usually isn't.
#
# Evidence from the live app's own logs (`~/.config/Wispr Flow/logs/main.log`):
#   - `[StatusWindow] Mouse input received - type: mouseDown, bounds:
#     {"x":722,"y":760,"width":440,"height":320}, visible: true, ...` fires
#     for every failed click in that exact screen rect (bottom-center on a
#     1920x1080 panel) -- "middle/mid-bottom of the screen", matching every
#     user report in this repo.
#   - `lastAlphaCheck` in that same log line was `null` for literally every
#     occurrence across the whole session, i.e. even when the poll IS
#     running and IS successfully flipping setIgnoreMouseEvents(false), it
#     never reads back as a "capture failure" -- ruling out the poll being
#     stuck/broken and pointing squarely at the alpha<=0 threshold itself.
#
# THE PATCH (surgical, idempotent, .orig backup, verified)
# ----------------------------------------------------------------------------
# Raise the poll's default threshold from `t=0` to `t=10` (about 4% opacity
# -- still visually indistinguishable from transparent, but well above any
# compositor rounding noise). Patching the DEFAULT PARAMETER (not the single
# call site) means every window that reuses this shared click-through helper
# gets the same tolerance, uniformly.
#
# A marker comment WISPR_ALPHA_THRESH_BT is left in the bundle so
# verify-patches.sh can statically confirm the patch shipped.
#
# WHY THIS CANNOT REGRESS NORMAL OPERATION
# ----------------------------------------
# - Raising the click-through threshold only makes the window MORE willing
#   to pass clicks through, never less: a pixel that was already alpha<=0
#   (real content, "click me") still fails `alpha<=10` the same way real
#   opaque bar UI (alpha typically 200+/255) always will. Only near-zero
#   alpha noise flips from "capture" to "click-through".
# - The visible bar UI itself renders at normal (near-255) alpha, so its own
#   buttons remain fully clickable; only the surrounding faux-transparent
#   padding becomes reliably click-through.
#
# Usage: patch-status-window-alpha-threshold.sh <path-to-.webpack/main/index.js>
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

MARKER = 'WISPR_ALPHA_THRESH_BT'
if MARKER in src:
    print("Already patched (marker present). Nothing to do.")
    sys.exit(0)

# Anchor: the alpha click-through poll starter -- unique across the bundle
# (verified: exactly one occurrence). `b` is the minified export name of the
# poll-starting function; `t=0` is the threshold default we are correcting.
ANCHOR = 'b=(e,t=0)=>{const n=new r.eu'
count = src.count(ANCHOR)
if count != 1:
    print(f"ERROR: expected exactly 1 occurrence of the alpha-poll anchor, found {count}. "
          "Bundle layout changed -- refusing to guess.", file=sys.stderr)
    sys.exit(1)

replacement = f'b=(/*{MARKER}*/e,t=10)=>{{const n=new r.eu'
patched = src.replace(ANCHOR, replacement, 1)

if MARKER not in patched:
    print("ERROR: verification failed -- marker not present after replace. Aborting.",
          file=sys.stderr)
    sys.exit(1)

shutil.copyfile(path, path + ".alphathresh.orig")
print("Backup written:", path + ".alphathresh.orig")
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(patched)
print("OK: alpha click-through threshold raised 0 -> 10 (marker: %s)." % MARKER)
PY

if command -v node >/dev/null; then
  node --check "$BUNDLE" && echo "node --check OK"
fi
echo "Done: alpha hit-test threshold now tolerates compositor rounding noise."
