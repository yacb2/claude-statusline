#!/bin/sh
unset CLAUDE_CONFIG_DIR   # the suites choose their own config dir; never inherit the caller's
# Tests for the extension hook: an executable ${CLAUDE_CONFIG_DIR:-~/.claude}/statusline-extra
# the script runs once per render, before the git section.
#
# Contract:
#   - stdin is the original payload; env STATUSLINE_DIR (workspace.current_dir) and
#     STATUSLINE_TITLE (the transcript's last custom-title, whitespace collapsed, "" if none)
#   - stdout goes right after line 1, empty lines dropped, before the git and worktree lines
#   - a first line of exactly "#hide-git" is not printed and drops the git and worktree lines
#   - a missing, non-executable or failing hook changes nothing
#   - the hook is looked up in the render's own config dir only (accounts never share one)
#
# Self-contained: HOME is redirected, fixtures live in a temp dir.

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline-command.sh"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/statusline-hook.XXXXXX")
trap 'rm -rf "$FIX"' EXIT INT TERM
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

HOME_D="$FIX/home"; CFG_A="$FIX/cfg-a"; CFG_B="$FIX/cfg-b"
mkdir -p "$HOME_D/.claude" "$CFG_A" "$CFG_B"
# A repo with one worktree: the git line shows "proj(", the worktree line "wt1".
REPO="$FIX/proj"
mkdir -p "$REPO" && git -C "$REPO" init -q -b main && git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" worktree add -q "$FIX/wt1" -b side

hook() { # <config dir> <body>: install an executable hook
  printf '#!/bin/sh\n%s\n' "$2" > "$1/statusline-extra"; chmod +x "$1/statusline-extra"
}
# <config dir ("" = unset)> [transcript] -> raw output, colours stripped
render() {
  printf '{"model":{"display_name":"Claude Opus 4.8"},"session_id":"sess-9","transcript_path":"%s","workspace":{"project_dir":"%s","current_dir":"%s/sub"}}' "${2:-}" "$REPO" "$REPO" \
    | if [ -n "$1" ]; then HOME="$HOME_D" CLAUDE_CONFIG_DIR="$1" sh "$SCRIPT"
      else env -u CLAUDE_CONFIG_DIR HOME="$HOME_D" sh "$SCRIPT"; fi \
    | sed 's/\x1b\[[0-9;]*m//g'
}
lines() { printf '%s' "$1" | awk 'END { print NR }'; }
line() { printf '%s\n' "$1" | sed -n "${2}p"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to contain [$3], got [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "expected NOT to contain [$3], got [$2]" ;; *) ok "$1" ;; esac; }

# Baseline: no hook.
base=$(render "$CFG_A")
has "baseline: git line shows the repo"      "$(line "$base" 2)" "proj("
has "baseline: worktree line shows wt1"      "$(line "$base" 3)" "wt1"

# 1. A hook that is not executable is not run.
printf '#!/bin/sh\necho HOOKRAN\n' > "$CFG_A/statusline-extra"; chmod -x "$CFG_A/statusline-extra"
eq "non-executable hook: output identical to no hook" "$(render "$CFG_A")" "$base"
rm -f "$CFG_A/statusline-extra"

# 2. Hook lines come right after line 1, empty lines dropped, git and worktree after.
hook "$CFG_A" 'printf "first\n\nsecond\n\n"'
out=$(render "$CFG_A")
eq "hook lines: line 1 is untouched"             "$(line "$out" 1)" "$(line "$base" 1)"
eq "hook lines: first, then second, no blank"    "$(line "$out" 2)|$(line "$out" 3)" "first|second"
has "hook lines: git line follows the hook"      "$(line "$out" 4)" "proj("
has "hook lines: worktree line follows git"      "$(line "$out" 5)" "wt1"
eq "hook lines: nothing else (5 lines)"          "$(lines "$out")" "5"

# 3. #hide-git: not printed, git and worktree lines gone, hook lines stay.
hook "$CFG_A" 'printf "#hide-git\n\nonly\n"'
out=$(render "$CFG_A")
eq "hide-git: line 1 then the hook's line only"  "$(line "$out" 2)|$(lines "$out")" "only|2"
hasnt "hide-git: the marker is not printed"      "$out" "#hide-git"
hasnt "hide-git: no git line"                    "$out" "proj("
hasnt "hide-git: no worktree line"               "$out" "wt1"
hook "$CFG_A" 'printf "#hide-git\n"'
out=$(render "$CFG_A")
eq "hide-git alone: line 1 only"                 "$(lines "$out")" "1"

# 4. The marker is exact and only the first line counts.
hook "$CFG_A" 'printf "x\n#hide-git\n"'
out=$(render "$CFG_A")
has "marker on line 2: printed as an ordinary line" "$out" "#hide-git"
has "marker on line 2: git still shown"             "$out" "proj("
hook "$CFG_A" 'printf "#hide-gitx\n"'
out=$(render "$CFG_A")
has "marker with a suffix: printed"                 "$out" "#hide-gitx"
has "marker with a suffix: git still shown"         "$out" "proj("
hook "$CFG_A" 'printf " #hide-git\n"'
has "marker with a leading space: git still shown"  "$(render "$CFG_A")" "proj("

# The marker is the first NON-EMPTY line, a trailing CR stripped (CRLF output).
hook "$CFG_A" 'printf "\n\n#hide-git\nx\n"'
out=$(render "$CFG_A")
eq "marker after leading blank lines: hides git, prints the rest" "$(line "$out" 2)|$(lines "$out")" "x|2"
hook "$CFG_A" 'printf "#hide-git\r\nx\r\n"'
out=$(render "$CFG_A")
eq "CRLF marker: hides git, prints the rest" "$(line "$out" 2)|$(lines "$out")" "x|2"
hasnt "CRLF marker: no CR left in the output" "$out" "$(printf '\r')"

# A hook that prints only blank lines changes nothing.
hook "$CFG_A" 'printf "\n\n\r\n"'
eq "blank-only hook: output identical to no hook" "$(render "$CFG_A")" "$base"

# 5. A failing hook changes nothing, even after printing the marker.
hook "$CFG_A" 'printf "#hide-git\nlost\n"; exit 3'
eq "failing hook: output identical to no hook" "$(render "$CFG_A")" "$base"

# 6. Payload, directory and title reach the hook.
hook "$CFG_A" 'printf "dir=%s title=[%s] sid=%s\n" "$STATUSLINE_DIR" "$STATUSLINE_TITLE" "$(jq -r .session_id)"'
T="$FIX/t.jsonl"
printf '{"type":"custom-title","customTitle":"old one","sessionId":"x"}\n' > "$T"
i=0; while [ "$i" -lt 350 ]; do printf '{"type":"user","message":{"content":"l%s"}}\n' "$i" >> "$T"; i=$((i + 1)); done
printf '{"type":"custom-title","customTitle":"TASK-7   new\\ttitle","sessionId":"x"}\n{"type":"user"}\n' >> "$T"
eq "payload: dir, last title (whitespace collapsed) and stdin reach the hook" "$(line "$(render "$CFG_A" "$T")" 2)" "dir=$REPO/sub title=[TASK-7 new title] sid=sess-9"
eq "no transcript: the title is empty"        "$(line "$(render "$CFG_A" "$FIX/missing.jsonl")" 2)" "dir=$REPO/sub title=[] sid=sess-9"
printf '{"type":"user"}\n' > "$FIX/notitle.jsonl"
printf '{"type":"custom-title","customTitle":" \\t ","sessionId":"x"}\n' > "$FIX/blank.jsonl"
eq "whitespace-only title: empty"            "$(line "$(render "$CFG_A" "$FIX/blank.jsonl")" 2)" "dir=$REPO/sub title=[] sid=sess-9"
printf '{"type":"custom-title","customTitle":"  padded  title ","sessionId":"x"}\n' > "$FIX/pad.jsonl"
eq "padded title: trimmed"                   "$(line "$(render "$CFG_A" "$FIX/pad.jsonl")" 2)" "dir=$REPO/sub title=[padded title] sid=sess-9"
eq "transcript without a title: empty"       "$(line "$(render "$CFG_A" "$FIX/notitle.jsonl")" 2)" "dir=$REPO/sub title=[] sid=sess-9"

# STATUSLINE_DIR falls back to project_dir when the payload has no current_dir.
hook "$CFG_A" 'printf "dir=%s\n" "$STATUSLINE_DIR"'
eq "no current_dir: STATUSLINE_DIR is project_dir" "$(printf '{"model":{"display_name":"Claude Opus 4.8"},"workspace":{"project_dir":"%s"}}' "$REPO" | env -u CLAUDE_CONFIG_DIR HOME="$HOME_D" CLAUDE_CONFIG_DIR="$CFG_A" sh "$SCRIPT" | sed -n 2p)" "dir=$REPO"

# A worktree line with no git line above it follows the hook line directly (no blank line).
mkdir -p "$FIX/emp_ws" "$FIX/emp_ws-wt-s"
hook "$CFG_A" 'echo h'
out=$(printf '{"model":{"display_name":"Claude Opus 4.8"},"workspace":{"project_dir":"%s"}}' "$FIX/emp_ws" | env -u CLAUDE_CONFIG_DIR HOME="$HOME_D" CLAUDE_CONFIG_DIR="$CFG_A" sh "$SCRIPT" | sed 's/\x1b\[[0-9;]*m//g')
eq "worktree line without a git line: right after the hook line" "$(line "$out" 2)|$(lines "$out")" "h|3"
case "$(line "$out" 3)" in "⎇ s"*) ok "worktree line without a git line: it is the worktree line" ;; *) bad "worktree line without a git line: it is the worktree line" "got [$(line "$out" 3)]" ;; esac

# 7. Per config dir: a hook under A does not run for B; unset uses ~/.claude.
hook "$CFG_A" 'echo from-a'
eq "other config dir: hook of A does not run"  "$(render "$CFG_B")" "$base"
hasnt "config dir set: ~/.claude hook ignored" "$(hook "$HOME_D/.claude" 'echo from-home'; render "$CFG_B")" "from-home"
has "config dir unset: ~/.claude hook runs"    "$(render "")" "from-home"
has "config dir A: its own hook runs"          "$(render "$CFG_A")" "from-a"

[ "$fails" -eq 0 ] && { echo; echo "ALL PASS"; exit 0; }
echo; echo "$fails FAILED"; exit 1
