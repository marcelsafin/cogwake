#!/usr/bin/env bash
# Install cogwake as a per-user launchd background agent.
set -eu

LABEL="io.github.marcelsafin.cogwake"
REPO="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$REPO/bin/cogwake.sh"
BIN="$HOME/.local/bin/cogwake.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ERRLOG="$HOME/Library/Logs/cogwake.err"
CFG="$HOME/.config/cogwake.env"

mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/.config"

chmod +x "$SCRIPT"
ln -sf "$SCRIPT" "$BIN"                       # symlink: repo stays source of truth
[ -f "$CFG" ] || cp "$REPO/cogwake.env.example" "$CFG"

sed -e "s|__LABEL__|$LABEL|g" \
    -e "s|__SCRIPT__|$BIN|g" \
    -e "s|__ERRLOG__|$ERRLOG|g" \
    "$REPO/launchd/io.github.marcelsafin.cogwake.plist.tmpl" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 1

echo "installed: $LABEL"
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E 'state =|pid =' || true
echo "config:  $CFG"
echo "log:     $HOME/Library/Logs/cogwake.log"
