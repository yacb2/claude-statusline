#!/bin/sh
# Tests for the account tag at the head of line 1.
#
# Contract: the profile in <config dir>/.claude.json (~/.claude.json without
# CLAUDE_CONFIG_DIR) decides the tag.
#   email listed in $XDG_CONFIG_HOME/claude-statusline/work-accounts -> "W"
#     (case and stray spaces/CR in the list are ignored, a substring is not a match)
#   any other email -> "P·<initial>", the display name's first letter upper-cased,
#     the email's when the name is missing or empty
#   no profile, no file -> no tag
#
# Self-contained: HOME and XDG_CONFIG_HOME are redirected to a fixture dir.

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline-command.sh"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/statusline-acct-test.XXXXXX")
trap 'rm -rf "$FIX"' EXIT INT TERM
mkdir -p "$FIX/.claude" "$FIX/work" "$FIX/cfg/claude-statusline"
LIST="$FIX/cfg/claude-statusline/work-accounts"

fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

# The tag: line 1 up to the model name, colours stripped. $1 = config dir ("" = unset).
tag() {
  printf '{"model":{"display_name":"Claude Opus 4.8"},"workspace":{"current_dir":"%s"}}' "$FIX" \
    | if [ -n "$1" ]; then HOME="$FIX" XDG_CONFIG_HOME="$FIX/cfg" CLAUDE_CONFIG_DIR="$1" sh "$SCRIPT"
      else HOME="$FIX" XDG_CONFIG_HOME="$FIX/cfg" sh "$SCRIPT"; fi \
    | sed -n '1p' | sed 's/\x1b\[[0-9;]*m//g' | sed 's/Opus 4\.8.*//'
}
profile() { printf '%s\n' "$2" > "$1/.claude.json"; }   # <dir> <json>

printf 'Boss@Work.example \r\n' > "$LIST"

profile "$FIX" '{"oauthAccount":{"emailAddress":"zoe@home.example","displayName":"zoe"}}'
eq "default dir, personal: P and the upper-cased initial" "$(tag "")" "P·Z "

profile "$FIX/work" '{"oauthAccount":{"emailAddress":"boss@work.example","displayName":"Boss"}}'
eq "listed email (case, spaces, CR ignored): W, no initial" "$(tag "$FIX/work")" "W "

profile "$FIX/work" '{"oauthAccount":{"emailAddress":"xboss@work.example","displayName":"Yan"}}'
eq "a longer email holding a listed one is personal" "$(tag "$FIX/work")" "P·Y "

profile "$FIX/work" '{"oauthAccount":{"emailAddress":"ana@home.example","displayName":""}}'
eq "empty display name: the email's initial" "$(tag "$FIX/work")" "P·A "

profile "$FIX/work" '{"oauthAccount":{"emailAddress":"ana@home.example"}}'
eq "missing display name: the email's initial" "$(tag "$FIX/work")" "P·A "

profile "$FIX/work" '{"oauthAccount":{"emailAddress":"ana@home.example","displayName":"Ángel"}}'
eq "a non-ASCII initial is kept whole" "$(tag "$FIX/work")" "P·Á "

profile "$FIX/work" '{"oauthAccount":{"emailAddress":"ana@home.example","displayName":["x; touch pwned"]}}'
eq "a non-string display name falls back to the email" "$(tag "$FIX/work")" "P·A "
[ -e pwned ] || [ -e "$FIX/pwned" ] && bad "nothing is executed" "pwned exists" || ok "nothing is executed"

profile "$FIX/work" '{"numStartups":3}'
eq "no profile: no tag" "$(tag "$FIX/work")" ""

rm -f "$FIX/work/.claude.json"
eq "no account file: no tag" "$(tag "$FIX/work")" ""

rm -f "$LIST"
profile "$FIX/work" '{"oauthAccount":{"emailAddress":"boss@work.example","displayName":"Boss"}}'
eq "no work list: every account is personal" "$(tag "$FIX/work")" "P·B "

[ "$fails" -eq 0 ] && { echo; echo "ALL PASS"; exit 0; }
echo; echo "$fails FAILED"; exit 1
