#!/usr/bin/env bash
# TermIMS uninstall — remove every file the app drops on disk and unload its
# launch agent. macOS will not let an external script revoke the
# Accessibility / Automation permissions, so those are listed at the end and
# left for the user to delete by hand in System Settings.

set -u

BUNDLE_ID="top.cuiko.termims"
APP_PATH="/Applications/TermIMS.app"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"

say() { printf '%s\n' "$1"; }
ok()  { printf '  ✓ %s\n' "$1"; }
skip(){ printf '  · %s\n' "$1"; }

say "TermIMS uninstall"
say ""

# 1. Quit the app if it's running.
if pgrep -x TermIMS >/dev/null 2>&1; then
    osascript -e 'quit app "TermIMS"' >/dev/null 2>&1 || true
    ok "quit TermIMS"
else
    skip "TermIMS not running"
fi

# 2. Unload + remove the launch agent so it doesn't relaunch on next login.
if [ -f "$LAUNCH_AGENT" ]; then
    launchctl unload "$LAUNCH_AGENT" >/dev/null 2>&1 || true
    rm -f "$LAUNCH_AGENT"
    ok "removed launch agent"
else
    skip "no launch agent installed"
fi

# 3. Delete the application bundle.
if [ -d "$APP_PATH" ]; then
    rm -rf "$APP_PATH"
    ok "removed ${APP_PATH}"
else
    skip "${APP_PATH} not present"
fi

# 4. Clear UserDefaults (rules, default input methods, indicator settings).
if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    ok "removed preferences (${BUNDLE_ID})"
else
    skip "no preferences to remove"
fi

# 5. Logs + cached data.
for path in \
    "${HOME}/Library/Logs/TermIMS" \
    "${HOME}/Library/Caches/${BUNDLE_ID}" \
    "${HOME}/Library/Caches/${BUNDLE_ID}.plist" \
    "${HOME}/Library/Preferences/${BUNDLE_ID}.plist" \
    "${HOME}/Library/HTTPStorages/${BUNDLE_ID}" \
    "${HOME}/Library/Saved Application State/${BUNDLE_ID}.savedState"
do
    if [ -e "$path" ]; then
        rm -rf "$path"
        ok "removed ${path/#${HOME}/~}"
    fi
done

say ""
say "Manual step (macOS does not let scripts revoke TCC grants):"
say "  System Settings → Privacy & Security → Accessibility — remove TermIMS"
say "  System Settings → Privacy & Security → Automation — remove the"
say "    'TermIMS' entries for Terminal / iTerm if they appear"
say ""
say "Done."
