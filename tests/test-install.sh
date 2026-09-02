#!/bin/sh
# Regression tests for install.sh. HOME is redirected to a fixture dir, so the
# real ~/.claude is never touched.
#
# Covers:
#   1. Fresh HOME: the script is copied, settings.json is created and wired.
#   2. Re-run is idempotent and reports "unchanged".
#   3. An invalid settings.json must fail loudly and leave the file as it was.
#      Bug: `jq ... > tmp && mv` inside an && list does not trip `set -e`, so a
#      parse error printed "updated", exited 0, left a 0-byte .tmp and never
#      wired the status line.
#   4. An empty settings.json is treated as `{}`, not as a parse error and not
#      as a file to overwrite with nothing.
#   5. Extra keys the user put under statusLine (e.g. "padding") survive.
#      Bug: `.statusLine = $sl` replaced the whole object on every run.

HERE=$(cd "$(dirname "$0")" && pwd)
INSTALL="$HERE/../install.sh"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/statusline-install-test.XXXXXX")
trap 'rm -rf "$FIX"' EXIT INT TERM
SETTINGS="$FIX/.claude/settings.json"

fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }
want() { # <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1" "expected to contain '$3', got: [$2]" ;;
  esac
}
run() { HOME="$FIX" sh "$INSTALL" 2>&1; }
cmd() { jq -r '.statusLine.command // "absent"' "$SETTINGS" 2>/dev/null; }

# ------------------------------------------------------------ 1. fresh HOME
out=$(run); rc=$?
[ "$rc" -eq 0 ] && ok "fresh install exits 0" || bad "fresh install exits 0" "rc=$rc: $out"
[ -x "$FIX/.claude/statusline-command.sh" ] && ok "script installed" || bad "script installed" "missing"
[ "$(cmd)" = "~/.claude/statusline-command.sh" ] && ok "statusLine wired" || bad "statusLine wired" "command: $(cmd)"

# ------------------------------------------------------------ 2. idempotent
out=$(run)
want "second run reports unchanged" "$out" "unchanged"

# ------------------------------------------------- 3. invalid settings.json
printf '{bad\n' > "$SETTINGS"
out=$(run); rc=$?
[ "$rc" -ne 0 ] && ok "invalid settings.json fails" || bad "invalid settings.json fails" "rc=0: $out"
[ "$(cat "$SETTINGS")" = "{bad" ] && ok "invalid settings.json left untouched" || bad "invalid settings.json left untouched" "now: $(cat "$SETTINGS")"
[ ! -e "$SETTINGS.tmp" ] && ok "no .tmp litter" || bad "no .tmp litter" "$SETTINGS.tmp exists"

# --------------------------------------------------- 4. empty settings.json
: > "$SETTINGS"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && ok "empty settings.json is accepted" || bad "empty settings.json is accepted" "rc=$rc: $out"
[ "$(cmd)" = "~/.claude/statusline-command.sh" ] && ok "empty settings.json gets wired" || bad "empty settings.json gets wired" "command: $(cmd)"

# ------------------------------------------- 5. user keys under statusLine
jq '.statusLine.padding = 0 | .other = 1' "$SETTINGS" > "$SETTINGS.new" && mv "$SETTINGS.new" "$SETTINGS"
out=$(run)
want "user statusLine keys are not a change" "$out" "unchanged"
[ "$(jq -r '.statusLine.padding' "$SETTINGS")" = "0" ] && ok "padding survives" || bad "padding survives" "$(cat "$SETTINGS")"
[ "$(jq -r '.other' "$SETTINGS")" = "1" ] && ok "other settings survive" || bad "other settings survive" "$(cat "$SETTINGS")"

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo 'ALL PASS' || echo "$fails FAILED")"
[ "$fails" -eq 0 ]
