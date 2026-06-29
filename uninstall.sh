#!/usr/bin/env bash
# Remove the cogwake launchd agent. Leaves config + logs in place.
set -eu

LABEL="io.github.marcelsafin.cogwake"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$HOME/.local/bin/cogwake.sh"
# release any assertion this PID held (caffeinate -w dies with the watchdog already)
echo "uninstalled: $LABEL  (kept ~/.config/cogwake.env and logs)"
