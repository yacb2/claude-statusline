#!/bin/sh
unset CLAUDE_CONFIG_DIR   # the suites choose their own config dir; never inherit the caller's
# Tests for the weekly-quota history the status line keeps.
#
# Contract, under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aidex/:
#   quota-history.jsonl  one line per weekly cycle (seven_day.resets_at), written the
#                        first time that resets_at is seen; a new cycle's line carries
#                        the previous cycle's closing % as prev_used_percentage
#   quota-current.json   the last {resets_at, used_percentage} seen
#   A render killed between writing quota-current.json.tmp.<pid> and the mv leaves the
#   tmp behind; a later render deletes tmp files older than a minute.
#
# Self-contained: HOME is redirected to a fixture dir.

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline-command.sh"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/statusline-qh-test.XXXXXX")
trap 'rm -rf "$FIX"' EXIT INT TERM
mkdir -p "$FIX/.claude"
Q="$FIX/.claude/aidex"

fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

now=$(date +%s)
w1=$((now + 86400)); w2=$((now + 7 * 86400))
# Render with a seven_day window: $1 = resets_at, $2 = used_percentage.
render() {
  printf '{"model":{"display_name":"Claude Opus 4.8"},"workspace":{"current_dir":"%s"},"rate_limits":{"seven_day":{"used_percentage":%s,"resets_at":%s}}}' "$FIX" "$2" "$1" \
    | HOME="$FIX" sh "$SCRIPT" >/dev/null 2>&1
}

# ------------------------------------ 1. one line per cycle
render "$w1" 40
render "$w1" 45
eq "same cycle writes one line" "$(wc -l < "$Q/quota-history.jsonl" | tr -d ' ')" "1"
eq "current holds the last %" "$(jq -r .used_percentage "$Q/quota-current.json")" "45"

# ------------------------------------ 2. a new cycle carries the previous closing %
render "$w2" 3
eq "new cycle adds a line" "$(wc -l < "$Q/quota-history.jsonl" | tr -d ' ')" "2"
eq "new line carries prev %" "$(tail -1 "$Q/quota-history.jsonl" | jq -r .prev_used_percentage)" "45"
eq "first line has no prev" "$(head -1 "$Q/quota-history.jsonl" | jq -r '.prev_used_percentage // "none"')" "none"

# ------------------------------------ 3. a stale tmp left by a killed render is swept
: > "$Q/quota-current.json.tmp.99999"
touch -t 202001010000 "$Q/quota-current.json.tmp.99999"
: > "$Q/quota-current.json.tmp.88888"   # fresh: may belong to a render in flight
render "$w2" 4
[ -e "$Q/quota-current.json.tmp.99999" ] && bad "stale tmp swept" "still there" || ok "stale tmp swept"
[ -e "$Q/quota-current.json.tmp.88888" ] && ok "fresh tmp kept" || bad "fresh tmp kept" "deleted"

[ "$fails" -eq 0 ] && { echo; echo "ALL PASS"; exit 0; }
echo; echo "$fails FAILED"; exit 1
