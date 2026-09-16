#!/bin/sh
# Regression tests for the git-line ANCHOR in statusline-command.sh.
#
# Bug: the anchor was `.workspace.current_dir`, which follows every `cd`. A
# session started in a workspace that cd'd into another project, or up to the
# flat parent holding all of them, re-anchored the render: the parent matches
# no `*_ws` name and is no git repo, so the fallback scanned its subdirs and
# line 2 listed EVERY repo in ~/Documents/projects instead of the session's.
# The anchor is now `.workspace.project_dir` (where the session started), with
# current_dir kept only as the fallback for a payload that omits it.
#
# Covers:
#   1. cwd moved to the flat parent: the session's workspace still renders,
#      and the sibling projects under that parent do not.
#   2. cwd moved into ANOTHER repo: same — the foreign repo is not rendered.
#   3. No project_dir in the payload: current_dir is still honoured.

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline-command.sh"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/statusline-anchor.XXXXXX")
trap 'rm -rf "$FIX"' EXIT INT TERM

fails=0
mkdir -p "$FIX/home/.claude"

ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }
want() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to contain '$3', got: [$2]" ;; esac; }
want_not() { case "$2" in *"$3"*) bad "$1" "expected NOT to contain '$3', got: [$2]" ;; *) ok "$1" ;; esac; }

mkrepo() { # <path>
  mkdir -p "$1" && git -C "$1" init -q
  git -C "$1" config user.email t@t && git -C "$1" config user.name t
  : > "$1/f" && git -C "$1" add f && git -C "$1" commit -qm init
}

# A flat parent holding the session's workspace and two unrelated projects.
PARENT="$FIX/projects"
mkrepo "$PARENT/mine_ws/mineapp"
mkrepo "$PARENT/other_ws/otherapp"
mkrepo "$PARENT/loose-repo"

# <current_dir> [project_dir]
run() {
  if [ -n "$2" ]; then ws=$(printf '{"current_dir":"%s","project_dir":"%s"}' "$1" "$2")
  else ws=$(printf '{"current_dir":"%s"}' "$1"); fi
  printf '{"model":{"display_name":"Claude Opus 4.8"},"workspace":%s}' "$ws" \
    | HOME="$FIX/home" sh "$SCRIPT" | sed 's/\x1b\[[0-9;]*m//g' | sed -n '2p'
}

out=$(run "$PARENT" "$PARENT/mine_ws")
want     "cd to the flat parent keeps the session workspace" "$out" "mineapp("
want_not "cd to the flat parent does not list siblings"      "$out" "loose-repo"

out=$(run "$PARENT/other_ws/otherapp" "$PARENT/mine_ws")
want     "cd into another repo keeps the session workspace" "$out" "mineapp("
want_not "cd into another repo does not render it"           "$out" "otherapp"

out=$(run "$PARENT/loose-repo")
want "no project_dir falls back to current_dir" "$out" "loose-repo"

[ "$fails" -eq 0 ] && { echo; echo "ALL PASS"; exit 0; }
echo; echo "$fails FAILED"; exit 1
