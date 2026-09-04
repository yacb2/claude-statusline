#!/bin/sh
# Regression tests for the prompt-cache element on line 1.
#
# Claude Code >= 2.1.251 hands the status line a `prompt_cache` object computed
# from the API's cache token counts (https://code.claude.com/docs/en/statusline,
# "Prompt cache fields"). Measured over 60 sessions on 2026-09-04: the TTL is 1h
# in 2501 turns against 30 at 5m; between 5 min and 1 h idle the cache still hit
# 58 times against 5 misses, past 1 h it missed 27 times against 2 hits. So the
# useful reading is a threshold — warm with the minutes left, or cold with what
# the next request re-caches — not a per-turn token count.
#
# Rendered:  "cache 42m"  warm, minutes until expires_at (yellow under 10m)
#            "cache cold 45k"  warm=false, recache_tokens_if_cold
#            "m2" appended only when misses > 0
#            nothing at all when the object is absent (before the first response)
#
# Self-contained: HOME is redirected to a fixture dir.

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline-command.sh"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/statusline-pc-test.XXXXXX")
trap 'rm -rf "$FIX"' EXIT INT TERM
mkdir -p "$FIX/.claude"

fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }
want() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to contain '$3', got: [$2]" ;; esac; }
want_not() { case "$2" in *"$3"*) bad "$1" "expected NOT to contain '$3', got: [$2]" ;; *) ok "$1" ;; esac; }

now=$(date +%s)

# Render line 1. $1 = prompt_cache JSON ("" = field absent). $2 = 1 to keep colours.
run() {
  if [ -n "$1" ]; then pc=",\"prompt_cache\":$1"; else pc=""; fi
  printf '{"model":{"display_name":"Claude Opus 4.8"},"workspace":{"current_dir":"%s"},"context_window":{"total_input_tokens":120000,"context_window_size":1000000}%s}' "$FIX" "$pc" \
    | HOME="$FIX" sh "$SCRIPT" | sed -n '1p' | { if [ "$2" = 1 ]; then cat; else sed 's/\x1b\[[0-9;]*m//g'; fi; }
}

# ------------------------------------ 1. warm: minutes until expires_at
out=$(run "{\"warm\":true,\"ttl\":\"1h\",\"expires_at\":$((now + 2550)),\"misses\":0,\"recache_tokens_if_cold\":45000}")
want     "warm shows minutes left"     "$out" "cache 42m"
want_not "no miss marker at 0 misses"  "$out" " m0"
outc=$(run "{\"warm\":true,\"ttl\":\"1h\",\"expires_at\":$((now + 2550)),\"misses\":0}" 1)
want "warm with time to spare is green" "$outc" "$(printf '\033[32m')cache 42m"

# ------------------------------------ 2. warm but about to expire: yellow
outc=$(run "{\"warm\":true,\"ttl\":\"1h\",\"expires_at\":$((now + 420)),\"misses\":0}" 1)
want "under 10m is yellow" "$outc" "$(printf '\033[33m')cache 7m"

# ------------------------------------ 3. cold: what the next request re-caches
out=$(run "{\"warm\":false,\"ttl\":\"1h\",\"expires_at\":null,\"misses\":0,\"recache_tokens_if_cold\":45000}")
want "cold shows recache size" "$out" "cache cold 45k"
out=$(run "{\"warm\":false,\"ttl\":\"1h\",\"expires_at\":null,\"misses\":0,\"recache_tokens_if_cold\":null}")
want     "cold without a size still says cold" "$out" "cache cold"
want_not "null size is not rendered"           "$out" "cold null"

# ------------------------------------ 4. misses are shown only when there are any
out=$(run "{\"warm\":true,\"ttl\":\"1h\",\"expires_at\":$((now + 2550)),\"misses\":2}")
want "misses appended" "$out" "cache 42m m2"

# ------------------------------------ 5. absent object: no element, no placeholder
out=$(run "")
want_not "nothing rendered before the first response" "$out" "cache"

# ------------------------------------ 6. expires_at already past while warm=true
# (a render between expiry and the re-run the docs promise): never a negative.
out=$(run "{\"warm\":true,\"ttl\":\"1h\",\"expires_at\":$((now - 30)),\"misses\":0}")
want_not "no negative minutes" "$out" "cache -"
want     "expired-while-warm reads cold" "$out" "cache cold"

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo 'ALL PASS' || echo "$fails FAILED")"
[ "$fails" -eq 0 ]
