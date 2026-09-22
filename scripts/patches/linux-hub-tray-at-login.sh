#!/usr/bin/env bash
#===============================================================================
# linux-hub-tray-at-login.sh -- widen the existing "auto launch at login is
# enabled" skip-show gate to Linux, in the webpack-bundled Electron main
# process (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS (issue #81)
# ------------------------------------
# The Hub window's launch gate already has the exact branch we want, gated to
# Windows only:
#
#   c=()=>r.app.isPackaged?a.RA.prefs?.isUpdating?(...,!1)
#     :process.argv.includes(o.v5)?(...,!0)              // --show-hub-at-launch
#     :r.app.getLoginItemSettings().wasOpenedAtLogin?(...,!1)
#     :o.H8&&a.RA.prefs?.user?.openAtLogin&&a.RA.prefs.user.onboardingCompleted
#       ?(s().info("Not showing hub window at launch: auto launch at login is
#          enabled"),!1)
#       :(s().info("Showing hub window at launch: normal app launch"),!0)
#     :(...,!0);
#
# `o.H8` is this bundle's isWindows flag. `getLoginItemSettings()` (the
# branch just above) is genuinely macOS/Windows-only in Electron and always
# reads `wasOpenedAtLogin:false` on Linux, so that branch never fires there
# -- but the VERY NEXT branch already expresses the right general rule
# ("user turned on open-at-login AND has finished onboarding -> don't pop
# the Hub"), just restricted to Windows. On Linux this bundle's own "new
# user" hook writes the same `prefs.user.openAtLogin` flag on every platform
# (unconditionally, not gated by `H8`), so the data this branch reads is
# already correct on Linux -- only the platform read needs widening.
#
# Confirmed live on a real Linux install with autostart configured
# (~/.config/autostart/wispr-flow.desktop): `prefs.user.openAtLogin` and
# `prefs.user.onboardingCompleted` are both already `true` in
# ~/.config/Wispr Flow/config.json, so this widened gate fires correctly
# with zero other changes needed.
#
# THE PATCH (surgical, idempotent, .orig backup, verified against 1.6.897)
# --------------------------------------------------------------------------
#   o.H8&&a.RA.prefs?.user?.openAtLogin&&a.RA.prefs.user.onboardingCompleted?(
#     becomes
#   (o.H8||"linux"===process.platform)/*WISPR_LINUX_HUB_TRAY_AT_LOGIN*/&&a.RA.prefs?.user?.openAtLogin&&a.RA.prefs.user.onboardingCompleted?(
#
# The isWindows flag's identifier and the two `prefs` chains either side of
# `&&` are captured with `[\w$]+`/`[\w$.?]+` (never hardcoded) and the
# developer string in the branch's own log line anchors the site, per
# docs/learnings/patching-minified-js.md. `--show-hub-at-launch` and the
# `wasOpenedAtLogin` branch above this one are untouched -- both still work
# exactly as shipped, on every platform.
#
# WHY THIS CANNOT REGRESS NORMAL OPERATION
# -------------------------------------------
# - macOS/Windows: `o.H8` (or the darwin case, where it's already false)
#   keeps evaluating exactly as before; `||"linux"===process.platform` only
#   adds a new true case for Linux, never removes the existing one.
# - A Linux user who never enabled "open at login" still sees the Hub at
#   every launch (the added `&&` conditions are unchanged) -- this only
#   changes behavior for the same "open at login is on AND onboarding is
#   done" case Windows already gets.
# - `--show-hub-at-launch` (process.argv.includes(...)) is checked in an
#   earlier, untouched branch, so it still forces the Hub open on Linux too.
#
# Usage: linux-hub-tray-at-login.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "usage: $0 <path-to-.webpack/main/index.js>" >&2
  exit 1
fi

LINUX_MARKER="WISPR_LINUX_HUB_TRAY_AT_LOGIN"
if grep -q "$LINUX_MARKER" "$BUNDLE"; then
  echo "Already patched ($LINUX_MARKER present in $BUNDLE) - nothing to do."
  exit 0
fi

if [[ ! -f "$BUNDLE.orig" ]]; then
  cp -p "$BUNDLE" "$BUNDLE.orig"
  echo "Backup written: $BUNDLE.orig"
fi

python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import re, sys, io

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    src = f.read()

# Anchor: the isWindows flag && the openAtLogin/onboardingCompleted prefs
# chain, through the developer string that names this exact branch. Every
# identifier is captured with [\w$]+ / [\w$.?]+ -- never hardcoded -- so a
# future re-minify only breaks this if the branch's SHAPE changes, not its
# variable names.
anchor = re.compile(
    r'(?P<flag>[\w$]+\.[\w$]+)&&'
    r'(?P<prefs>[\w$.?]+\.openAtLogin&&[\w$.?]+\.onboardingCompleted)'
    r'\?\((?P<logger>[\w$]+\(\))\.info\('
    r'"Not showing hub window at launch: auto launch at login is enabled"\),!1\)'
)

EXPECTED = 1
matches = list(anchor.finditer(src))
if len(matches) != EXPECTED:
    sys.exit(
        f"ERROR: expected exactly {EXPECTED} \"auto launch at login is "
        f"enabled\" gate site(s), found {len(matches)}. Bundle layout may "
        f"have changed -- refusing to guess."
    )

def fix(m):
    return (
        '(' + m.group('flag') + '||"linux"===process.platform)/*' + marker + '*/&&'
        + m.group('prefs') + '?(' + m.group('logger') + '.info('
        '"Not showing hub window at launch: auto launch at login is enabled"),!1)'
    )

patched = anchor.sub(fix, src, count=EXPECTED)

if marker not in patched:
    sys.exit("ERROR: verification failed -- marker not present after replace. Aborting.")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(patched)
print(f"OK: hub tray-at-login gate widened to Linux (marker: {marker}).")
PY

if command -v node >/dev/null; then
  if ! node --check "$BUNDLE"; then
    echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
    cp -p "$BUNDLE.orig" "$BUNDLE"
    exit 1
  fi
  echo "node --check OK"
fi
echo "Done: Linux now honors 'Open at login' + completed onboarding as a tray-only launch, same as Windows."
