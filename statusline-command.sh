#!/bin/bash
# Claude Code status line (detailed layout, ANSI colors)
# Segments, each cleanly omitted when its data is absent/null, joined with " | ":
#   1  clock time HH:MM (not from stdin)                              - bright white
#   2  model display name + ·effort + ·think, each part colored individually
#      (name/·/effort/think - see inline comment below)
#   3  current directory, abbreviated (home -> ~, collapsed with …); last
#      component bright blue, everything before it (incl. backslashes) blue
#   4  repo identity: owner cyan, "/" gray, name bright cyan
#   5  git branch: name always green; trailing "*" when dirty is its own
#      yellow token
#   6  PR: "PR#N" magenta; review state (if any) keeps its dynamic color
#      (approved green / changes_requested bright red / draft gray / other yellow)
#   7  context: "!" bright red, "ctx"/"left" gray, "N%" dynamic (>=50 green /
#      20-49 yellow / <20 bright red), "Nk" white, "/Nk" gray
#   8  session cost: "$" gray, amount dynamic (<$1 gray / $1-4 yellow / >=$5 bright red)
#   9  lines changed +added/-removed                        - "+" green / "/" uncolored / "-" red
#   10 rate limits: "5h"/"7d" label gray, "N%" dynamic per window (<50 green /
#      50-79 yellow / >=80 bright red), "→reset" gray
#   11 session name                                                  - gray
# Colors are the basic 16-color ANSI palette (30-37 / 90-97) via bash
# ANSI-C quoting ($'\e[..m'), so each variable already holds the literal
# escape byte; the final printf only ever needs %s (never %b).
# Full example:         14:32 | Fable 5·max·think | ~\proj\webapp | acme/webapp | main* | PR#42 approved | ctx 66% left 68k/200k | $0.42 | +156/-23 | 5h 37%→09:00 7d 12%→08-15 | my-session
# Low-context example:  09:15 | Fable 5 | ~\…\b\c | !ctx 12% left 176k/200k
# Minimal example:      14:32 | Fable 5 | ~

# --- color constants (basic 16-color ANSI only) ---
RESET=$'\e[0m'
GRAY=$'\e[90m'
RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
CYAN=$'\e[36m'
MAGENTA=$'\e[35m'
BLUE=$'\e[34m'
WHITE=$'\e[37m'
BLUE_BRIGHT=$'\e[94m'
CYAN_BRIGHT=$'\e[96m'
RED_BRIGHT=$'\e[91m'
MAGENTA_BRIGHT=$'\e[95m'
WHITE_BRIGHT=$'\e[97m'

input=$(cat)
jqr() { printf '%s' "$input" | jq -r "$1"; }

# 1. clock (not from stdin) - bright white
clock=$(date +%H:%M)
[ -n "$clock" ] && clock="${WHITE_BRIGHT}${clock}${RESET}"

# 2. model + effort + thinking markers, each part colored individually:
# name bright cyan, · separators gray, effort level dynamic "heat" (low gray,
# medium green, high yellow, xhigh bright magenta, max bright red, any other
# value yellow), think marker magenta. No effort -> no ·effort part; thinking
# not true -> no ·think part; model alone renders as just the cyan name.
model=$(jqr '.model.display_name // empty')
effort=$(jqr '.effort.level // empty')
thinking=$(jqr 'if .thinking.enabled == true then "think" else empty end')
model_seg=""
[ -n "$model" ] && model_seg="${CYAN_BRIGHT}${model}${RESET}"
if [ -n "$effort" ]; then
  case "$effort" in
    low) effort_color="$GRAY" ;;
    medium) effort_color="$GREEN" ;;
    high) effort_color="$YELLOW" ;;
    xhigh) effort_color="$MAGENTA_BRIGHT" ;;
    max) effort_color="$RED_BRIGHT" ;;
    *) effort_color="$YELLOW" ;;
  esac
  model_seg="${model_seg}${GRAY}·${RESET}${effort_color}${effort}${RESET}"
fi
if [ -n "$thinking" ]; then
  model_seg="${model_seg}${GRAY}·${RESET}${MAGENTA}${thinking}${RESET}"
fi

# 3. current directory, abbreviated for display (the original $dir is kept
# untouched below and reused as-is for the git commands). Split into parent
# (drive/~, any collapsed …, and all backslashes - regular blue) and the
# final component (bright blue); a single-component path is bright blue only.
dir=$(jqr '.workspace.current_dir // empty')
dir_display="$dir"
home_bs='C:\Users\Administrator'
home_fs='C:/Users/Administrator'
dir_lc="${dir_display,,}"
if [[ "$dir_lc" == "${home_bs,,}"* ]]; then
  dir_display="~${dir_display:${#home_bs}}"
elif [[ "$dir_lc" == "${home_fs,,}"* ]]; then
  dir_display="~${dir_display:${#home_fs}}"
fi
dir_display="${dir_display//\//\\}"
IFS='\' read -ra dir_comps <<< "$dir_display"
comp_count=${#dir_comps[@]}
if [ "$comp_count" -gt 3 ]; then
  dir_display="${dir_comps[0]}\\…\\${dir_comps[$((comp_count-2))]}\\${dir_comps[$((comp_count-1))]}"
fi
if [ -n "$dir_display" ]; then
  IFS='\' read -ra dir_final_comps <<< "$dir_display"
  dfc=${#dir_final_comps[@]}
  if [ "$dfc" -le 1 ]; then
    dir_display="${BLUE_BRIGHT}${dir_display}${RESET}"
  else
    dir_last="${dir_final_comps[$((dfc-1))]}"
    dir_prefix=""
    for ((di=0; di<dfc-1; di++)); do
      if [ -z "$dir_prefix" ]; then
        dir_prefix="${dir_final_comps[$di]}"
      else
        dir_prefix="${dir_prefix}\\${dir_final_comps[$di]}"
      fi
    done
    dir_display="${BLUE}${dir_prefix}\\${RESET}${BLUE_BRIGHT}${dir_last}${RESET}"
  fi
fi

# 4. repo identity: owner cyan, "/" gray, name bright cyan
repo_owner=$(jqr '.workspace.repo.owner // empty')
repo_name=$(jqr '.workspace.repo.name // empty')
repo=""
if [ -n "$repo_owner" ] && [ -n "$repo_name" ]; then
  repo="${CYAN}${repo_owner}${RESET}${GRAY}/${RESET}${CYAN_BRIGHT}${repo_name}${RESET}"
fi

# 5. git branch; uses the ORIGINAL $dir, never the abbreviated display text.
# --no-optional-locks keeps these read-only and fast; the dirty check only
# runs when we already know we're on a branch, and `head -c1` stops reading
# as soon as porcelain output proves the tree dirty.
# Branch name is always green; a dirty "*" is appended as its own yellow token.
branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)
if [ -n "$branch" ]; then
  dirty=$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null | head -c1)
  branch="${GREEN}${branch}${RESET}"
  [ -n "$dirty" ] && branch="${branch}${YELLOW}*${RESET}"
fi

# 6. PR info: "PR#N" is always magenta; the review state (when present) keeps
# its own dynamic color: approved green, changes_requested bright red, draft
# gray, pending or any other value yellow. No state -> just the magenta PR#N.
pr_number=$(jqr '.pr.number // empty')
pr_state=$(jqr '.pr.review_state // empty')
pr_seg=""
if [ -n "$pr_number" ]; then
  pr_seg="${MAGENTA}PR#${pr_number}${RESET}"
  if [ -n "$pr_state" ]; then
    case "$pr_state" in
      approved) pr_color="$GREEN" ;;
      changes_requested) pr_color="$RED_BRIGHT" ;;
      draft) pr_color="$GRAY" ;;
      *) pr_color="$YELLOW" ;;
    esac
    pr_seg="${pr_seg} ${pr_color}${pr_state}${RESET}"
  fi
fi

# 7. context: remaining % (+ used/total tokens in k, rounded to nearest 1000);
# "!" is prefixed when remaining is below 20%. remaining_int truncates the
# fractional part, which is equivalent to flooring a non-negative percentage,
# so the integer comparisons below match real-valued thresholds exactly.
# Per-part colors: "!" bright red, "ctx"/"left" gray, "N%" dynamic (>=50
# green, 20-49 yellow, <20 bright red), "Nk" white, "/Nk" (slash included) gray.
remaining=$(jqr '.context_window.remaining_percentage // empty')
in_tokens=$(jqr '.context_window.total_input_tokens // empty')
win_size=$(jqr '.context_window.context_window_size // empty')
ctx_seg=""
if [ -n "$remaining" ]; then
  remaining_int="${remaining%%.*}"
  ctx_color="$GREEN"
  ctx_warn=""
  if [[ "$remaining_int" =~ ^[0-9]+$ ]]; then
    if [ "$remaining_int" -lt 20 ]; then
      ctx_warn="1"
      ctx_color="$RED_BRIGHT"
    elif [ "$remaining_int" -lt 50 ]; then
      ctx_color="$YELLOW"
    fi
  fi
  [ -n "$ctx_warn" ] && ctx_seg="${RED_BRIGHT}!${RESET}"
  ctx_seg="${ctx_seg}${GRAY}ctx${RESET} ${ctx_color}$(printf '%.0f' "$remaining")%${RESET} ${GRAY}left${RESET}"
  if [ -n "$in_tokens" ] && [ -n "$win_size" ] && [[ "$in_tokens" =~ ^[0-9]+$ ]] && [[ "$win_size" =~ ^[0-9]+$ ]]; then
    used_k=$(( (in_tokens + 500) / 1000 ))
    total_k=$(( (win_size + 500) / 1000 ))
    ctx_seg="${ctx_seg} ${WHITE}${used_k}k${RESET}${GRAY}/${total_k}k${RESET}"
  fi
fi

# 8. session cost (USD): "$" gray, amount dynamic by integer dollars: <1
# gray, 1-4 yellow, >=5 bright red.
cost=$(jqr '.cost.total_cost_usd // empty')
cost_seg=""
if [ -n "$cost" ]; then
  cost_int="${cost%%.*}"
  cost_color="$GRAY"
  if [[ "$cost_int" =~ ^[0-9]+$ ]]; then
    if [ "$cost_int" -ge 5 ]; then
      cost_color="$RED_BRIGHT"
    elif [ "$cost_int" -ge 1 ]; then
      cost_color="$YELLOW"
    fi
  fi
  cost_amount=$(printf '%.2f' "$cost")
  cost_seg="${GRAY}\$${RESET}${cost_color}${cost_amount}${RESET}"
fi

# 9. lines changed (shown once either field is present; missing side defaults
# to 0) - "+added" green, "/" uncolored, "-removed" red.
added=$(jqr '.cost.total_lines_added // empty')
removed=$(jqr '.cost.total_lines_removed // empty')
lines_seg=""
if [ -n "$added" ] || [ -n "$removed" ]; then
  [ -z "$added" ] && added=0
  [ -z "$removed" ] && removed=0
  lines_seg="${GREEN}+${added}${RESET}/${RED}-${removed}${RESET}"
fi

# 10. rate limits (each window independently optional, each with an optional
# "->reset" suffix guarded by a numeric check before it's handed to `date`).
# Per-part colors per window: "5h"/"7d" label gray, "N%" dynamic by that
# window's own floor(used_percentage) (<50 green, 50-79 yellow, >=80 bright
# red), "→reset" gray. Windows are still joined by a plain space.
five=$(jqr '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(jqr '.rate_limits.five_hour.resets_at // empty')
week=$(jqr '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(jqr '.rate_limits.seven_day.resets_at // empty')
rl_seg=""
if [ -n "$five" ]; then
  five_int="${five%%.*}"
  five_color="$GREEN"
  if [[ "$five_int" =~ ^[0-9]+$ ]]; then
    if [ "$five_int" -ge 80 ]; then
      five_color="$RED_BRIGHT"
    elif [ "$five_int" -ge 50 ]; then
      five_color="$YELLOW"
    fi
  fi
  five_part="${GRAY}5h${RESET} ${five_color}$(printf '%.0f' "$five")%${RESET}"
  [[ "$five_reset" =~ ^[0-9]+$ ]] && five_part="${five_part}${GRAY}→$(date -d "@$five_reset" +%H:%M)${RESET}"
  rl_seg="$five_part"
fi
if [ -n "$week" ]; then
  week_int="${week%%.*}"
  week_color="$GREEN"
  if [[ "$week_int" =~ ^[0-9]+$ ]]; then
    if [ "$week_int" -ge 80 ]; then
      week_color="$RED_BRIGHT"
    elif [ "$week_int" -ge 50 ]; then
      week_color="$YELLOW"
    fi
  fi
  week_part="${GRAY}7d${RESET} ${week_color}$(printf '%.0f' "$week")%${RESET}"
  [[ "$week_reset" =~ ^[0-9]+$ ]] && week_part="${week_part}${GRAY}→$(date -d "@$week_reset" +%m-%d)${RESET}"
  if [ -n "$rl_seg" ]; then
    rl_seg="${rl_seg} ${week_part}"
  else
    rl_seg="$week_part"
  fi
fi

# 11. session name - gray
session_name=$(jqr '.session_name // empty')
[ -n "$session_name" ] && session_name="${GRAY}${session_name}${RESET}"

parts=()
[ -n "$clock" ]        && parts+=("$clock")
[ -n "$model_seg" ]    && parts+=("$model_seg")
[ -n "$dir_display" ]  && parts+=("$dir_display")
[ -n "$repo" ]         && parts+=("$repo")
[ -n "$branch" ]       && parts+=("$branch")
[ -n "$pr_seg" ]       && parts+=("$pr_seg")
[ -n "$ctx_seg" ]      && parts+=("$ctx_seg")
[ -n "$cost_seg" ]     && parts+=("$cost_seg")
[ -n "$lines_seg" ]    && parts+=("$lines_seg")
[ -n "$rl_seg" ]       && parts+=("$rl_seg")
[ -n "$session_name" ] && parts+=("$session_name")

# Separator: dim gray " | ", reset before and after it.
SEP="${RESET}${GRAY} | ${RESET}"
line=""
for part in "${parts[@]}"; do
  if [ -z "$line" ]; then
    line="$part"
  else
    line="${line}${SEP}${part}"
  fi
done

printf '%s\n' "${line}${RESET}"
