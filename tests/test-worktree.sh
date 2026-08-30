#!/bin/sh
# Regression tests for worktree handling in statusline-command.sh.
#
# Self-contained: every fixture is built here and torn down at exit, so the
# suite does not depend on which worktrees happen to exist in ~/Documents.
# (An earlier version guarded on a live echo_lab_ws worktree; tearing that
# worktree down silently skipped the whole file, including tests that need
# no git at all.)
#
# Covers:
#   1. Line 2 renders inside a worktree. Bug: render_repo gated on
#      `[ -d "$repo/.git" ]`, but a worktree's .git is a FILE. Also the
#      workspace-root walk matched only `*_ws`, never `*_ws-wt-<slug>`.
#   2. Worktrees are listed by slug; the active one (if this session is in one)
#      is bold+magenta and pinned first, the rest dim.
#   3. Past WT_MAX=3 names the remainder collapses to "+N"; the active slug is
#      never truncated even when it sorts past the cap.
#   4. No blank line is emitted when line 2 has no git activity.
#   5. A plain repo worktree as cwd (no *_ws naming, .git is a FILE) still
#      renders line 2. Bug: the top-level branch tested `[ -d "$cwd/.git" ]`
#      and fell through to the sub-repo scan, which found nothing.
#   6. No *_ws convention at all: a cwd anywhere INSIDE a repo renders that
#      repo, and the repo's linked worktrees (plain `git worktree add`, which
#      is also what Claude Code does under .claude/worktrees/) fill line 3.
#      Bug: only `$cwd/.git` was probed, so a session opened in `repo/src`
#      showed no git line, and line 3 only ever read `<name>_ws-wt-*` siblings.

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline-command.sh"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX")
trap 'rm -rf "$FIX"' EXIT INT TERM

fails=0

run() {
  printf '{"model":{"display_name":"Claude Opus 4.8","id":"claude-opus-4-8[1m]"},"workspace":{"current_dir":"%s"}}' "$1" \
    | sh "$SCRIPT"
}
plain() { run "$1" | sed 's/\x1b\[[0-9;]*m//g'; }
line()  { plain "$2" | sed -n "${1}p"; }

ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }

want() { # <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1" "expected to contain '$3', got: [$2]" ;;
  esac
}

# ---------------------------------------------------------------- fixtures
GIT="git -c user.email=t@t -c user.name=t -c init.defaultBranch=main"

# A. Real repo + real worktree, so the .git-is-a-file path is exercised.
mkdir -p "$FIX/real_ws/backend"
$GIT init -q "$FIX/real_ws/backend"
$GIT -C "$FIX/real_ws/backend" commit -q --allow-empty -m init
$GIT -C "$FIX/real_ws/backend" worktree add -q -b fix/demo-thing \
  "$FIX/real_ws-wt-demo/backend" >/dev/null 2>&1

# B. Directory-only fixture for the listing/cap logic (needs no git at all).
mkdir -p "$FIX/demo_ws"
for s in alpha beta gamma delta epsilon; do mkdir -p "$FIX/demo_ws-wt-$s"; done

# D. A plain repo (no *_ws naming) with a linked worktree, cwd = the worktree.
mkdir -p "$FIX/plain"
$GIT init -q "$FIX/plain"
$GIT -C "$FIX/plain" commit -q --allow-empty -m init
$GIT -C "$FIX/plain" worktree add -q -b feat/x "$FIX/plain-x" >/dev/null 2>&1
$GIT -C "$FIX/plain-x" commit -q --allow-empty -m one-ahead
mkdir -p "$FIX/plain/src"

# C. A workspace with no worktree siblings.
mkdir -p "$FIX/lonely_ws/backend"
$GIT init -q "$FIX/lonely_ws/backend"
$GIT -C "$FIX/lonely_ws/backend" commit -q --allow-empty -m init

# ---------------------------------------------------- 1. line 2 in a worktree
if [ -e "$FIX/real_ws-wt-demo/backend/.git" ]; then
  want "main checkout renders its repo"     "$(line 2 "$FIX/real_ws")"         "backend"
  want "worktree renders its repo"          "$(line 2 "$FIX/real_ws-wt-demo")" "backend"
  want "worktree shows its own branch"      "$(line 2 "$FIX/real_ws-wt-demo")" "fix/demo-thing"
  want "main checkout lists the worktree"   "$(line 3 "$FIX/real_ws")"         "demo"
else
  bad "worktree fixture built" "git worktree add failed"
fi

# ------------------------------------------ 2. names listed, active highlighted
# No git repos in demo_ws, so the worktree roster lands on line 2.
l2=$(line 2 "$FIX/demo_ws")
want "lists worktrees by name" "$l2" "alpha"
want "lists a second worktree" "$l2" "beta"

raw=$(run "$FIX/demo_ws-wt-alpha" | sed -n '2p')
if printf '%s' "$raw" | grep -q "$(printf '\033')\[1m$(printf '\033')\[35malpha"; then
  ok "active worktree is bold+magenta"
else
  bad "active worktree is bold+magenta" "raw: [$raw]"
fi
case "$raw" in
  *"$(printf '\033')[90mbeta"*) ok "sibling worktrees stay dim" ;;
  *) bad "sibling worktrees stay dim" "raw: [$raw]" ;;
esac

# ------------------------------------------- 3. the cap collapses the remainder
# Alphabetical order is alpha beta delta epsilon gamma, so gamma sorts 5th —
# past WT_MAX=3. As the active slug it must still appear, pinned first.
cap=$(line 2 "$FIX/demo_ws-wt-gamma")
want "active worktree survives the cap" "$cap" "gamma"
want "remainder collapses to +N"        "$cap" "+2"
case "$cap" in
  *gamma*alpha*) ok "active worktree is pinned first" ;;
  *) bad "active worktree is pinned first" "got: [$cap]" ;;
esac

# From the main checkout the cap still applies: 3 names + "+2".
cap_main=$(line 2 "$FIX/demo_ws")
want "main checkout also caps at +N" "$cap_main" "+2"

# --------------------------------------------- 4. no worktrees, no extra line
n=$(run "$FIX/lonely_ws" | wc -l | tr -d ' ')
# The last line carries no trailing newline, so a 2-line render reports 1.
if [ "$n" -le 1 ]; then
  ok "no worktrees -> no third line"
else
  bad "no worktrees -> no third line" "got $n newline(s): [$(plain "$FIX/lonely_ws")]"
fi

# With no git activity the roster must sit on line 2, not after a blank line.
if [ -n "$l2" ]; then
  ok "no blank line when line 2 has no git activity"
else
  bad "no blank line when line 2 has no git activity" "line 2 was empty"
fi

# ------------------------------ 5. plain worktree as cwd renders its repo line
want "plain worktree cwd renders its repo"   "$(line 2 "$FIX/plain-x")" "plain-x"
want "plain worktree cwd shows its branch"   "$(line 2 "$FIX/plain-x")" "feat/x"

# ------------------------ 6. no convention: nested cwd + git-native worktrees
want "nested cwd renders the enclosing repo"  "$(line 2 "$FIX/plain/src")" "plain(main)"
want "main checkout lists git worktrees"      "$(line 3 "$FIX/plain")"     "plain-x"
want "git worktree shows commits ahead"       "$(line 3 "$FIX/plain")"     "plain-x +1"
raw=$(run "$FIX/plain-x" | sed -n '3p')
if printf '%s' "$raw" | grep -q "$(printf '\033')\[1m$(printf '\033')\[35mplain-x"; then
  ok "active git worktree is bold+magenta"
else
  bad "active git worktree is bold+magenta" "raw: [$raw]"
fi

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo 'ALL PASS' || echo "$fails FAILED")"
[ "$fails" -eq 0 ]
