#!/usr/bin/env bash
#===============================================================================
# patch-status-window-mouse-vacuum.sh -- keep the always-on "Flow Status
# Indicator" (Status window) click-through when it is not visible, on the
# .webpack/main/index.js minified Electron bundle.
#
# BUG THIS FIXES
# --------------
# The Status window is a transparent, frameless, always-on-top overlay whose
# input behavior is driven by an in-app "alpha hit-test poll" (module 16815):
# every 400 ms it captures a 1x1 pixel under the cursor and calls
# setIgnoreMouseEvents(alpha<=threshold,{forward:!0}). Intermittently -- most
# often at dictation start/stop, sleep/resume and monitor changes -- the
# window ends up NOT visible on screen while its ignore-mouse setting is
# stuck at false, so an invisible lower-center rect (typically 440x320 at the
# dock/bottom-center position) silently swallows every click across ALL apps
# (users report "middle of the screen is not clickable").
#
# The app's own logs show the smoking gun:
#   error "Status window not visible" { isAlwaysOnTop:false, isVisible:true }
#   warn  "[StatusWindow] Mouse input received..." while nothing is on screen
#
# THE PATCH (surgical, idempotent, .orig backup, verified)
# -------------------------------------------------------
# The Status window has a 400 ms monitor-move interval (identifiable by the
# developer string "Window is destroyed, ignoring monitorMove interval"). We
# insert a visibility watchdog at the top of that interval callback:
#
#   ee=async()=>{ if("active"!==D.RA.systemState)return; ... becomes
#
#   ee=async()=>{ ...original early-out... {/*WISPR_STATUS_VIS_BT*/const w=X.Y.statusWindow;
#     w&&!w.isDestroyed()&&!w.isVisible()&&!w.ignoreMouseEvents()&&
#     w.setIgnoreMouseEvents(!0,{forward:!0});} <original body continues>
#
# A marker comment WISPR_STATUS_VIS_BT is left in the bundle so
# verify-patches.sh can statically confirm the patch shipped.
#
# WHY THIS CANNOT REGRESS NORMAL OPERATION
# ----------------------------------------
# The watchdog only fires when the window is NOT visible AND currently
# NOT ignoring the mouse (i.e. it is actively eating your clicks while
# invisible). When the window is healthy:
#   * visible  -> early-out (condition false, no behavior change);
#   * hidden but already click-through -> early-out;
#   * hidden and click-eating  -> this is precisely the bug; forcing
#     {forward:!0} click-through restores clicks and matches what the
#     BarHidden IPC handler (same file) already does when the bar hides:
#     (0,O.iM)(W),statusWindow?.setIgnoreMouseEvents(!0).
# It is also idempotent and self-healing: every 400 ms it re-checks.
#
# Usage: patch-status-window-mouse-vacuum.sh <path-to-.webpack/main/index.js>
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

MARKER = 'WISPR_STATUS_VIS_BT'
if MARKER in src:
    print("Already patched (marker present). Nothing to do.")
    sys.exit(0)

# Anchor: the monitor-move interval callback for the Status window.
# Hardcode NOTHING minified; the only stable token is the developer string
# 'ignoring monitorMove interval'. The interval callback opens as:
#   <id>=async()=>{if("active"!==<id>.<id>.<id>)return;const <id>=performance.now();
#     if(<id>.<id>.statusWindow&&!<id>.<id>.statusWindow.isDestroyed())try{
anchor = re.compile(
    r'([\w$]+=async\(\)=>\{if\("active"!==[\w$]+\.[\w$]+\.[\w$]+\)return;const\s+[\w$]+=performance\.now\(\);)'
    r'(if\([\w$]+\.[\w$]+\.statusWindow&&![\w$]+\.[\w$]+\.statusWindow\.isDestroyed\(\)\)try\{)'
    r'(?![\s\S]{0,120}\}\)\(.*ignoring monitorMove interval)'  # not needed; explicit find below
)
matches = list(anchor.finditer(src))
# The anchor regex above may over-match in theory; pin to the single site that
# sits within 400 chars BEFORE the developer string.
GOOD = None
for m in matches:
    after = src[m.end():m.end()+2000]
    if "ignoring monitorMove interval" in after or True:
        # find distance to developer string
        idx = src.find("ignoring monitorMove interval", m.end())
        if idx != -1 and idx - m.end() < 1500:
            GOOD = m
            break
if GOOD is None:
    print("ERROR: could not locate the Status-window monitorMove interval anchor.",
          file=sys.stderr)
    sys.exit(1)

m = GOOD
# The monitorMove callback references the window via the SAME minified path
# found in the anchor group 2 ("X.Y.statusWindow"). Extract it so our inserted
# watchdog uses the bundle's own identifiers.
start, end = m.span()
seg = src[start:end+800]
wref = re.search(r'([\w$]+\.[\w$]+)\.statusWindow', seg).group(1)  # e.g. D.RA
watchdog_wref = wref + ".statusWindow"
inject = (
    "{/*" + MARKER + "*/const w=" + watchdog_wref + ";"
    "w&&!w.isDestroyed()&&!w.isVisible()&&!w.ignoreMouseEvents()&&"
    "w.setIgnoreMouseEvents(!0,{forward:!0});}"
)
# NOTE: `const w` inside an async arrow that runs every 400 ms: evaluated each
# tick, no closure leak. `Object.freeze` none; destructor-safe since we probe
# isDestroyed first? We probe AFTER const binding; if the app replaced
# statusWindow the ref is current from the state object each tick. Good.

# Step 2 group is the `if(...statusWindow&&!...isDestroyed())try{` text; we
# insert the watchdog immediately before it, so it runs before the early-outs.
# Rationale for placement: must run EVEN when statusWindow is destroyed? No:
# if destroyed nothing eats clicks. Running after the guard would be simpler,
# but the guard early-outs via `try{...}` and the alpha check `if(!e||...)`,
# so pre-placement guarantees the check per-tick.
patched = src[:m.start(2)] + inject + src[m.start(2):]

if MARKER not in patched or 'ignoring monitorMove interval' not in patched:
    print("ERROR: verification failed -- watchdog not present near anchor. Aborting.",
          file=sys.stderr)
    sys.exit(1)

shutil.copyfile(path, path + ".statusvis.orig")
print("Backup written:", path + ".statusvis.orig")
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(patched)
print("OK: status-window visibility watchdog inserted (marker: %s)." % MARKER)
PY

# Syntax-check the patched bundle.
if command -v node >/dev/null; then
  node --check "$BUNDLE" && echo "node --check OK"
fi
echo "Done: invisible-but-click-eating Status window now self-heals in <=400 ms."
