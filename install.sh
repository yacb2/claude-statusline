#!/bin/sh
# Install statusline-command.sh into ~/.claude and wire it into settings.json.
# Idempotent: re-run after pulling to update the installed copy.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
DEST="$HOME/.claude/statusline-command.sh"
SETTINGS="$HOME/.claude/settings.json"

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq / apt install jq)"; exit 1; }

mkdir -p "$HOME/.claude"
cp "$HERE/statusline-command.sh" "$DEST"
chmod +x "$DEST"
echo "installed  $DEST"

want='{"type":"command","command":"~/.claude/statusline-command.sh","refreshInterval":60}'
[ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
if [ "$(jq -c '.statusLine // {}' "$SETTINGS")" = "$want" ]; then
  echo "unchanged  $SETTINGS (statusLine already set)"
else
  cp "$SETTINGS" "$SETTINGS.bak"
  jq --argjson sl "$want" '.statusLine = $sl' "$SETTINGS" > "$SETTINGS.tmp" \
    && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "updated    $SETTINGS (backup: $SETTINGS.bak)"
fi
