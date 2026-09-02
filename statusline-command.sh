#!/bin/sh
input=$(cat)

# Hard dependency: jq. Surface a single-line diagnostic instead of silently
# rendering a half-empty status line.
if ! command -v jq >/dev/null 2>&1; then
  printf 'statusline: jq not found (brew install jq / apt install jq)\n'
  exit 0
fi

# --- ANSI colors ---
RESET="$(printf '\033[0m')"
DIM="$(printf '\033[2m')"
BOLD="$(printf '\033[1m')"
GRAY="$(printf '\033[90m')"
RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
MAGENTA="$(printf '\033[35m')"
CYAN="$(printf '\033[36m')"
SEP="${DIM} · ${RESET}"

# Threshold color helper: <70% green, 70-89% yellow, >=90% red
pct_color() {
  v=$1
  if [ "$(printf '%.0f' "$v")" -ge 90 ]; then printf "%s" "$RED"
  elif [ "$(printf '%.0f' "$v")" -ge 70 ]; then printf "%s" "$YELLOW"
  else printf "%s" "$GREEN"
  fi
}

# Context colour: absolute depth, not percentage of window.
#
# On a 1M model, percentage-of-window is the wrong denominator — 400k reads as
# 40% and colours green, while measurement over 674 Opus 5 sessions puts 88% of
# all input spend above 150k and turns at 400k running 1.55x slower than the same
# session's own sub-100k baseline. Overflow is not the binding constraint; depth
# is. Bands:
#   <200k  green   nothing to do
#   200k   yellow  start looking for an exit
#   250k   orange  hand off at the next boundary — end of phase, after a commit
#   300k   red     hand off now
#
# Percentage still governs on small-window models, where 150k really is nearly
# full. Take whichever of the two reads more urgent, so neither case is wrong.
depth_color() {
  _tok=$1; _pct=$2
  _lvl=0
  [ "$_tok" -ge 200000 ] && _lvl=1
  [ "$_tok" -ge 250000 ] && _lvl=2
  [ "$_tok" -ge 300000 ] && _lvl=3
  _p=$(printf '%.0f' "$_pct")
  [ "$_p" -ge 70 ] && [ "$_lvl" -lt 1 ] && _lvl=1
  [ "$_p" -ge 85 ] && [ "$_lvl" -lt 2 ] && _lvl=2
  [ "$_p" -ge 90 ] && _lvl=3
  case "$_lvl" in
    3) printf '%s' "$RED" ;;
    2) printf '\033[38;5;208m' ;;
    1) printf '%s' "$YELLOW" ;;
    *) printf '%s' "$GREEN" ;;
  esac
}

# --- Model ---
# Strip leading "Claude " and trailing " (NM context)" suffix for compactness.
# "Claude Opus 4.7 (1M context)" -> "Opus 4.7"
model=$(echo "$input" | jq -r '.model.display_name // "Claude"' \
  | sed -E 's/^Claude //; s/ \([0-9]+[MmKk] context\)$//')

# --- Context window ---
# Resolution order:
# 0. Transcript-derived depth — max over usage.iterations. See below.
# 1. Current schema (Claude Code 2.1.x): precise counts from context_window
#    (total_input_tokens + context_window_size).
# 2. Legacy schema: absolute tokens_used + tokens_remaining.
# 3. Fall back to remaining_percentage with model-id detection.
# 4. Default 1M-context models to 1M; legacy 200k assumption otherwise.
#
# Why 0 exists and outranks 1: `context_window.total_input_tokens` SUMS the
# iterations of a multi-iteration turn. Observed live on 2026-08-13 — a 3-iteration
# turn reported 394,807 while the window actually held 198,928, a 1.98x overstatement
# that pushed the display from green into red. Across 86,800 Opus 5 turns, 4.0% are
# multi-iteration with a p50 inflation of 1.99x, and 2.4% of all turns would be
# coloured in the wrong band. The transcript carries the per-iteration breakdown, so
# depth can be computed exactly rather than inferred from an inflated total.
# Same rule as ~/.claude/hooks/context-depth-nudge.sh — the two must agree.
#
# One pass over the transcript tail yields two facts about the last REAL response:
# its depth (above) and its timestamp, `taken_at`, which the rate-limit merge uses
# to date this session's snapshot. "Real" excludes the assistant entries Claude Code
# appends on API errors ({"isApiErrorMessage":true}, model "<synthetic>", all-zero
# usage): 142 transcripts on this machine carry them, and taking them as responses
# read the depth as 0k during the very minutes the user was being throttled, and
# stamped a stale snapshot as fresh. Lines are parsed one by one (fromjson?) so a
# last line still being written cannot discard the whole window.
now=$(date +%s)
model_id=$(echo "$input" | jq -r '.model.id // ""')
transcript_p=$(echo "$input" | jq -r '.transcript_path // empty')
depth_tok=""
taken_at=""
if [ -n "$transcript_p" ] && [ -f "$transcript_p" ]; then
  set -- $(tail -n 400 "$transcript_p" 2>/dev/null | jq -Rs -r '
    [ split("\n")[] | fromjson? | select(.type == "assistant")
      | (.message.usage // null) as $u | select($u != null)
      | { t: ((.timestamp // "" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // 0),
          d: (if (($u.iterations // []) | length) > 0 then
                [ $u.iterations[]
                  | (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.input_tokens // 0)
                ] | max
              else
                ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.input_tokens // 0)
              end) }
      | select(.d > 0) ] | last
    | if . == null then empty else "\(.d) \(.t)" end
  ' 2>/dev/null)
  depth_tok=$1; taken_at=$2
  case "$depth_tok" in ''|*[!0-9]*) depth_tok="" ;; esac
  case "$taken_at" in ''|*[!0-9]*) taken_at="" ;; esac
fi
# No dated response yet (new session, unreadable transcript): the snapshot in hand
# still came from an API response just now, so it is dated now — not 0, which
# made every new session lose to whatever the cache held.
[ -n "$taken_at" ] || taken_at=$now
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
tokens_used=$(echo "$input" | jq -r '.context_window.tokens_used // empty')
tokens_remaining=$(echo "$input" | jq -r '.context_window.tokens_remaining // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

if [ -n "$depth_tok" ] && [ -n "$ctx_size" ] && [ "$ctx_size" != "null" ] && [ "$ctx_size" -gt 0 ]; then
  MAX_CONTEXT="$ctx_size"
  used_tokens="$depth_tok"
  remaining_tokens=$((ctx_size - depth_tok))
  [ "$remaining_tokens" -lt 0 ] && remaining_tokens=0
  remaining=$(awk "BEGIN { printf \"%.1f\", 100 * $remaining_tokens / $MAX_CONTEXT }")
elif [ -n "$total_input" ] && [ -n "$ctx_size" ] && [ "$total_input" != "null" ] && [ "$ctx_size" != "null" ] && [ "$ctx_size" -gt 0 ]; then
  MAX_CONTEXT="$ctx_size"
  used_tokens="$total_input"
  remaining_tokens=$((ctx_size - total_input))
  [ "$remaining_tokens" -lt 0 ] && remaining_tokens=0
  remaining=$(awk "BEGIN { printf \"%.1f\", 100 * $remaining_tokens / $MAX_CONTEXT }")
elif [ -n "$tokens_used" ] && [ -n "$tokens_remaining" ] && [ "$tokens_used" != "null" ] && [ "$tokens_remaining" != "null" ] && [ "$((tokens_used + tokens_remaining))" -gt 0 ]; then
  used_tokens="$tokens_used"
  remaining_tokens="$tokens_remaining"
  MAX_CONTEXT=$((tokens_used + tokens_remaining))
  if [ -z "$remaining" ] || [ "$remaining" = "null" ]; then
    remaining=$(awk "BEGIN { printf \"%.1f\", 100 * $tokens_remaining / $MAX_CONTEXT }")
  fi
elif [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
  case "$model_id" in
    *"[1m]"*|*"-1m"*) MAX_CONTEXT=1000000 ;;
    claude-opus-4-7*|claude-opus-4-8*) MAX_CONTEXT=1000000 ;;
    *) MAX_CONTEXT=200000 ;;
  esac
  used_tokens=$(awk "BEGIN { printf \"%.0f\", $MAX_CONTEXT * (1 - $remaining/100) }")
  remaining_tokens=$(awk "BEGIN { printf \"%.0f\", $MAX_CONTEXT * $remaining/100 }")
else
  MAX_CONTEXT=0
fi

if [ "${MAX_CONTEXT:-0}" -gt 0 ]; then
  used_fmt=$(awk "BEGIN { printf \"%.0fk\", $used_tokens/1000 }")
  remaining_fmt=$(awk "BEGIN { printf \"%.0fk\", $remaining_tokens/1000 }")
  total_fmt=$(awk "BEGIN { printf \"%.0fk\", $MAX_CONTEXT/1000 }")
  used_pct=$(awk "BEGIN { printf \"%.0f\", 100 - $remaining }")
  ctx_color=$(depth_color "$used_tokens" "$used_pct")
  # Used in urgency color (grows toward red); remaining in blue (capacity).
  ctx_display="${ctx_color}${used_fmt}${RESET}${DIM}/${RESET}${BLUE}${remaining_fmt}${RESET}"
  # Model tag: short context window label (1M, 200k, etc.)
  if [ "$MAX_CONTEXT" -ge 1000000 ]; then
    model_tag="1M"
  else
    model_tag=$(awk "BEGIN { printf \"%.0fk\", $MAX_CONTEXT/1000 }")
  fi
else
  ctx_display="${DIM}—${RESET}"
  model_tag=""
fi

# --- Settings: effort + advisor ---
# Effort now ships live in the status input (.effort.level); prefer it over the
# possibly-stale settings.json value. Advisor model still comes from settings.json.
effort=$(echo "$input" | jq -r '.effort.level // empty')
settings_file="$HOME/.claude/settings.json"
if [ -f "$settings_file" ]; then
  [ -z "$effort" ] && effort=$(jq -r '.effortLevel // "—"' "$settings_file")
  advisor=$(jq -r '.advisorModel // "—"' "$settings_file")
else
  [ -z "$effort" ] && effort="—"
  advisor="—"
fi

# --- Rate limits ---
# Epoch → formatted time; BSD date (macOS) first, GNU fallback.
fmt_epoch() {
  date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2" 2>/dev/null
}
# Seconds → compact duration: "2h05m" / "45m"
fmt_left() {
  s=$1
  [ "$s" -lt 0 ] && s=0
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"; else printf '%dm' "$m"; fi
}
# Cross-session cache. Rate limits are account-wide, but Claude Code hands each
# session ITS OWN snapshot, taken at that session's last API response — and, per
# the docs ("Fields that may be absent"), each window may be independently absent
# and a window is dropped once its resets_at passes. So an idle session carries a
# stale seven_day and no five_hour at all, and no clock says whose snapshot is
# fresher: transcript mtime moves on non-API writes too. Observed 2026-08-29 over
# five live sessions: idle ones reported 7d 38/40/42/48 with no five_hour, the
# active one 7d 63 with five_hour 29. The first design keyed freshness on mtime
# and replaced the whole snapshot, so an idle session published its partial,
# stale one over the good one and every session lost the 5h window.
#
# So the merge is decided by the data itself, per window:
#   same resets_at   -> higher used_percentage (usage is cumulative in a window)
#   resets_at <= now -> dropped; rendered as a placeholder, never as a stale %
#   different, both live -> the snapshot taken later. A natural rollover never
#     produces this case (the old window is already expired), so two live windows
#     mean the server replaced one, and resets_at ordering says nothing about
#     which is current: on 2026-09-01 an account-wide reset replaced a 7d window
#     resetting in 5 days with one resetting in 16h, and "later resets_at wins"
#     pinned the stale 29% on every session. "Taken later" is the timestamp of
#     the last real assistant entry in the session's transcript — its last API
#     response, which is when its snapshot was refreshed (computed with the
#     context depth above). Unlike the file mtime it does not move on non-API
#     writes. Stored per window as taken_at.
#   Liveness is decided BEFORE the tie-break: an expired cached window with a
#     later taken_at once beat the live one and emptied the slot ("5h —" while
#     the session held data), flapping as sessions alternated renders.
rl_cache="$HOME/.claude/rate-limits-cache.json"
mine=$(echo "$input" | jq -c --argjson t "$taken_at" \
  '.rate_limits // {} | map_values(. + {taken_at: $t})' 2>/dev/null)
[ -n "$mine" ] || mine="{}"
cached="{}"
[ -f "$rl_cache" ] && cached=$(jq -c '.rate_limits // {}' "$rl_cache" 2>/dev/null)
[ -n "$cached" ] || cached="{}"
merged=$(jq -c -n --argjson a "$cached" --argjson b "$mine" --argjson now "$now" '
  def pick(x; y):
    if x == null then y elif y == null then x
    elif y.resets_at == x.resets_at then
      (if (y.used_percentage // 0) > (x.used_percentage // 0) then y else x end)
    elif (y.taken_at // 0) > (x.taken_at // 0) then y
    elif (y.taken_at // 0) < (x.taken_at // 0) then x
    elif y.resets_at > x.resets_at then y else x end;
  def live(w): if w == null or (w.resets_at // 0) <= $now then null else w end;
  { five_hour: pick(live($a.five_hour); live($b.five_hour)),
    seven_day: pick(live($a.seven_day); live($b.seven_day)) }
  | with_entries(select(.value != null))
' 2>/dev/null)
[ -n "$merged" ] || merged="$mine"
if [ "$merged" != "$cached" ]; then
  # Atomic write: several sessions render concurrently.
  printf '{"rate_limits":%s}\n' "$merged" > "$rl_cache.tmp.$$" \
    && mv -f "$rl_cache.tmp.$$" "$rl_cache"
fi
five=$(echo "$merged" | jq -r '.five_hour.used_percentage // empty' 2>/dev/null)
five_reset=$(echo "$merged" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
week=$(echo "$merged" | jq -r '.seven_day.used_percentage // empty' 2>/dev/null)
week_reset=$(echo "$merged" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)
# Both slots always render, so the line keeps one shape: "5h —" says "no live
# data for this window", which is a different fact from a window that is missing.
if [ -n "$five" ]; then
  c=$(pct_color "$five")
  rl="${DIM}5h${RESET} ${c}$(printf '%.0f' "$five")%${RESET}"
  # Reset hour + time remaining: "↻14:30 (2h05m)"
  [ -n "$five_reset" ] && rl="$rl ${DIM}↻$(fmt_epoch "$five_reset" +%H:%M) ($(fmt_left $((five_reset - now))))${RESET}"
else
  rl="${DIM}5h —${RESET}"
fi
rl="${rl}${SEP}"
if [ -n "$week" ]; then
  c=$(pct_color "$week")
  rl="${rl}${DIM}7d${RESET} ${c}$(printf '%.0f' "$week")%${RESET}"
  # Next weekly reset as day + hour: "↻vie 09:00"
  [ -n "$week_reset" ] && rl="$rl ${DIM}↻$(fmt_epoch "$week_reset" '+%a %H:%M')${RESET}"
else
  rl="${rl}${DIM}7d —${RESET}"
fi

# --- Git: per-repo changes in workspace ---
# Detects sub-repos under the workspace root (cwd or nearest *_ws ancestor)
# and shows compact change/ahead counters per repo. Skips repos with no activity.
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
git_display=""
ws_root=""
repo_top=""
# Marker for deletable branches. Intentionally EMPTY: the first version used
# ✂ (U+2702), which carries emoji presentation and is rendered double-width by
# most terminals while the status line accounts for one cell — so the glyph
# overlapped the count. Any replacement must be narrow *and* unambiguous;
# ✱ ↑ ↓ ⎇ already in use qualify, most pictographs do not. Plain gray text
# needs no width assumption at all. Set to e.g. "~" if you want a marker back.
CLEAN_GLYPH=""

# Render one repo's status into git_display. Args: <label> <repo_path>
render_repo() {
  label=$1
  repo=$2
  # -e, not -d: in a git worktree .git is a FILE (a gitdir: pointer), not a dir.
  [ -e "$repo/.git" ] || return
  branch=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo "detached")
  changes=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  ahead=$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  behind=$(git -C "$repo" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)

  # Two branch counts against trunk (main, else master), and they answer
  # different questions:
  #   unmerged = work in flight        -> --no-merged
  #   merged   = safe to delete        -> --merged
  # Only the first existed until 2026-08-01, which meant a branch became
  # INVISIBLE at the exact moment it became deletable. Measured across 15 repos
  # that day: 7 unmerged shown, 41 merged branches sitting unseen.
  trunk=""
  if git -C "$repo" rev-parse --verify --quiet main >/dev/null 2>&1; then
    trunk=main
  elif git -C "$repo" rev-parse --verify --quiet master >/dev/null 2>&1; then
    trunk=master
  fi
  unmerged=0
  merged=0
  if [ -n "$trunk" ]; then
    unmerged=$(git -C "$repo" for-each-ref \
      --no-merged="refs/heads/$trunk" \
      --format='%(refname:short)' refs/heads/ 2>/dev/null \
      | grep -cvE "^${trunk}$" 2>/dev/null)
    [ -z "$unmerged" ] && unmerged=0
    # Exclude trunk and every branch checked out in ANY worktree — git refuses
    # to delete those ("cannot delete branch 'x' used by worktree at ..."), so
    # counting them would offer work that cannot be done. `worktree list`
    # includes the main checkout, so this also covers the current branch.
    # Verified 2026-08-01: without it a repo with one merged branch live in a
    # worktree reported 3 deletable when only 2 were.
    # Space-separated, not newline: BSD awk rejects a literal newline inside a
    # -v assignment ("awk: newline in string"), and git forbids spaces in ref
    # names, so space is a safe delimiter. Caught 2026-08-01 — the failure was
    # silent, awk errored and the count fell back to 0, i.e. it under-reported
    # in exactly the case the exclusion exists for.
    wt_branches=$(git -C "$repo" worktree list --porcelain 2>/dev/null \
      | sed -n 's#^branch refs/heads/##p' | tr '\n' ' ')
    merged=$(git -C "$repo" for-each-ref \
      --merged="refs/heads/$trunk" \
      --format='%(refname:short)' refs/heads/ 2>/dev/null \
      | awk -v trunk="$trunk" -v excl="$wt_branches" '
          BEGIN { n = split(excl, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") skip[a[i]] = 1; skip[trunk] = 1 }
          !($0 in skip) { c++ }
          END { print c + 0 }')
    case "$merged" in ''|*[!0-9]*) merged=0 ;; esac
  fi

  # Always render presence: name·branch, then counters only if >0.
  name_part="${BOLD}${label}${RESET}${DIM}(${RESET}${MAGENTA}${branch}${RESET}${DIM})${RESET}"
  entry="$name_part"
  [ "$changes" -gt 0 ] && entry="$entry ${YELLOW}${changes}✱${RESET}"
  [ "$ahead" -gt 0 ] && entry="$entry ${CYAN}↑$ahead${RESET}"
  [ "$behind" -gt 0 ] && entry="$entry ${RED}↓$behind${RESET}"
  [ "$unmerged" -gt 0 ] && entry="${entry}${SEP}${YELLOW}+${unmerged} branch$([ "$unmerged" -gt 1 ] && echo es)${RESET}"
  # Gray, not yellow: deletable branches are housekeeping, never urgency.
  [ "$merged" -gt 0 ] && entry="${entry}${SEP}${GRAY}${CLEAN_GLYPH}${merged} merged${RESET}"
  [ -n "$git_display" ] && git_display="$git_display${SEP}"
  git_display="$git_display$entry"
}

iterate_subrepos() {
  # Iterate immediate */ subdirs of $1 via glob (handles spaces/globs in names).
  # Caps at 50 subdirs to bound per-render git subprocess count.
  root=$1
  count=0
  for sub_path in "$root"/*/; do
    [ -d "$sub_path" ] || continue
    count=$((count + 1))
    [ "$count" -gt 50 ] && break
    sub=$(basename "$sub_path")
    render_repo "$sub" "$root/$sub"
  done
}

if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  search="$cwd"
  # Walk to the OUTERMOST *_ws ancestor (don't break), so a nested scratch_ws
  # inside lore_ws still resolves to lore_ws.
  while [ "$search" != "/" ] && [ "$search" != "" ]; do
    case "$(basename "$search")" in
      # *_ws-wt-<slug> is the worktree wrapper sibling of a *_ws workspace.
      *_ws|*_ws-wt-*) ws_root="$search" ;;
    esac
    parent=$(dirname "$search")
    [ "$parent" = "$search" ] && break
    search="$parent"
  done

  if [ -n "$ws_root" ]; then
    # Monorepo: workspace root is itself a git repo (.git at root, plain subdirs).
    [ -e "$ws_root/.git" ] && render_repo "$(basename "$ws_root")" "$ws_root"
    # Multi-repo: independent git repos live in immediate subdirs.
    iterate_subrepos "$ws_root"
  else
    # No workspace convention: whatever repo encloses cwd — its root, a
    # subdirectory of it, or a linked worktree (whose .git is a FILE) all
    # resolve the same way. Only when cwd is in no repo at all is it read as a
    # flat parent holding one or more */.git children.
    repo_top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$repo_top" ]; then
      render_repo "$(basename "$repo_top")" "$repo_top"
    else
      iterate_subrepos "$cwd"
    fi
  fi
fi

# --- Worktrees ---
# The roster is one path per line, from whichever source applies:
#   - workspace convention: sibling dirs "<base_ws>-wt-<slug>". One *logical*
#     worktree may span several repos (backend+frontend), so it is counted once
#     by directory, never per `git worktree list` entry — and derived from
#     names, at zero git subprocesses.
#   - any other repo: `git worktree list` of the rendered repo minus its main
#     checkout (always the first entry). Covers plain `git worktree add` and
#     Claude Code's own .claude/worktrees/<name>.
# The displayed name is the directory's basename with any "<ws>-wt-" prefix
# stripped; the entry equal to the tree this session sits in is pinned first.
WT_GLYPH="⎇"
WT_MAX=3   # names shown before collapsing the remainder into "+N"
wt_display=""
wt_paths=""
wt_cur=""
if [ -n "$ws_root" ]; then
  ws_base=$(basename "$ws_root")
  ws_parent=$(dirname "$ws_root")
  base_ws=${ws_base%%-wt-*}
  case "$ws_base" in *-wt-*) wt_cur=$ws_root ;; esac
  for wt_dir in "$ws_parent/$base_ws"-wt-*/; do
    [ -d "$wt_dir" ] || continue
    wt_paths="$wt_paths${wt_dir%/}
"
  done
elif [ -n "$repo_top" ]; then
  # One paragraph per worktree; the first is the main checkout. A worktree whose
  # directory was deleted stays listed as "prunable" until `git worktree prune`
  # and would otherwise render as "<name> —", i.e. finished — skip it.
  wt_paths=$(git -C "$repo_top" worktree list --porcelain 2>/dev/null \
    | awk 'BEGIN { RS = "" } NR > 1 {
        n = split($0, l, "\n"); keep = 1
        for (i = 2; i <= n; i++) if (l[i] ~ /^prunable/) keep = 0
        if (keep) print substr(l[1], 10) }')
  wt_cur=$repo_top   # matches an entry only when cwd is inside a linked worktree
fi

if [ -n "$wt_paths" ]; then
  # Commits + dirty files a worktree holds. The argument is either a repo
  # itself or a wrapper dir whose immediate subdirs are repos; a worktree
  # spanning backend+frontend is ONE unit, so its commits are the sum.
  # Measured 2026-08-01: 6 git calls over 3 worktrees cost 57ms, against a 60s
  # refresh — affordable, but only computed for the entries actually rendered
  # (WT_MAX), never for the ones collapsed into "+N".
  wt_stats() {
    wt_ahead=0
    wt_dirty=0
    if [ -e "$1/.git" ]; then set -- "$1"; else set -- "$1"/*/; fi
    for _s in "$@"; do
      [ -e "$_s/.git" ] || continue
      _t=main
      git -C "$_s" rev-parse --verify --quiet main >/dev/null 2>&1 || _t=master
      _a=$(git -C "$_s" rev-list --count "$_t..HEAD" 2>/dev/null || echo 0)
      case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
      _c=$(git -C "$_s" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
      wt_ahead=$((wt_ahead + _a))
      wt_dirty=$((wt_dirty + _c))
    done
  }
  # Render "<name> +N✱" — and a DIM em-dash when a worktree holds neither
  # commits nor changes, which is the signal that it is finished or abandoned.
  wt_entry() {
    wt_stats "$1"
    _name=$(basename "$1"); _name=${_name#*-wt-}
    _out="$2${_name}${RESET}"
    [ "$wt_ahead" -gt 0 ] && _out="${_out} ${CYAN}+${wt_ahead}${RESET}"
    [ "$wt_dirty" -gt 0 ] && _out="${_out} ${YELLOW}${wt_dirty}✱${RESET}"
    [ "$wt_ahead" -eq 0 ] && [ "$wt_dirty" -eq 0 ] && _out="${_out} ${DIM}—${RESET}"
    printf '%s' "$_out"
  }

  # Paths may hold spaces; split on newlines only.
  _ifs=$IFS
  IFS='
'
  wt_n=0
  wt_shown=0
  # If this session sits inside a worktree, pin it first (bold+magenta) and
  # never let WT_MAX truncate it — "which one am I in" is the whole point.
  for p in $wt_paths; do
    wt_n=$((wt_n + 1))
    if [ "$p" = "$wt_cur" ]; then
      wt_display="$(wt_entry "$p" "${BOLD}${MAGENTA}")"
      wt_shown=1
    fi
  done
  for p in $wt_paths; do
    [ "$p" = "$wt_cur" ] && continue
    [ "$wt_shown" -ge "$WT_MAX" ] && break
    wt_shown=$((wt_shown + 1))
    [ -n "$wt_display" ] && wt_display="${wt_display}${DIM}, ${RESET}"
    wt_display="${wt_display}$(wt_entry "$p" "${GRAY}")"
  done
  IFS=$_ifs
  [ "$wt_n" -gt "$wt_shown" ] && wt_display="${wt_display}${DIM}, +$((wt_n - wt_shown))${RESET}"
  wt_display="${MAGENTA}${WT_GLYPH}${RESET} ${wt_display}"
fi

# --- Render ---
# Line 1: model · used/total · effort/advisor · rate limits
# Note: Claude Code auto-appends "(1M context)" or equivalent after the model name,
# so we don't add our own context-size tag here.
model_part="${BOLD}${model}${RESET}"
cfg_part="${GRAY}${effort}/${advisor}${RESET}"
line1="${model_part}${SEP}${ctx_display}${SEP}${cfg_part}${SEP}${rl}"
printf "%s\n" "$line1"

# Line 2: git per-repo (only if there's activity)
[ -n "$git_display" ] && printf "%s" "$git_display"

# Line 3: worktrees (omitted entirely when none exist). The separator is only
# emitted when line 2 actually rendered, else we'd print a blank line.
if [ -n "$wt_display" ]; then
  [ -n "$git_display" ] && printf "\n"
  printf "%s" "$wt_display"
fi
exit 0
