#!/usr/bin/env bash
# Remove the cogwake LaunchDaemon and reset the sleep override. Keeps config + logs.
set -eu

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
[ "$(id -u)" = 0 ] || exec sudo bash "$SELF" "$@"

LABEL="io.github.marcelsafin.cogwake"
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/usr/local/bin/cogwake.sh"
pmset -a disablesleep 0 2>/dev/null || true   # safety: never leave sleep disabled
echo "uninstalled: $LABEL  (kept /usr/local/etc/cogwake.env and logs; disablesleep reset to 0)"
