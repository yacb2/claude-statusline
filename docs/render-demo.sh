#!/bin/sh
# Renders statusline-command.sh over synthetic fixtures; prints raw ANSI, one scenario per block.
# Regenerate docs/statusline.svg: sh docs/render-demo.sh | python3 docs/ansi2svg.py > docs/statusline.svg
S=$(cd "$(dirname "$0")/.." && pwd)/statusline-command.sh
FIX=$(mktemp -d); export HOME="$FIX/home"; mkdir -p "$HOME/.claude"
printf '{"advisorModel":"opus"}\n' > "$HOME/.claude/settings.json"
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
now=$(date +%s)
five=$((now + 4380)); week=$(( (now/86400+3)*86400 + 9*3600 ))
run() {
  printf '{"model":{"display_name":"Claude Opus 4.8 (1M context)","id":"claude-opus-4-8[1m]"},"workspace":{"current_dir":"%s"},"effort":{"level":"medium"},"context_window":{"total_input_tokens":%s,"context_window_size":1000000},"rate_limits":{"five_hour":{"used_percentage":29,"resets_at":%s},"seven_day":{"used_percentage":63,"resets_at":%s}}}' "$1" "$2" "$five" "$week" | sh "$S"
  printf '\n\n'
}
# A. single repo, cwd in a subdir, two worktrees via git worktree add (Claude Code style)
g init "$FIX/myapp"; g -C "$FIX/myapp" commit --allow-empty -m init
g -C "$FIX/myapp" remote add origin "$FIX/myapp"; g -C "$FIX/myapp" fetch origin
g -C "$FIX/myapp" branch -u origin/main main
g -C "$FIX/myapp" commit --allow-empty -m c1; g -C "$FIX/myapp" commit --allow-empty -m c2
mkdir -p "$FIX/myapp/src"; echo x > "$FIX/myapp/src/a.ts"; echo y > "$FIX/myapp/src/b.ts"
g -C "$FIX/myapp" worktree add -b feat/login "$FIX/myapp/.claude/worktrees/feat-login"
for i in 1 2 3; do g -C "$FIX/myapp/.claude/worktrees/feat-login" commit --allow-empty -m "w$i"; done
echo z > "$FIX/myapp/.claude/worktrees/feat-login/new.ts"
g -C "$FIX/myapp" worktree add -b fix/typo "$FIX/myapp/.claude/worktrees/fix-typo"
g -C "$FIX/myapp" branch old-merged
echo "# single repo · cwd myapp/src"; run "$FIX/myapp/src" 237000
echo "# single repo · inside the feat-login worktree"; run "$FIX/myapp/.claude/worktrees/feat-login" 88000
# B. multi-repo workspace shop_ws (backend + frontend) with two worktree siblings
for r in backend frontend; do g init "$FIX/shop_ws/$r"; g -C "$FIX/shop_ws/$r" commit --allow-empty -m init; done
echo m > "$FIX/shop_ws/backend/models.py"
g -C "$FIX/shop_ws/frontend" commit --allow-empty -m local; g -C "$FIX/shop_ws/frontend" branch spike/ssr
for r in backend frontend; do g -C "$FIX/shop_ws/$r" worktree add -b feat/checkout "$FIX/shop_ws-wt-checkout/$r"; done
g -C "$FIX/shop_ws-wt-checkout/backend" commit --allow-empty -m a; g -C "$FIX/shop_ws-wt-checkout/frontend" commit --allow-empty -m b
g -C "$FIX/shop_ws-wt-checkout/frontend" commit --allow-empty -m c; echo q > "$FIX/shop_ws-wt-checkout/frontend/x.ts"
mkdir -p "$FIX/shop_ws-wt-search"
echo "# multi-repo workspace · cwd shop_ws"; run "$FIX/shop_ws" 312000
rm -rf "$FIX"
