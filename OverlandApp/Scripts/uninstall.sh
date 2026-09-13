#!/bin/zsh
#
# uninstall.sh: Remove Overland completely from this Mac.
#
# Disconnects (through the app, so gpclient restores routes and DNS),
# unregisters the privileged helper's background item, quits the app, and
# deletes the bundle, its Application Support folder and preferences.
# Keychain passwords saved by the app are removed too.
#
# Usage: zsh OverlandApp/Scripts/uninstall.sh [/path/to/Overland.app]
set -euo pipefail

APP="${1:-/Applications/Overland.app}"
BUNDLE_ID="io.bino.overland"

if [[ -d "$APP" ]]; then
    echo "==> Unregistering the privileged helper"
    # The helper owns any running tunnel; unregistering from the app's own
    # binary keeps the registration record consistent.
    "$APP/Contents/MacOS/Overland" --helper-status --helper-unregister 2>/dev/null | sed -n 's/^unregister():/    unregister:/p' || true
fi

if pgrep -f "$APP/Contents/MacOS/Overland" >/dev/null 2>&1; then
    echo "==> Quitting Overland (it disconnects first if connected)"
    osascript -e 'tell application id "io.bino.overland" to quit' 2>/dev/null || pkill -f "$APP/Contents/MacOS/Overland" || true
    for _ in {1..30}; do
        pgrep -f "$APP/Contents/MacOS/Overland" >/dev/null 2>&1 || break
        sleep 0.5
    done
fi

echo "==> Removing files"
[[ -d "$APP" ]] && rm -rf "$APP" && echo "    removed $APP"
rm -rf "$HOME/Library/Application Support/Overland" && echo "    removed ~/Library/Application Support/Overland"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 && echo "    removed preferences" || true
rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
while security delete-generic-password -s "$BUNDLE_ID" >/dev/null 2>&1; do :; done

echo "✓ Overland removed. If a stale entry remains in System Settings › Login Items & Extensions, remove it there."
