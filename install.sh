#!/usr/bin/env bash
# Install cogwake as a root LaunchDaemon. Needs root: it toggles
# `pmset disablesleep`, the only switch that survives a lid close on battery.
set -eu

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
[ "$(id -u)" = 0 ] || exec sudo bash "$SELF" "$@"

REPO="$(dirname "$SELF")"
LABEL="io.github.marcelsafin.cogwake"
BIN="/usr/local/bin/cogwake.sh"
CFG="/usr/local/etc/cogwake.env"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
ERRLOG="/var/log/cogwake.err"

mkdir -p /usr/local/bin /usr/local/etc /Library/LaunchDaemons

install -m 0755 -o root -g wheel "$REPO/bin/cogwake.sh" "$BIN"
[ -f "$CFG" ] || install -m 0644 -o root -g wheel "$REPO/cogwake.env.example" "$CFG"

sed -e "s|__LABEL__|$LABEL|g" \
    -e "s|__SCRIPT__|$BIN|g" \
    -e "s|__ERRLOG__|$ERRLOG|g" \
    "$REPO/launchd/$LABEL.plist.tmpl" > "$PLIST"
chown root:wheel "$PLIST"; chmod 0644 "$PLIST"

# Migrate any older per-user agent of the same name.
if [ -n "${SUDO_UID:-}" ]; then
  launchctl bootout "gui/$SUDO_UID/$LABEL" 2>/dev/null || true
  rm -f "/Users/${SUDO_USER:-}/Library/LaunchAgents/$LABEL.plist" \
        "/Users/${SUDO_USER:-}/.local/bin/cogwake.sh" 2>/dev/null || true
fi

launchctl bootout "system/$LABEL" 2>/dev/null || true
# bootout is async; bootstrapping before teardown finishes returns
# "Bootstrap failed: 5: Input/output error". Wait until it's really gone.
i=0; while launchctl print "system/$LABEL" >/dev/null 2>&1 && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done

launchctl enable "system/$LABEL" 2>/dev/null || true
# Bootstrap; if it still races to EIO, kickstart restarts in place and picks up
# the freshly copied /usr/local/bin/cogwake.sh.
launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl kickstart -k "system/$LABEL"
sleep 1

echo "installed: $LABEL (root LaunchDaemon)"
launchctl print "system/$LABEL" 2>/dev/null | grep -E 'state =|pid =' || true
echo "config: $CFG"
echo "log:    /var/log/cogwake.log"
