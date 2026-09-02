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
# A missing or empty settings.json is `{}`; anything else must parse, and a
# parse error stops here with the file untouched (jq's message is on stderr).
[ -s "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
current=$(jq -c '.statusLine // {}' "$SETTINGS") \
  || { echo "cannot parse $SETTINGS — fix it and re-run"; exit 1; }
# Our keys are set on top of whatever the user put under statusLine (padding…).
merged=$(printf '%s' "$current" | jq -c --argjson sl "$want" '. + $sl')
if [ "$merged" = "$current" ]; then
  echo "unchanged  $SETTINGS (statusLine already set)"
else
  cp "$SETTINGS" "$SETTINGS.bak"
  jq --argjson sl "$merged" '.statusLine = $sl' "$SETTINGS" > "$SETTINGS.tmp" \
    && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "updated    $SETTINGS (backup: $SETTINGS.bak)"
fi
