#!/usr/bin/env bash
#===============================================================================
# patch-hub-hidden-tray-only-linux.sh -- start Wispr Flow tray-only on Linux;
# never auto-show the Hub window at launch.
#
# BUG THIS FIXES
# ----------------------------------------------------------------------------
# The Hub window's own gate function already tries to skip showing itself at
# launch when the app was opened via the OS's login-item/autostart mechanism:
#
#   b=()=>i.app.isPackaged
#     ?d.RA.prefs?.isUpdating
#       ?(log("Not showing hub window at launch: app is updating"),!1)
#       :i.app.getLoginItemSettings().wasOpenedAtLogin
#         ?(log("Not showing hub window at launch: app was opened at login"),!1)
#         :(log("Showing hub window at launch: normal app launch"),!0)
#     :(log("Showing hub window at launch: dev app launch"),!0)
#
# `app.getLoginItemSettings().wasOpenedAtLogin` is macOS/Windows-only --
# Electron does not implement Linux login-item detection at all, so this
# always evaluates false on Linux regardless of how the process was actually
# started. This repo's own autostart entry
# (~/.config/autostart/wispr-flow.desktop) is a plain XDG .desktop file, which
# Electron's API has no way to see. Result: every launch on Linux --
# autostart at login, a manual relaunch, or the dead-zone workaround script
# restarting the process -- falls through to the "normal app launch" branch
# and pops the full Hub window on screen every time, unconditionally.
#
# Confirmed live: killing and relaunching the process always remaps the Hub
# window (`xwininfo` reports IsViewable immediately after a clean launch).
#
# THE PATCH (surgical, idempotent, .orig backup, verified)
# ----------------------------------------------------------------------------
# On Linux, always skip showing the Hub at launch -- tray-icon-only startup,
# matching a normal background-service UX. The tray's own context menu still
# has "Open Wispr Flow" and "Settings" entries that call the same show/focus
# helper, so the Hub remains one click away; nothing is removed, only the
# unconditional auto-show at process start.
#
#   :(a().info("Showing hub window at launch: normal app launch"),!0)
#     becomes
#   :"linux"===process.platform?(a().info("Not showing hub window at launch: Linux tray-only mode"),!1):(a().info("Showing hub window at launch: normal app launch"),!0)
#
# A marker comment WISPR_HUB_TRAY_ONLY_LINUX is left in the bundle so
# verify-patches.sh can statically confirm the patch shipped.
#
# WHY THIS CANNOT REGRESS NORMAL OPERATION
# ----------------------------------------
# - macOS/Windows behavior is untouched (the new branch only matches
#   process.platform==="linux").
# - Dev-mode launches (app.isPackaged===false) are untouched -- this only
#   changes the packaged/production branch.
# - The "app is updating" and "wasOpenedAtLogin" skip-show branches above
#   this one are untouched; this only changes what the final, previously
#   unconditional "show" branch does on Linux.
# - The Hub window is still fully created and functional -- only its
#   automatic initial `.show()` at the ready-to-show event is skipped. All
#   other show paths (tray menu, global shortcut, activate handler) are
#   unaffected.
#
# Usage: patch-hub-hidden-tray-only-linux.sh <path-to-.webpack/main/index.js>
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

MARKER = 'WISPR_HUB_TRAY_ONLY_LINUX'
if MARKER in src:
    print("Already patched (marker present). Nothing to do.")
    sys.exit(0)

# Anchor: the "normal app launch" show-hub branch. Verified unique (exactly
# one occurrence) against the pristine 1.6.7 bundle.
ANCHOR = (
    ':(a().info("Showing hub window at launch: normal app launch"),!0)'
    ':(a().info("Showing hub window at launch: dev app launch"),!0)'
)
count = src.count(ANCHOR)
if count != 1:
    print(f"ERROR: expected exactly 1 occurrence of the hub-launch-gate anchor, "
          f"found {count}. Bundle layout changed -- refusing to guess.", file=sys.stderr)
    sys.exit(1)

replacement = (
    f':/*{MARKER}*/"linux"===process.platform'
    '?(a().info("Not showing hub window at launch: Linux tray-only mode"),!1)'
    ':(a().info("Showing hub window at launch: normal app launch"),!0)'
    ':(a().info("Showing hub window at launch: dev app launch"),!0)'
)
patched = src.replace(ANCHOR, replacement, 1)

if MARKER not in patched:
    print("ERROR: verification failed -- marker not present after replace. Aborting.",
          file=sys.stderr)
    sys.exit(1)

shutil.copyfile(path, path + ".hubtrayonly.orig")
print("Backup written:", path + ".hubtrayonly.orig")
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(patched)
print("OK: Hub window no longer auto-shows at launch on Linux (marker: %s)." % MARKER)
PY

if command -v node >/dev/null; then
  node --check "$BUNDLE" && echo "node --check OK"
fi
echo "Done: Wispr Flow now starts tray-only on Linux; open it via the tray icon's context menu."
