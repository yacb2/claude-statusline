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

# --- Input fields ---
# One jq over the payload emitting shell assignments (@sh quotes every value),
# not one jq per field: measured 41 ms for nine calls against 6 ms for this one,
# on a render Claude Code may request every 300 ms. The model name drops the
# "Claude " prefix and any " (NM context)" suffix: "Claude Opus 4.7 (1M context)"
# -> "Opus 4.7". Defaults first, so malformed stdin degrades to placeholders.
# Every interpolation goes through `s`, which makes it ONE string: @sh expands an
# array into several quoted words, and `x='a' 'b'` would run b as a command.
model="Claude"; transcript_p=""; total_input=""; ctx_size=""; effort=""; cwd=""; rate_limits="{}"
pc_present=""; pc_warm=""; pc_exp=""; pc_cold=""; pc_misses=""
eval "$(echo "$input" | jq -r '
  def s: if type == "string" then . elif type == "number" then tostring else tojson end;
  @sh "model=\((.model.display_name // "Claude") | s | sub("^Claude "; "") | sub(" \\([0-9]+[MmKk] context\\)$"; "")) transcript_p=\(.transcript_path // "" | s) total_input=\(.context_window.total_input_tokens // "" | s) ctx_size=\(.context_window.context_window_size // "" | s) effort=\(.effort.level // "" | s) cwd=\(.workspace.project_dir // .workspace.current_dir // "" | s) rate_limits=\(.rate_limits // {} | tojson) pc_present=\(if .prompt_cache == null then "" else "1" end) pc_warm=\(.prompt_cache.warm // false | s) pc_exp=\(.prompt_cache.expires_at // "" | s) pc_cold=\(.prompt_cache.recache_tokens_if_cold // "" | s) pc_misses=\(.prompt_cache.misses // 0 | s)"
' 2>/dev/null)"

# --- Context window ---
# Depth is the transcript-derived count when the transcript is readable, else
# context_window.total_input_tokens; the window size is always
# context_window.context_window_size (docs list it as never absent). Nothing
# else: the pre-2.1 schemas once handled here cannot arrive any more.
#
# Why the transcript outranks the payload: `context_window.total_input_tokens` SUMS the
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
used_tokens=${depth_tok:-$total_input}

if [ -n "$used_tokens" ] && [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ]; then
  remaining_tokens=$((ctx_size - used_tokens))
  [ "$remaining_tokens" -lt 0 ] && remaining_tokens=0
  used_fmt=$(awk "BEGIN { printf \"%.0fk\", $used_tokens/1000 }")
  remaining_fmt=$(awk "BEGIN { printf \"%.0fk\", $remaining_tokens/1000 }")
  used_pct=$(awk "BEGIN { printf \"%.0f\", 100 * $used_tokens / $ctx_size }")
  ctx_color=$(depth_color "$used_tokens" "$used_pct")
  # Used in urgency color (grows toward red); remaining in blue (capacity).
  ctx_display="${ctx_color}${used_fmt}${RESET}${DIM}/${RESET}${BLUE}${remaining_fmt}${RESET}"
else
  ctx_display="${DIM}—${RESET}"
fi

# --- Prompt cache ---
# `prompt_cache` (Claude Code >= 2.1.251) is computed by Claude Code from the
# API's cache token counts; it appears after the first response and is absent
# before, so the element is omitted rather than shown as a placeholder. What the
# reader needs is a threshold, not a count: measured over 60 sessions on
# 2026-09-04, the TTL was 1h in 2501 turns (5m in 30); idle 5 min-1 h still hit
# 58:5, idle past 1 h missed 27:2. So: warm -> minutes until expires_at, yellow
# under 10m; cold -> the tokens the next request re-caches. Claude Code re-runs
# the script when a warm cache reaches expires_at, so the flip is not left to
# refreshInterval. A render can still land between expiry and that re-run:
# `warm` true with expires_at in the past reads cold, never a negative.
# `misses` (real misses, compaction rebuilds excluded) only shows when > 0 —
# a session invalidating its prefix every turn is worth noticing.
pc_display=""
if [ -n "$pc_present" ]; then
  pc_left=""
  case "$pc_exp" in ''|*[!0-9]*) ;; *) pc_left=$((pc_exp - now)) ;; esac
  if [ "$pc_warm" = "true" ] && [ -n "$pc_left" ] && [ "$pc_left" -gt 0 ]; then
    pc_min=$((pc_left / 60))
    if [ "$pc_left" -lt 600 ]; then c=$YELLOW; else c=$GREEN; fi
    pc_display="${c}cache ${pc_min}m${RESET}"
  else
    pc_display="${GRAY}cache cold${RESET}"
    case "$pc_cold" in
      ''|*[!0-9]*) ;;
      *) pc_display="$pc_display ${GRAY}$(awk "BEGIN { printf \"%.0fk\", $pc_cold/1000 }")${RESET}" ;;
    esac
  fi
  case "$pc_misses" in ''|*[!0-9]*|0) ;; *) pc_display="$pc_display ${RED}m${pc_misses}${RESET}" ;; esac
fi

# --- Settings: effort + advisor ---
# Effort now ships live in the status input (.effort.level); prefer it over the
# possibly-stale settings.json value. Advisor model still comes from settings.json.
settings_file="$HOME/.claude/settings.json"
effort_cfg="—"; advisor="—"
[ -f "$settings_file" ] \
  && eval "$(jq -r 'def s: if type == "string" then . else tojson end;
    @sh "effort_cfg=\(.effortLevel // "—" | s) advisor=\(.advisorModel // "—" | s)"' "$settings_file" 2>/dev/null)"
[ -n "$effort" ] || effort=$effort_cfg

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
cached="{}"
[ -f "$rl_cache" ] && cached=$(jq -c '.rate_limits // {}' "$rl_cache" 2>/dev/null)
[ -n "$cached" ] || cached="{}"
# One jq merges and emits the merged JSON plus the four rendered scalars as
# shell assignments. If it fails, merged stays as cached (nothing written) and
# the slots render as placeholders.
merged=$cached; five=""; five_reset=""; week=""; week_reset=""
eval "$(jq -r -n --argjson a "$cached" --argjson b "$rate_limits" --argjson t "$taken_at" --argjson now "$now" '
  def pick(x; y):
    if x == null then y elif y == null then x
    elif y.resets_at == x.resets_at then
      (if (y.used_percentage // 0) > (x.used_percentage // 0) then y else x end)
    elif (y.taken_at // 0) > (x.taken_at // 0) then y
    elif (y.taken_at // 0) < (x.taken_at // 0) then x
    elif y.resets_at > x.resets_at then y else x end;
  def live(w): if w == null or (w.resets_at // 0) <= $now then null else w end;
  ($b | map_values(. + {taken_at: $t})) as $b
  | { five_hour: pick(live($a.five_hour); live($b.five_hour)),
      seven_day: pick(live($a.seven_day); live($b.seven_day)) }
  | with_entries(select(.value != null))
  | def n: if type == "number" then tostring else "" end;
    @sh "merged=\(tojson) five=\(.five_hour.used_percentage | n) five_reset=\(.five_hour.resets_at | n) week=\(.seven_day.used_percentage | n) week_reset=\(.seven_day.resets_at | n)"
' 2>/dev/null)"
if [ "$merged" != "$cached" ]; then
  # Atomic write: several sessions render concurrently.
  printf '{"rate_limits":%s}\n' "$merged" > "$rl_cache.tmp.$$" \
    && mv -f "$rl_cache.tmp.$$" "$rl_cache"
fi
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
git_display=""
ws_root=""
repo_top=""

# Trunk of a repo: the branch origin/HEAD names when it exists locally, else
# main, else master; prints nothing when none exists. "main first" counted a
# repo's real master trunk as work in flight whenever a stale main was left
# behind by a half-done rename.
trunk_of() {
  _h=$(git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
  for _b in "${_h#origin/}" main master; do
    [ -n "$_b" ] || continue
    if git -C "$1" rev-parse --verify --quiet "refs/heads/$_b" >/dev/null 2>&1; then
      printf '%s' "$_b"; return
    fi
  done
}

# Render one repo's status into git_display. Args: <label> <repo_path>
render_repo() {
  label=$1
  repo=$2
  # -e, not -d: in a git worktree .git is a FILE (a gitdir: pointer), not a dir.
  [ -e "$repo/.git" ] || return
  # One `status --porcelain=v2 --branch` carries the branch, ahead/behind (only
  # when an upstream exists) and one line per change: measured 13 ms against
  # 33 ms for symbolic-ref + status|wc|tr + two rev-list per repo.
  set -- $(git -C "$repo" status --porcelain=v2 --branch 2>/dev/null | awk '
    /^# branch\.head / { b = $3 }
    /^# branch\.ab /   { a = substr($3, 2); d = substr($4, 2) }
    !/^#/              { c++ }
    END { print (b == "" || b == "(detached)" ? "detached" : b), a + 0, d + 0, c + 0 }')
  branch=${1:-detached}; ahead=${2:-0}; behind=${3:-0}; changes=${4:-0}
  # Read once here; the worktree roster below reuses it for the rendered repo.
  wt_list=$(git -C "$repo" worktree list --porcelain 2>/dev/null)

  # Two branch counts against trunk (main, else master), and they answer
  # different questions:
  #   unmerged = work in flight        -> --no-merged
  #   merged   = safe to delete        -> --merged
  # Only the first existed until 2026-08-01, which meant a branch became
  # INVISIBLE at the exact moment it became deletable. Measured across 15 repos
  # that day: 7 unmerged shown, 41 merged branches sitting unseen.
  trunk=$(trunk_of "$repo")
  unmerged=0
  merged=0
  if [ -n "$trunk" ]; then
    unmerged=$(git -C "$repo" for-each-ref \
      --no-merged="refs/heads/$trunk" \
      --format='%(refname:short)' refs/heads/ 2>/dev/null \
      | grep -cvE "^${trunk}$")
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
    wt_branches=$(printf '%s\n' "$wt_list" | sed -n 's#^branch refs/heads/##p' | tr '\n' ' ')
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
  # Gray, not yellow: deletable branches are housekeeping, never urgency. No
  # glyph: ✂ has emoji presentation and renders double-width while the status
  # line accounts for one cell, so it overlapped the count.
  [ "$merged" -gt 0 ] && entry="${entry}${SEP}${GRAY}${merged} merged${RESET}"
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
    sub=${sub_path%/}; sub=${sub##*/}
    render_repo "$sub" "$root/$sub"
  done
}

# Anchored to workspace.project_dir (the session's starting directory), NOT
# current_dir: a cd into another project or up to ~/Documents/projects would
# otherwise re-anchor the render and list every repo under that parent.
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  search="$cwd"
  # Walk to the OUTERMOST *_ws ancestor (don't break), so a nested scratch_ws
  # inside lore_ws still resolves to lore_ws.
  # Parameter expansion, not basename/dirname: 12-14 forks per render for a
  # path of ordinary depth, measured 20 ms against under 1 ms.
  while [ "$search" != "/" ] && [ "$search" != "" ]; do
    case "${search##*/}" in
      # *_ws-wt-<slug> is the worktree wrapper sibling of a *_ws workspace.
      *_ws|*_ws-wt-*) ws_root="$search" ;;
    esac
    search=${search%/*}
  done

  if [ -n "$ws_root" ]; then
    # Monorepo: workspace root is itself a git repo (.git at root, plain subdirs).
    [ -e "$ws_root/.git" ] && render_repo "${ws_root##*/}" "$ws_root"
    # Multi-repo: independent git repos live in immediate subdirs.
    iterate_subrepos "$ws_root"
  else
    # No workspace convention: whatever repo encloses cwd — its root, a
    # subdirectory of it, or a linked worktree (whose .git is a FILE) all
    # resolve the same way. Only when cwd is in no repo at all is it read as a
    # flat parent holding one or more */.git children.
    repo_top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$repo_top" ]; then
      render_repo "${repo_top##*/}" "$repo_top"
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
  ws_base=${ws_root##*/}
  ws_parent=${ws_root%/*}
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
  wt_paths=$(printf '%s\n' "$wt_list" \
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
      _t=$(trunk_of "$_s")
      _a=0
      [ -n "$_t" ] && _a=$(git -C "$_s" rev-list --count "$_t..HEAD" 2>/dev/null)
      case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
      _c=$(git -C "$_s" status --porcelain 2>/dev/null | awk 'END { print NR }')
      case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
      wt_ahead=$((wt_ahead + _a))
      wt_dirty=$((wt_dirty + _c))
    done
  }
  # Render "<name> +N✱" — and a DIM em-dash when a worktree holds neither
  # commits nor changes, which is the signal that it is finished or abandoned.
  wt_entry() {
    wt_stats "$1"
    _name=${1##*/}; _name=${_name#*-wt-}
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
# Line 1: model · used/total · prompt cache · effort/advisor · rate limits
# Note: Claude Code auto-appends "(1M context)" or equivalent after the model name,
# so we don't add our own context-size tag here.
model_part="${BOLD}${model}${RESET}"
cfg_part="${GRAY}${effort}/${advisor}${RESET}"
line1="${model_part}${SEP}${ctx_display}${SEP}${pc_display:+${pc_display}${SEP}}${cfg_part}${SEP}${rl}"
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
