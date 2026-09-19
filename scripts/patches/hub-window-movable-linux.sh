#!/usr/bin/env bash
#===============================================================================
# patch-hub-window-movable-linux.sh -- make the Flow Hub window actually
# movable on Linux (drag-to-reposition), in the webpack-bundled Electron
# main process (.webpack/main/index.js).
#
# BUG THIS FIXES
# --------------
# The Hub (main app) window cannot be moved: neither Wispr's own CSS
# `-webkit-app-region: drag` titlebar band nor GNOME's own WM-level
# Super+click-drag (a pure Mutter gesture, unrelated to the app) can
# reposition it. Confirmed with a live A/B test: Super+drag moves a
# completely different XWayland window (Bitwarden) fine, but not the Hub --
# so this is not an XWayland-vs-Wayland limitation, it is specific to the
# Hub window's own configuration.
#
# ROOT CAUSE (confirmed via `xprop -id <hub-window-id> _NET_WM_ALLOWED_ACTIONS`)
# -------------------------------------------------------------------------
# Mutter reports the Hub window's allowed actions as only
# `CHANGE_DESKTOP, ABOVE, BELOW` -- notably missing `_NET_WM_ACTION_MOVE`
# (also missing RESIZE/MINIMIZE/MAXIMIZE/CLOSE). A normal movable window
# (e.g. Bitwarden) reports the full set including MOVE. Electron's
# BrowserWindow config for the Hub sets `movable:!0` (true) -- but ALSO
# `focusable:!1` (false). On X11/EWMH, a non-focusable window (roughly,
# `WM_HINTS.input = False`) is treated by Mutter as a non-interactive
# utility surface and the move/resize/minimize/maximize/close actions are
# stripped from `_NET_WM_ALLOWED_ACTIONS` regardless of the `movable`/
# `resizable`/etc. hints -- Electron's own `movable:true` option only
# controls Electron's INTERNAL gating of its own setPosition/setMovable
# API; it has no effect on what the X11 window manager itself permits.
# On Windows and macOS, a non-focusable frameless window CAN still be
# dragged (HTCAPTION-style hit testing and Cocoa's movableByBackground both
# work independently of key-window status), so upstream never noticed this
# on the platforms they test. It is a genuine, Linux-specific bug in the
# upstream Hub window config: `focusable:false` was almost certainly chosen
# to stop the Hub from stealing input focus when it appears in the
# background (see the codebase's own `.focus()` calls elsewhere gated on a
# visible/active check), not to make the window immovable -- but on Linux
# it does both, and the Hub is the user's main app window, not an ambient
# overlay; it should be draggable.
#
# THE PATCH (surgical, Linux-only, idempotent, .orig backup, verified)
# ----------------------------------------------------------------------------
# At the Hub window's config site (identified by its preload path,
# ".../hub/preload.js", immediately followed by the focusable flag),
# widen `focusable:!1` to be platform-conditional:
#
#   focusable:!1
#     becomes
#   focusable:"linux"===process.platform
#
# mac/win keep the exact original value (`false`); Linux gets `true`,
# which restores `_NET_WM_ACTION_MOVE` (and RESIZE/MINIMIZE/MAXIMIZE/CLOSE)
# to Mutter's allowed-actions set, making both the CSS drag band and
# Super+drag work.
#
# This is a DIFFERENT window config from the Status/Context-Menu/Floating
# windows (which also set focusable:!1, deliberately paired with
# movable:!1/closable:!1/etc -- those are genuinely non-interactive
# overlays and are correctly left untouched; the anchor below is pinned
# tightly enough via the Hub's own preload path that it cannot match them).
#
# A marker comment WISPR_HUB_MOVABLE_LINUX is left in the bundle so
# verify-patches.sh can statically confirm the patch shipped.
#
# WHY THIS CANNOT REGRESS WINDOWS/MACOS BEHAVIOUR
# ------------------------------------------------
# `"linux"===process.platform` evaluates to `false` (the original literal
# value) on every other platform; the expression is only ever `true` when
# `process.platform==="linux"`. Windows/macOS get byte-identical behavior.
#
# Usage: patch-hub-window-movable-linux.sh <path-to-.webpack/main/index.js>
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

MARKER = 'WISPR_HUB_MOVABLE_LINUX'
if MARKER in src:
    print("Already patched (marker present). Nothing to do.")
    sys.exit(0)

# Anchor: the Hub window's preload path immediately followed by the
# devtools-gate object close and the focusable flag. Verified unique
# (exactly one occurrence) against the pristine 1.6.7 bundle.
ANCHOR = '(0,N.Pv)(d.RA.prefs?.user.email||"")},focusable:!1};'
count = src.count(ANCHOR)
if count != 1:
    print(f"ERROR: expected exactly 1 occurrence of the Hub-window focusable anchor, "
          f"found {count}. Bundle layout changed -- refusing to guess.", file=sys.stderr)
    sys.exit(1)

replacement = (
    '(0,N.Pv)(d.RA.prefs?.user.email||"")}'
    f',focusable:/*{MARKER}*/"linux"===process.platform}};'
)
patched = src.replace(ANCHOR, replacement, 1)

if MARKER not in patched:
    print("ERROR: verification failed -- marker not present after replace. Aborting.",
          file=sys.stderr)
    sys.exit(1)

shutil.copyfile(path, path + ".hubmovable.orig")
print("Backup written:", path + ".hubmovable.orig")
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(patched)
print("OK: Hub window is focusable (and therefore movable) on Linux (marker: %s)." % MARKER)
PY

if command -v node >/dev/null; then
  node --check "$BUNDLE" && echo "node --check OK"
fi
echo "Done: Hub window can now be dragged via its titlebar band or Super+drag."
