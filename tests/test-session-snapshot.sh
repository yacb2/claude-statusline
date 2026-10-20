#!/bin/sh
# Regression tests for the per-session snapshot the status line writes.
#
# Each render writes ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline-sessions/<sid>.json
# so another process (the command_center core) can read a session's real context
# window and prompt-cache state. Contract:
#   { "session_id": str, "written_at": ISO-8601 UTC, "context_window_size": number,
#     "prompt_cache": null | { "warm": bool, "expires_at": str,
#                              "recache_tokens_if_cold": number, "misses": number } }
#   sid is only [0-9A-Za-z-]; anything else writes nothing. The id comes from
#   `session_id`, else from the transcript_path basename without ".jsonl".
#   Written atomically (tmp + mv); nothing is written without a sid and a window.
#
# Self-contained: HOME is redirected to a fixture dir.

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline-command.sh"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/statusline-snap-test.XXXXXX")
trap 'rm -rf "$FIX"' EXIT INT TERM
mkdir -p "$FIX/.claude"
SNAP="$FIX/.claude/statusline-sessions"

fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

# Render with payload $1 into the redirected HOME; the output is not under test.
render() { printf '%s' "$1" | HOME="$FIX" sh "$SCRIPT" >/dev/null 2>&1; }
# Payload builder: $1 = extra top-level JSON members (leading comma included).
payload() {
  printf '{"model":{"display_name":"Claude Opus 4.8"},"workspace":{"current_dir":"%s"},"context_window":{"total_input_tokens":120000,"context_window_size":1000000}%s}' "$FIX" "$1"
}
fresh() { rm -rf "$SNAP"; }
files() { ls -A "$SNAP" 2>/dev/null | tr '\n' ' '; }

# ------------------------------------ 1. fields written
fresh
render "$(payload ',"session_id":"abc-123","prompt_cache":{"warm":true,"ttl":"1h","expires_at":1788513844,"misses":2,"recache_tokens_if_cold":45000}')"
f="$SNAP/abc-123.json"
eq "file is named by the session id"  "$(files)" "abc-123.json "
eq "session_id"                        "$(jq -r .session_id "$f")" "abc-123"
eq "context_window_size is a number"   "$(jq -r '.context_window_size|type' "$f")" "number"
eq "context_window_size value"         "$(jq -r .context_window_size "$f")" "1000000"
eq "written_at is ISO UTC"             "$(jq -r '.written_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$f")" "true"
eq "written_at is now"                 "$(jq -r '(.written_at | fromdateiso8601) - now | fabs < 30' "$f")" "true"
eq "prompt_cache.warm"                 "$(jq -r .prompt_cache.warm "$f")" "true"
eq "prompt_cache.expires_at is ISO"    "$(jq -r .prompt_cache.expires_at "$f")" "2026-09-04T09:24:04Z"
eq "prompt_cache.recache_tokens_if_cold" "$(jq -r .prompt_cache.recache_tokens_if_cold "$f")" "45000"
eq "prompt_cache.misses"               "$(jq -r .prompt_cache.misses "$f")" "2"

# ------------------------------------ 2. cold cache: warm false, no expiry
fresh
render "$(payload ',"session_id":"cold1","prompt_cache":{"warm":false,"ttl":"1h","expires_at":null,"misses":0,"recache_tokens_if_cold":45000}')"
eq "cold: warm is false"       "$(jq -r .prompt_cache.warm "$SNAP/cold1.json")" "false"
eq "cold: expires_at stays a string" "$(jq -r '.prompt_cache.expires_at|type' "$SNAP/cold1.json")" "string"

# ------------------------------------ 3. prompt_cache absent gives null
fresh
render "$(payload ',"session_id":"nocache"')"
eq "absent prompt_cache is null" "$(jq -c .prompt_cache "$SNAP/nocache.json")" "null"

# ------------------------------------ 4. sid validation: refused vs accepted
for bad_sid in 'a/b' '../x' '..' 'a.b' 'a b' 'a_b' 'é'; do
  fresh; rm -f "$FIX/.claude/x.json" "$FIX/x.json"
  mkdir -p "$SNAP/a"   # so 'a/b' could be written if the guard were gone
  render "$(payload ",\"session_id\":\"$bad_sid\"")"
  # Checked right after the render, over the whole fixture: a traversal sid
  # writes outside $SNAP, where files() cannot see it.
  eq "sid [$bad_sid] writes nothing anywhere" "$(find "$FIX" -name '*.json*' ! -path "$FIX/proj/*")" ""
done
for good_sid in 'ABC' 'a-1' '0' '8568b9dc-e29a-4f61-a204-a17277cc3f31'; do
  fresh
  render "$(payload ",\"session_id\":\"$good_sid\"")"
  eq "sid [$good_sid] is written" "$(files)" "$good_sid.json "
done

# ------------------------------------ 5. nothing to say: no sid, or no window
fresh
render "$(payload '')"
eq "no sid and no transcript writes nothing" "$(files)" ""
eq "no sid does not even create the dir"      "$([ -d "$SNAP" ] && echo yes || echo no)" "no"
fresh
render '{"session_id":"nowin","model":{"display_name":"Claude Opus 4.8"},"workspace":{"current_dir":"/nonexistent"}}'
eq "sid without a window writes nothing" "$(files)" ""

# window must be a positive integer (the reader divides by it)
for bad_win in 0 00 -5 1.5 '"x"'; do
  fresh
  render "{\"session_id\":\"win\",\"model\":{\"display_name\":\"Claude Opus 4.8\"},\"context_window\":{\"context_window_size\":$bad_win}}"
  eq "window [$bad_win] writes nothing" "$(find "$FIX" -name '*.json*' ! -path "$FIX/proj/*")" ""
done

# expires_at out of range must not blank the render nor leak a bogus date
for exp in 1e20 1788513844000 -1 100000000000; do
  fresh
  out=$(payload ",\"session_id\":\"exp\",\"prompt_cache\":{\"warm\":true,\"expires_at\":$exp,\"misses\":0,\"recache_tokens_if_cold\":1}" | HOME="$FIX" sh "$SCRIPT" 2>/dev/null)
  case "$out" in *"Opus 4.8"*) ok "expires_at [$exp]: render keeps the model name" ;; *) bad "expires_at [$exp]: render keeps the model name" "got [$out]" ;; esac
  eq "expires_at [$exp] is an empty string in a written file" "$(jq -r '.prompt_cache.expires_at | type + ":" + .' "$SNAP/exp.json")" "string:"
done

# the last accepted second just below the 1e11 bound still converts
fresh
payload ",\"session_id\":\"exp\",\"prompt_cache\":{\"warm\":true,\"expires_at\":99999999999,\"misses\":0,\"recache_tokens_if_cold\":1}" | HOME="$FIX" sh "$SCRIPT" >/dev/null 2>&1
eq "expires_at [99999999999] converts" "$(jq -r .prompt_cache.expires_at "$SNAP/exp.json")" "5138-11-16T09:46:39Z"

# ------------------------------------ 6. fallback: transcript basename
fresh
render "$(payload ",\"transcript_path\":\"$FIX/proj/8568b9dc-e29a.jsonl\"")"
eq "no session_id: transcript basename names the file" "$(files)" "8568b9dc-e29a.json "
eq "no session_id: session_id field matches"  "$(jq -r .session_id "$SNAP/8568b9dc-e29a.json")" "8568b9dc-e29a"
fresh
render "$(payload ",\"session_id\":\"real\",\"transcript_path\":\"$FIX/proj/other.jsonl\"")"
eq "session_id outranks the transcript basename" "$(files)" "real.json "

# ------------------------------------ 7. atomic: no tmp file left, rewrite replaces
fresh
render "$(payload ',"session_id":"atom"')"
render "$(payload ',"session_id":"atom"')"
eq "no .tmp file is left behind" "$(ls -A "$SNAP")" "atom.json"

# ------------------------------------ 8. the account's own config dir
fresh
mkdir -p "$FIX/work"
payload ',"session_id":"acct"' | HOME="$FIX" CLAUDE_CONFIG_DIR="$FIX/work" sh "$SCRIPT" >/dev/null 2>&1
eq "CLAUDE_CONFIG_DIR gets the file"  "$(ls "$FIX/work/statusline-sessions" 2>/dev/null)" "acct.json"
eq "the default dir stays empty"      "$(files)" ""

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo 'ALL PASS' || echo "$fails FAILED")"
[ "$fails" -eq 0 ]
