#!/bin/sh
# Regression tests for the cross-session rate-limit cache in statusline-command.sh.
#
# Claude Code hands each session ITS OWN snapshot of rate_limits, taken at that
# session's last API response. Two documented properties make a shared cache
# non-trivial (https://code.claude.com/docs/en/statusline — "Fields that may be
# absent"): each window (five_hour / seven_day) may be independently absent, and
# a window is dropped once its resets_at passes. So an idle session carries a
# stale seven_day and no five_hour at all, while its transcript mtime keeps
# moving. Observed 2026-08-29 across five live sessions: 7d reported 38/40/42/48
# by idle sessions against 63 by the active one, and only the active one carried
# five_hour. The first cache design keyed freshness on transcript mtime and
# replaced the whole snapshot, so an idle session could publish a partial, stale
# one over the good one — and every session lost the 5h window.
#
# The rule under test: merge PER WINDOW from the data itself, never from a file
# clock.
#   resets_at passed            -> dropped, rendered as a dim placeholder
#   same resets_at              -> higher used_percentage wins (usage is cumulative)
#   different resets_at, both live -> the snapshot taken later wins, dated by the
#     last real assistant response in the transcript (taken_at); equal -> later
#     resets_at
#
# Self-contained: HOME is redirected to a fixture dir so the real cache and
# settings.json are never read or written.

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline-command.sh"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/statusline-rl-test.XXXXXX")
trap 'rm -rf "$FIX"' EXIT INT TERM
mkdir -p "$FIX/.claude"
CACHE="$FIX/.claude/rate-limits-cache.json"
# The session's transcript: its last real assistant entry dates the snapshot
# (taken_at). Cases that need a date write entries into it and truncate after.
TRANSCRIPT="$FIX/transcript.jsonl"
: > "$TRANSCRIPT"

fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }
want() { # <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1" "expected to contain '$3', got: [$2]" ;;
  esac
}
want_not() { # <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) bad "$1" "expected NOT to contain '$3', got: [$2]" ;;
    *) ok "$1" ;;
  esac
}

now=$(date +%s)
in_2h=$((now + 7200))
in_5d=$((now + 432000))
ago_1h=$((now - 3600))

# Render line 1, colours stripped. $1 = rate_limits JSON ("" = field absent).
# $2 = extra top-level JSON members (optional), e.g. a context_window.
run() {
  if [ -n "$1" ]; then rl=",\"rate_limits\":$1"; else rl=""; fi
  printf '{"model":{"display_name":"Claude Opus 4.8","id":"claude-opus-4-8[1m]"},"workspace":{"current_dir":"%s"},"transcript_path":"%s","effort":{"level":"medium"}%s%s}' "$FIX" "$TRANSCRIPT" "$rl" "${2:+,$2}" \
    | HOME="$FIX" sh "$SCRIPT" | sed -n '1p' | sed 's/\x1b\[[0-9;]*m//g'
}
seed() { printf '%s\n' "$1" > "$CACHE"; }
cache_five() { jq -r '.rate_limits.five_hour.used_percentage // "absent"' "$CACHE"; }
cache_week() { jq -r '.rate_limits.seven_day.used_percentage // "absent"' "$CACHE"; }

# ------------------------------------ 1. a partial snapshot must not erase a window
seed "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":29,\"resets_at\":$in_2h},\"seven_day\":{\"used_percentage\":63,\"resets_at\":$in_5d}}}"
out=$(run "{\"seven_day\":{\"used_percentage\":40,\"resets_at\":$in_5d}}")
want     "5h survives a payload that lacks it"     "$out" "5h 29%"
want     "stale 7d from an idle session loses"     "$out" "7d 63%"
want_not "stale 7d is not rendered"                "$out" "7d 40%"
[ "$(cache_five)" = "29" ] && ok "cache keeps five_hour" || bad "cache keeps five_hour" "cache five_hour: $(cache_five)"
[ "$(cache_week)" = "63" ] && ok "cache keeps the higher 7d" || bad "cache keeps the higher 7d" "cache seven_day: $(cache_week)"

# ------------------------------------ 2. same window: the higher usage is the newer
seed "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":29,\"resets_at\":$in_2h}}}"
out=$(run "{\"five_hour\":{\"used_percentage\":31,\"resets_at\":$in_2h}}")
want "payload with higher usage wins" "$out" "5h 31%"
[ "$(cache_five)" = "31" ] && ok "cache advanced to 31" || bad "cache advanced to 31" "cache five_hour: $(cache_five)"

# ------------------------------------ 3. a newer window wins even at lower usage
seed "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":90,\"resets_at\":$in_2h}}}"
out=$(run "{\"five_hour\":{\"used_percentage\":3,\"resets_at\":$((in_2h + 18000))}}")
want "later resets_at wins" "$out" "5h 3%"

# ------------------------------------ 4. an expired window is dropped, not shown stale
seed "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":90,\"resets_at\":$ago_1h},\"seven_day\":{\"used_percentage\":63,\"resets_at\":$in_5d}}}"
out=$(run "{\"seven_day\":{\"used_percentage\":63,\"resets_at\":$in_5d}}")
want_not "expired 5h is not rendered"       "$out" "5h 90%"
want     "unknown 5h renders a placeholder" "$out" "5h —"
want     "7d still renders"                 "$out" "7d 63%"
[ "$(cache_five)" = "absent" ] && ok "expired window purged from cache" || bad "expired window purged from cache" "cache five_hour: $(cache_five)"

# ------------------------------------ 5. no cache, no payload: placeholders, no crash
rm -f "$CACHE"
out=$(run "")
want "no data -> 5h placeholder" "$out" "5h —"
want "no data -> 7d placeholder" "$out" "7d —"

# ------------------------------------ 6. a server-side reset replaces a window with an
# EARLIER resets_at. Observed 2026-09-01: every quota was reset account-wide; the live
# snapshot became 7d 1% resetting in 16h while the cache held 7d 29% resetting in 5
# days, and "later resets_at wins" pinned the stale 29% on every session. Between two
# live windows the tie-break is the snapshot's own age: the timestamp of the last
# assistant entry in the transcript, which is when that session last heard from the
# API. An idle session re-reporting the old window later must not win it back.
iso() { jq -n --argjson t "$1" '$t | todate'; }
in_16h=$((now + 57600))
seed "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":29,\"resets_at\":$in_5d,\"taken_at\":$((now - 86400))}}}"
printf '{"type":"assistant","timestamp":%s,"message":{"usage":{"input_tokens":1000}}}\n' "$(iso "$now")" > "$TRANSCRIPT"
out=$(run "{\"seven_day\":{\"used_percentage\":1,\"resets_at\":$in_16h}}")
want     "fresher snapshot wins over a later resets_at" "$out" "7d 1%"
want_not "reset-away window is not rendered"           "$out" "7d 29%"
printf '{"type":"assistant","timestamp":%s,"message":{"usage":{"input_tokens":1000}}}\n' "$(iso "$((now - 172800))")" > "$TRANSCRIPT"
out=$(run "{\"seven_day\":{\"used_percentage\":29,\"resets_at\":$in_5d}}")
want     "idle session cannot bring the old window back" "$out" "7d 1%"
[ "$(cache_week)" = "1" ] && ok "cache keeps the fresher window" || bad "cache keeps the fresher window" "cache seven_day: $(cache_week)"
: > "$TRANSCRIPT"

# ------------------------------------ 7. an expired window never wins the tie-break
# Liveness must be decided BEFORE the tie-break: an expired cached 5h with a later
# taken_at beat the live one from the payload, and the slot rendered "5h —" while
# the session held live data — then flapped as sessions alternated renders.
seed "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":90,\"resets_at\":$ago_1h,\"taken_at\":$((now - 100))}}}"
printf '{"type":"assistant","timestamp":%s,"message":{"usage":{"input_tokens":1000}}}\n' "$(iso "$((now - 200))")" > "$TRANSCRIPT"
out=$(run "{\"five_hour\":{\"used_percentage\":3,\"resets_at\":$in_2h}}")
want "live window beats an expired one with a later taken_at" "$out" "5h 3%"
[ "$(cache_five)" = "3" ] && ok "cache holds the live window" || bad "cache holds the live window" "cache five_hour: $(cache_five)"

# ------------------------------------ 8. API-error assistant entries are not responses
# Claude Code appends {"type":"assistant","isApiErrorMessage":true} with an all-zero
# usage on 529s/rate-limit errors (142 transcripts on this machine carry them). Both
# transcript-derived values must skip them: depth otherwise reads 0k during the exact
# minutes the user is being throttled, and taken_at stamps a stale snapshot as fresh.
seed "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":1,\"resets_at\":$in_16h,\"taken_at\":$((now - 120))}}}"
{
  printf '{"type":"assistant","timestamp":%s,"message":{"usage":{"input_tokens":2000,"cache_read_input_tokens":150000}}}\n' "$(iso "$((now - 172800))")"
  printf '{"type":"assistant","timestamp":%s,"isApiErrorMessage":true,"message":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"iterations":null}}}\n' "$(iso "$now")"
} > "$TRANSCRIPT"
out=$(run "{\"seven_day\":{\"used_percentage\":29,\"resets_at\":$in_5d}}" '"context_window":{"total_input_tokens":152000,"context_window_size":1000000}')
want     "depth ignores the API-error entry"      "$out" "152k/848k"
want_not "depth is not read as 0k"               "$out" "0k/"
want     "taken_at ignores the API-error entry"  "$out" "7d 1%"
: > "$TRANSCRIPT"

# ------------------------------------ 9. a snapshot with no dated transcript is fresh
# A brand-new session (no assistant entry yet) still holds a snapshot from its first
# API response; dating it 0 made it lose to any cached window with a different
# resets_at, which is the reset incident replayed on every new session.
seed "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":29,\"resets_at\":$in_5d,\"taken_at\":$((now - 86400))}}}"
out=$(run "{\"seven_day\":{\"used_percentage\":1,\"resets_at\":$in_16h}}")
want "undated live snapshot wins over an older cached window" "$out" "7d 1%"

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo 'ALL PASS' || echo "$fails FAILED")"
[ "$fails" -eq 0 ]
