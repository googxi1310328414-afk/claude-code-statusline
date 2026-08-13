#!/bin/bash
# Force a UTF-8 locale: this environment's LANG is empty (POSIX/C locale),
# under which bash's ${#var}, ${var:0:N}, and =~ character classes are all
# BYTE-based, silently over-counting every multibyte glyph used below
# (▸ ● ✓ ✗ · █ ░ ▁-█ … ⎇ » Σ →) and throwing off column alignment. Must be
# set before any string measurement happens (i.e. before every other line
# in this script).
export LC_ALL=C.UTF-8
# Claude Code status line (detailed layout, ANSI colors, THREE printed
# lines, column-aligned)
# Reads the JSON payload once from stdin and prints up to three lines to
# stdout (Claude Code renders each printed line as its own status-line row;
# ANSI colors and OSC 8 hyperlinks work on every line). Each line is
# assembled independently - same colors/per-segment omission rules
# regardless of line - with its own trailing RESET. Line 1 always has at
# least the clock, so it always prints; lines 2 and 3 are skipped ENTIRELY
# (no blank line) when every one of their segments is absent - e.g. a
# fresh minimal session can render as just line 1 + a short line 3, with
# no line 2 at all. The " | " separators are COLUMN-ALIGNED across all
# three lines: every segment tracks a parallel plain-text twin (no ANSI,
# no OSC 8 - hyperlinks and colors are zero-width and never factor into
# alignment) purely for width measurement, measured in true terminal
# DISPLAY cells via disp_width() (not raw character count) so East Asian
# wide/fullwidth text (e.g. in session_name, or any repo/branch/worktree
# name) aligns correctly too; see disp_width()'s own comment for the
# wide-character ranges used and the render_line()/col_widths block near
# the bottom for the actual padding logic.
#
# LINE 1 (identity/location), joined with " | ":
#   1  clock time HH:MM:SS (not from stdin; only advances on refresh)  - bright white
#   2  model display name + ·effort + ·think, each part colored individually
#      (name/·/effort/think - see inline comment below)
#   3  current directory, abbreviated (home -> ~, collapsed with …); last
#      component bright blue, everything before it (incl. backslashes) blue
#   4  worktree (only in --worktree sessions): "⎇" gray + name bright blue,
#      "→"+branch (gray arrow, green branch) appended when branch is known
#   5  repo identity: owner cyan, "/" gray, name bright cyan; the whole
#      colored construct is an OSC 8 hyperlink to
#      https://<host>/<owner>/<name> (host defaults to "github.com")
#   6  git branch: name always green; trailing "*" when dirty is its own
#      yellow token
#   7  PR: "PR#N" magenta, an OSC 8 hyperlink to .pr.url when present
#      (plain text otherwise); review state (if any) stays outside the
#      link and keeps its own dynamic color (approved green /
#      changes_requested bright red / draft gray / other yellow)
#
# LINE 2 (context engine), joined with " | ":
#   8  context battery, always led by a gray "ctx" label + space (so it
#      never reads as a floating bar with no anchor), then the optional
#      "!", then the bar. PRIMARY data source is actual occupancy, not the
#      input-only remaining_percentage field - when total_input_tokens and
#      context_window_size are both present/numeric/positive, occupied =
#      total_input_tokens + total_output_tokens (0 if absent/non-numeric);
#      used% = occupied*100/window (clamped 0..100), remaining = 100-used%,
#      and this remaining drives the bar/tiers/"!"/displayed percentage;
#      the token text becomes "<occupied>/<window>" through the same
#      k-or-M formatter described below (occupancy, not input-only).
#      FALLBACK when those fields are absent but remaining_percentage is
#      present: behaves exactly as the primary path's bar/tier/"!"/
#      percentage math but driven by that percentage directly, and with no
#      token text at all. Either way: "!" bright red when remaining <20%,
#      5-cell bar (█ filled / ░ empty; filled = remaining% rounded to
#      nearest fifth) with filled cells in the same dynamic tier as "N%"
#      (>=50 green / 20-49 yellow / <20 bright red) and empty cells gray,
#      "N%" dynamic. Each of the two token numbers is formatted
#      independently by fmt_k_or_m(): "<N>k" (white) while under 1000k,
#      else "<N>M" or "<N>.<N>M" (one decimal, omitted when zero) - e.g.
#      1000000 -> "1M", 1500000 -> "1.5M" - with "/" gray between them.
#      (The total_output_tokens read here is unrelated to and unaffected
#      by the removal of the old standalone "out" segment - see below.)
#   9  token rate + sparkline, derived from ~/.claude/statusline-history.tsv
#      (see the history block below); sparkline (cyan) is up to 8
#      consecutive token deltas over the last up-to-9 samples, normalized
#      onto ▁▂▃▄▅▆▇█; rate is tokens/min over the last 5 minutes, "N/m" or
#      ">=1000/min" as "X.Yk/m", tiered <5000 gray / 5000-14999 yellow /
#      >=15000 bright red; either half, or the whole segment, may be absent
#   10 cache hit rate "cache <N>%" - gray label; N% dynamic (>=80 green /
#      50-79 yellow / <50 bright red); only when current_usage has all of
#      input/cache_creation/cache_read tokens and their sum is > 0
#
# (The standalone "out" segment, total_output_tokens shown on its own, has
# been removed entirely - variables, formatting, and its parts2+= entry.)
#
# LINE 3 (spend/quota), joined with " | ":
#   11 session cost: "$" uncolored (plain default foreground, like the "/" in
#      lines changed), amount dynamic (<$1 gray / $1-4 yellow / >=$5 bright
#      red); optionally followed by a space and a history-derived cost rate
#      "$X.Y/h" whose "$" is ALSO uncolored (bare, matching the amount's),
#      with only "X.Y/h" itself in its own dynamic color by whole
#      dollars/hour: <1 gray / 1-4 yellow / >=5 bright red
#   12 lines changed +added/-removed                        - "+" green / "/" uncolored / "-" red
#   13 rate limits: "5h"/"7d" label fixed cyan, "N%" dynamic per window (<50
#      green / 50-79 yellow / >=80 bright red), "→reset" white
#   14 session name - gray, prefixed with a "» " marker (both inside the
#      same gray span) so the AI-generated name doesn't read as a bare
#      stray system message
#
# (The "API wait share" segment has been removed entirely - variables,
# formatting, and its parts3+= entry.)
#
# Colors are the basic 16-color ANSI palette (30-37 / 90-97) via bash
# ANSI-C quoting ($'\e[..m'), so each variable already holds the literal
# escape byte; every printf only ever needs %s (never %b).
#
# Full example (three lines):
#   14:32:07 | Fable 5·max·think | ~\proj\webapp | ⎇ wt-fix→main | acme/webapp | main* | PR#42 approved
#   ctx ████░ 71% 294k/1M | ▂▅█▃ 5.6k/m | cache 82%
#   $0.42 $0.6/h | +156/-23 | 5h 37%→09:00 7d 12%→08-15 | » my-session
# Low-context example (line 2 only, illustrating the "!" warning bar):
#   ctx !█░░░░ 12% 176k/200k
# Minimal example (fresh session: line 1 + a bare line 3, no line 2 at all):
#   14:32:07 | Fable 5 | ~
#   » my-session

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

# OSC 8 terminal hyperlinks (experimental - terminals without support just
# render the plain colored text, which is fine). A link is
# OSC_OPEN + url + OSC_CLOSE + <visible text, with its own color codes
# inside as usual> + OSC_OPEN + OSC_CLOSE (an empty-URL open ends the link).
OSC_OPEN=$'\e]8;;'
OSC_CLOSE=$'\e\\'

input=$(cat)
jqr() { printf '%s' "$input" | jq -r "$1"; }

# --- history state file (used by the token-rate/sparkline and cost-rate
# sub-segments below): ~/.claude/statusline-history.tsv, TSV rows
# "epoch\tsession_id\ttokens\tcost". Skipped entirely when session_id is
# absent. A row is appended only if the last row for this session is
# missing or >=5s old, then the file is trimmed to its last 200 lines via a
# temp file + mv (tolerates races between parallel sessions - worst case a
# lost row, never corruption). All history reads tolerate/skip malformed
# lines. The derived rate/sparkline segments stay silently absent while
# history is too thin for their window - that's correct, not an error.
session_id=$(jqr '.session_id // empty')
history_file="$HOME/.claude/statusline-history.tsv"
hist_rows=""
if [ -n "$session_id" ]; then
  now_epoch=$(date +%s)
  should_append=1
  if [ -f "$history_file" ]; then
    last_hist_line=$(grep -F "$(printf '\t%s\t' "$session_id")" "$history_file" 2>/dev/null | tail -n 1)
    if [ -n "$last_hist_line" ]; then
      last_hist_epoch=$(printf '%s' "$last_hist_line" | cut -f1)
      if [[ "$last_hist_epoch" =~ ^[0-9]+$ ]]; then
        hist_age=$(( now_epoch - last_hist_epoch ))
        [ "$hist_age" -lt 5 ] && should_append=0
      fi
    fi
  fi
  if [ "$should_append" -eq 1 ]; then
    hist_in=$(jqr '.context_window.total_input_tokens // empty')
    hist_win=$(jqr '.context_window.context_window_size // empty')
    hist_out=$(jqr '.context_window.total_output_tokens // empty')
    if [[ "$hist_in" =~ ^[0-9]+$ ]] && [ "$hist_in" -gt 0 ] && [[ "$hist_win" =~ ^[0-9]+$ ]] && [ "$hist_win" -gt 0 ]; then
      hist_out_n=0
      [[ "$hist_out" =~ ^[0-9]+$ ]] && hist_out_n="$hist_out"
      hist_tokens_now=$(( hist_in + hist_out_n ))
    else
      hist_tokens_now="$hist_in"
    fi
    hist_cost_now=$(jqr '.cost.total_cost_usd // empty')
    printf '%s\t%s\t%s\t%s\n' "$now_epoch" "$session_id" "$hist_tokens_now" "$hist_cost_now" >> "$history_file" 2>/dev/null
    tail -n 200 "$history_file" > "${history_file}.tmp" 2>/dev/null && mv -f "${history_file}.tmp" "$history_file" 2>/dev/null
  fi
  hist_rows=$(awk -F'\t' -v sid="$session_id" 'NF==4 && $2==sid {print}' "$history_file" 2>/dev/null)
fi

# Windows jq/awk can emit CRLF; mapfile only strips \n, so a stray \r would
# survive on every element and fail the numeric regex guards below (the
# same class of bug found and fixed in the subagent script's sparkline
# mapfile) - tr -d '\r' defends all four of these the same way.
mapfile -t tok_epochs < <(printf '%s\n' "$hist_rows" | awk -F'\t' '$3 ~ /^[0-9]+$/ {print $1}' | tr -d '\r')
mapfile -t tok_values < <(printf '%s\n' "$hist_rows" | awk -F'\t' '$3 ~ /^[0-9]+$/ {print $3}' | tr -d '\r')
mapfile -t cost_epochs < <(printf '%s\n' "$hist_rows" | awk -F'\t' '$4 ~ /^[0-9]+(\.[0-9]+)?$/ {print $1}' | tr -d '\r')
mapfile -t cost_values < <(printf '%s\n' "$hist_rows" | awk -F'\t' '$4 ~ /^[0-9]+(\.[0-9]+)?$/ {print $4}' | tr -d '\r')

# Parses a cost string ("12", "12.5", "12.34...") to integer cents in pure
# bash: no bc/awk. Decimal part is truncated/zero-padded to exactly 2
# digits; 10#$decpart forces base-10 so a leading zero (e.g. "05") is never
# misread as octal.
cost_to_cents() {
  local c="$1"
  local intpart decpart
  intpart="${c%%.*}"
  if [[ "$c" == *.* ]]; then
    decpart="${c#*.}"
  else
    decpart=""
  fi
  [[ "$intpart" =~ ^[0-9]+$ ]] || return 1
  decpart="${decpart:0:2}"
  while [ "${#decpart}" -lt 2 ]; do
    decpart="${decpart}0"
  done
  [[ "$decpart" =~ ^[0-9]{2}$ ]] || return 1
  printf '%s' "$(( intpart * 100 + 10#$decpart ))"
}

# Formats a raw token count as "<N>k" (as before) unless that would be
# >=1000k, in which case it switches to "<N>M" / "<N>.<N>M" (one decimal,
# omitted when zero). m10 is computed directly from the raw count via a
# single division (not from the already-rounded k value) to avoid
# compounding truncation error, matching the rounding style used elsewhere
# in this script (e.g. the burn-rate segments' rate10).
fmt_k_or_m() {
  local n="$1"
  local k=$(( (n + 500) / 1000 ))
  if [ "$k" -ge 1000 ]; then
    local m10=$(( (n + 50000) / 100000 ))
    local whole=$(( m10 / 10 ))
    local frac=$(( m10 % 10 ))
    if [ "$frac" -eq 0 ]; then
      printf '%sM' "$whole"
    else
      printf '%s.%sM' "$whole" "$frac"
    fi
  else
    printf '%sk' "$k"
  fi
}

# True terminal DISPLAY width of a plain (no ANSI/OSC 8) string, in cells,
# for column-alignment math - ${#s} alone is a character count, which
# under-counts East Asian wide/fullwidth characters (2 cells each). Fast
# path: pure-ASCII strings return ${#s} directly (cheap, covers the common
# case). Otherwise walks characters (relies on LC_ALL=C.UTF-8 above so
# ${s:i:1}/${#s} are character-, not byte-, based), looks up each
# non-ASCII character's Unicode codepoint via printf's "'c" numeric-value
# extension, and adds 2 for the standard wide/fullwidth ranges, else 1.
# The glyphs this script uses on its own (▸ ● ✓ ✗ · → ⎇ Σ » █ ░ ▁-█ …) are
# all deliberately counted as 1 cell here, matching how Windows Terminal's
# default (non-East-Asian-ambiguous-wide) profile renders them - a
# terminal configured for East-Asian ambiguous-wide would need those
# bumped to 2 to match its own rendering.
disp_width() {
  local s="$1"
  if [[ "$s" != *[![:ascii:]]* ]]; then
    printf '%s' "${#s}"
    return
  fi
  local len=${#s} i c cp w total=0
  for ((i=0; i<len; i++)); do
    c="${s:i:1}"
    if [[ "$c" == [[:ascii:]] ]]; then
      total=$(( total + 1 ))
      continue
    fi
    printf -v cp '%d' "'$c"
    w=1
    if   [ "$cp" -ge 4352 ]   && [ "$cp" -le 4447 ]; then w=2    # 1100-115F
    elif [ "$cp" -ge 11904 ]  && [ "$cp" -le 12350 ]; then w=2   # 2E80-303E
    elif [ "$cp" -ge 12353 ]  && [ "$cp" -le 13311 ]; then w=2   # 3041-33FF
    elif [ "$cp" -ge 13312 ]  && [ "$cp" -le 19903 ]; then w=2   # 3400-4DBF
    elif [ "$cp" -ge 19968 ]  && [ "$cp" -le 40959 ]; then w=2   # 4E00-9FFF
    elif [ "$cp" -ge 40960 ]  && [ "$cp" -le 42191 ]; then w=2   # A000-A4CF
    elif [ "$cp" -ge 44032 ]  && [ "$cp" -le 55203 ]; then w=2   # AC00-D7A3
    elif [ "$cp" -ge 63744 ]  && [ "$cp" -le 64255 ]; then w=2   # F900-FAFF
    elif [ "$cp" -ge 65072 ]  && [ "$cp" -le 65103 ]; then w=2   # FE30-FE4F
    elif [ "$cp" -ge 65280 ]  && [ "$cp" -le 65376 ]; then w=2   # FF00-FF60
    elif [ "$cp" -ge 65504 ]  && [ "$cp" -le 65510 ]; then w=2   # FFE0-FFE6
    elif [ "$cp" -ge 127744 ] && [ "$cp" -le 129791 ]; then w=2  # 1F300-1FAFF
    elif [ "$cp" -ge 131072 ]; then w=2                          # >= 20000
    fi
    total=$(( total + w ))
  done
  printf '%s' "$total"
}

# 1. clock (not from stdin) - bright white
clock=$(date +%H:%M:%S)
clock_plain="$clock"
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
model_plain=""
if [ -n "$model" ]; then
  model_seg="${CYAN_BRIGHT}${model}${RESET}"
  model_plain="$model"
fi
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
  model_plain="${model_plain}·${effort}"
fi
if [ -n "$thinking" ]; then
  model_seg="${model_seg}${GRAY}·${RESET}${MAGENTA}${thinking}${RESET}"
  model_plain="${model_plain}·${thinking}"
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
dir_plain="$dir_display"
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

# 4. worktree - only in --worktree sessions, from .worktree.name/.branch
wt_name=$(jqr '.worktree.name // empty')
wt_branch=$(jqr '.worktree.branch // empty')
wt_seg=""
wt_plain=""
if [ -n "$wt_name" ]; then
  wt_seg="${GRAY}⎇${RESET} ${BLUE_BRIGHT}${wt_name}${RESET}"
  wt_plain="⎇ ${wt_name}"
  if [ -n "$wt_branch" ]; then
    wt_seg="${wt_seg}${GRAY}→${RESET}${GREEN}${wt_branch}${RESET}"
    wt_plain="${wt_plain}→${wt_branch}"
  fi
fi

# 5. repo identity: owner cyan, "/" gray, name bright cyan; the whole
# colored construct is wrapped in an OSC 8 hyperlink to
# https://<host>/<owner>/<name> (host defaults to github.com), unless the
# built URL fails the whitespace/ESC paranoia guard.
repo_owner=$(jqr '.workspace.repo.owner // empty')
repo_name=$(jqr '.workspace.repo.name // empty')
repo_host=$(jqr '.workspace.repo.host // "github.com"')
repo=""
repo_plain=""
if [ -n "$repo_owner" ] && [ -n "$repo_name" ]; then
  repo="${CYAN}${repo_owner}${RESET}${GRAY}/${RESET}${CYAN_BRIGHT}${repo_name}${RESET}"
  repo_plain="${repo_owner}/${repo_name}"
  repo_url="https://${repo_host}/${repo_owner}/${repo_name}"
  if [[ "$repo_url" != *[[:space:]]* ]] && [[ "$repo_url" != *$'\e'* ]]; then
    repo="${OSC_OPEN}${repo_url}${OSC_CLOSE}${repo}${OSC_OPEN}${OSC_CLOSE}"
  fi
fi

# 6. git branch; uses the ORIGINAL $dir, never the abbreviated display text.
# --no-optional-locks keeps these read-only and fast; the dirty check only
# runs when we already know we're on a branch, and `head -c1` stops reading
# as soon as porcelain output proves the tree dirty.
# Branch name is always green; a dirty "*" is appended as its own yellow token.
branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)
branch_plain=""
if [ -n "$branch" ]; then
  dirty=$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null | head -c1)
  branch_plain="$branch"
  branch="${GREEN}${branch}${RESET}"
  if [ -n "$dirty" ]; then
    branch="${branch}${YELLOW}*${RESET}"
    branch_plain="${branch_plain}*"
  fi
fi

# 7. PR info: "PR#N" is always magenta, wrapped in an OSC 8 hyperlink to
# .pr.url when that's non-empty and passes the whitespace/ESC paranoia
# guard (plain colored text otherwise); the review state (when present)
# stays OUTSIDE the link and keeps its own dynamic color: approved green,
# changes_requested bright red, draft gray, pending or any other value
# yellow. No state -> just the (possibly linked) magenta PR#N.
pr_number=$(jqr '.pr.number // empty')
pr_state=$(jqr '.pr.review_state // empty')
pr_url=$(jqr '.pr.url // empty')
pr_seg=""
pr_plain=""
if [ -n "$pr_number" ]; then
  pr_num_seg="${MAGENTA}PR#${pr_number}${RESET}"
  pr_plain="PR#${pr_number}"
  if [ -n "$pr_url" ] && [[ "$pr_url" != *[[:space:]]* ]] && [[ "$pr_url" != *$'\e'* ]]; then
    pr_num_seg="${OSC_OPEN}${pr_url}${OSC_CLOSE}${pr_num_seg}${OSC_OPEN}${OSC_CLOSE}"
  fi
  pr_seg="$pr_num_seg"
  if [ -n "$pr_state" ]; then
    case "$pr_state" in
      approved) pr_color="$GREEN" ;;
      changes_requested) pr_color="$RED_BRIGHT" ;;
      draft) pr_color="$GRAY" ;;
      *) pr_color="$YELLOW" ;;
    esac
    pr_seg="${pr_seg} ${pr_color}${pr_state}${RESET}"
    pr_plain="${pr_plain} ${pr_state}"
  fi
fi

# 8. context battery bar: [!]<bar> N% [Xk/Yk]. remaining_int truncates the
# fractional part (floor for a non-negative percentage), so the integer
# comparisons below match real-valued thresholds exactly. "!" is prefixed
# when remaining is below 20%. The bar is 5 cells; filled count is
# remaining_int rounded to the nearest fifth via integer math
# ((remaining_int + 10) / 20), clamped to 0..5. Filled cells (█, U+2588) use
# the segment's dynamic color (>=50 green, 20-49 yellow, <20 bright red);
# empty cells (░, U+2591) are gray. "N%" keeps the dynamic color; token
# counts are unchanged: "Nk" white, "/Nk" (slash included) gray.
remaining=$(jqr '.context_window.remaining_percentage // empty')
in_tokens=$(jqr '.context_window.total_input_tokens // empty')
win_size=$(jqr '.context_window.context_window_size // empty')
out_tokens_ctx=$(jqr '.context_window.total_output_tokens // empty')
ctx_seg=""
ctx_plain=""
if [[ "$in_tokens" =~ ^[0-9]+$ ]] && [ "$in_tokens" -gt 0 ] && [[ "$win_size" =~ ^[0-9]+$ ]] && [ "$win_size" -gt 0 ]; then
  # PRIMARY: actual occupancy (input + this response's output), not the
  # input-only remaining_percentage field.
  occ_out=0
  [[ "$out_tokens_ctx" =~ ^[0-9]+$ ]] && occ_out="$out_tokens_ctx"
  occupied=$(( in_tokens + occ_out ))
  used_pct=$(( occupied * 100 / win_size ))
  [ "$used_pct" -lt 0 ] && used_pct=0
  [ "$used_pct" -gt 100 ] && used_pct=100
  ctx_remaining=$(( 100 - used_pct ))
  ctx_color="$GREEN"
  ctx_warn=""
  if [ "$ctx_remaining" -lt 20 ]; then
    ctx_warn="1"
    ctx_color="$RED_BRIGHT"
  elif [ "$ctx_remaining" -lt 50 ]; then
    ctx_color="$YELLOW"
  fi
  filled=$(( (ctx_remaining + 10) / 20 ))
  [ "$filled" -lt 0 ] && filled=0
  [ "$filled" -gt 5 ] && filled=5
  bar_filled=""
  bar_empty=""
  for ((bi=0; bi<5; bi++)); do
    if [ "$bi" -lt "$filled" ]; then
      bar_filled="${bar_filled}█"
    else
      bar_empty="${bar_empty}░"
    fi
  done
  bar="${ctx_color}${bar_filled}${RESET}${GRAY}${bar_empty}${RESET}"
  ctx_seg="${GRAY}ctx${RESET} "
  ctx_plain="ctx "
  if [ -n "$ctx_warn" ]; then
    ctx_seg="${ctx_seg}${RED_BRIGHT}!${RESET}"
    ctx_plain="${ctx_plain}!"
  fi
  ctx_seg="${ctx_seg}${bar} ${ctx_color}${ctx_remaining}%${RESET}"
  ctx_plain="${ctx_plain}${bar_filled}${bar_empty} ${ctx_remaining}%"
  occ_fmt=$(fmt_k_or_m "$occupied")
  total_fmt=$(fmt_k_or_m "$win_size")
  ctx_seg="${ctx_seg} ${WHITE}${occ_fmt}${RESET}${GRAY}/${total_fmt}${RESET}"
  ctx_plain="${ctx_plain} ${occ_fmt}/${total_fmt}"
elif [ -n "$remaining" ]; then
  # FALLBACK: token fields unavailable, drive everything off the
  # (input-only) remaining_percentage field instead, no token text.
  remaining_int="${remaining%%.*}"
  ctx_color="$GREEN"
  ctx_warn=""
  filled=0
  if [[ "$remaining_int" =~ ^[0-9]+$ ]]; then
    filled=$(( (remaining_int + 10) / 20 ))
    [ "$filled" -lt 0 ] && filled=0
    [ "$filled" -gt 5 ] && filled=5
    if [ "$remaining_int" -lt 20 ]; then
      ctx_warn="1"
      ctx_color="$RED_BRIGHT"
    elif [ "$remaining_int" -lt 50 ]; then
      ctx_color="$YELLOW"
    fi
  fi
  bar_filled=""
  bar_empty=""
  for ((bi=0; bi<5; bi++)); do
    if [ "$bi" -lt "$filled" ]; then
      bar_filled="${bar_filled}█"
    else
      bar_empty="${bar_empty}░"
    fi
  done
  bar="${ctx_color}${bar_filled}${RESET}${GRAY}${bar_empty}${RESET}"
  ctx_seg="${GRAY}ctx${RESET} "
  ctx_plain="ctx "
  if [ -n "$ctx_warn" ]; then
    ctx_seg="${ctx_seg}${RED_BRIGHT}!${RESET}"
    ctx_plain="${ctx_plain}!"
  fi
  remaining_disp=$(printf '%.0f' "$remaining")
  ctx_seg="${ctx_seg}${bar} ${ctx_color}${remaining_disp}%${RESET}"
  ctx_plain="${ctx_plain}${bar_filled}${bar_empty} ${remaining_disp}%"
fi

# 9. token rate + sparkline, from the history file above (needs >=2
# history rows for this session; silently absent otherwise). Two
# independently-optional halves joined by a space when both are present.
# Sparkline: consecutive deltas (negative deltas, from a post-/compact
# reset, clamp to 0) of the tokens column over the last up-to-9 rows (up to
# 8 deltas), needs >=2 deltas, normalized min..max onto ▁▂▃▄▅▆▇█ (all-equal
# -> all ▄), cyan. Rate: newest tokens minus the oldest row within the last
# 5 minutes, divided by that span; needs span >=60s and a non-negative
# delta. >=1000/min renders as "X.Yk/m" (rate10 computed as a single more
# precise division rather than rate*10, to avoid double truncation), else
# "N/m"; tiers by the integer per-minute rate: <5000 gray, 5000-14999
# yellow, >=15000 bright red.
tok_count=${#tok_values[@]}
spark2_seg=""
spark2_plain=""
if [ "$tok_count" -ge 2 ]; then
  start_idx=$(( tok_count - 9 ))
  [ "$start_idx" -lt 0 ] && start_idx=0
  last9=()
  for ((i=start_idx; i<tok_count; i++)); do
    last9+=( "${tok_values[$i]}" )
  done
  n9=${#last9[@]}
  deltas=()
  for ((i=1; i<n9; i++)); do
    d=$(( last9[i] - last9[i-1] ))
    [ "$d" -lt 0 ] && d=0
    deltas+=( "$d" )
  done
  if [ "${#deltas[@]}" -ge 2 ]; then
    min_d=${deltas[0]}
    max_d=${deltas[0]}
    for dv in "${deltas[@]}"; do
      [ "$dv" -lt "$min_d" ] && min_d=$dv
      [ "$dv" -gt "$max_d" ] && max_d=$dv
    done
    glyph_chars2=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
    if [ "$max_d" -eq "$min_d" ]; then
      for dv in "${deltas[@]}"; do
        spark2_plain="${spark2_plain}▄"
      done
    else
      d_range=$(( max_d - min_d ))
      for dv in "${deltas[@]}"; do
        d_idx=$(( (dv - min_d) * 7 / d_range ))
        [ "$d_idx" -lt 0 ] && d_idx=0
        [ "$d_idx" -gt 7 ] && d_idx=7
        spark2_plain="${spark2_plain}${glyph_chars2[$d_idx]}"
      done
    fi
    spark2_seg="${CYAN}${spark2_plain}${RESET}"
  fi
fi

rate_seg=""
rate_plain=""
if [ "$tok_count" -ge 2 ]; then
  newest_tok=${tok_values[$((tok_count-1))]}
  newest_epoch=${tok_epochs[$((tok_count-1))]}
  tok_cutoff=$(( newest_epoch - 300 ))
  oldest_idx=-1
  for ((i=0; i<tok_count; i++)); do
    if [ "${tok_epochs[$i]}" -ge "$tok_cutoff" ]; then
      oldest_idx=$i
      break
    fi
  done
  if [ "$oldest_idx" -ge 0 ] && [ "$oldest_idx" -lt "$((tok_count-1))" ]; then
    old_tok=${tok_values[$oldest_idx]}
    old_epoch=${tok_epochs[$oldest_idx]}
    span_s=$(( newest_epoch - old_epoch ))
    delta_tok=$(( newest_tok - old_tok ))
    if [ "$span_s" -ge 60 ] && [ "$delta_tok" -ge 0 ]; then
      trate=$(( delta_tok * 60 / span_s ))
      if [ "$trate" -ge 1000 ]; then
        trate10=$(( delta_tok * 60 / (span_s * 100) ))
        rate_text="$(( trate10 / 10 )).$(( trate10 % 10 ))k/m"
      else
        rate_text="${trate}/m"
      fi
      if [ "$trate" -ge 15000 ]; then
        rate_color="$RED_BRIGHT"
      elif [ "$trate" -ge 5000 ]; then
        rate_color="$YELLOW"
      else
        rate_color="$GRAY"
      fi
      rate_seg="${rate_color}${rate_text}${RESET}"
      rate_plain="$rate_text"
    fi
  fi
fi

tokrate_seg=""
tokrate_plain=""
if [ -n "$spark2_seg" ] && [ -n "$rate_seg" ]; then
  tokrate_seg="${spark2_seg} ${rate_seg}"
  tokrate_plain="${spark2_plain} ${rate_plain}"
elif [ -n "$spark2_seg" ]; then
  tokrate_seg="$spark2_seg"
  tokrate_plain="$spark2_plain"
elif [ -n "$rate_seg" ]; then
  tokrate_seg="$rate_seg"
  tokrate_plain="$rate_plain"
fi

# 10. cache hit rate, from .context_window.current_usage (may be null or
# absent - guarded by requiring all three numeric fields).
cache_r=$(jqr '.context_window.current_usage.cache_read_input_tokens // empty')
cache_w=$(jqr '.context_window.current_usage.cache_creation_input_tokens // empty')
cache_i=$(jqr '.context_window.current_usage.input_tokens // empty')
cache_seg=""
cache_plain=""
if [[ "$cache_r" =~ ^[0-9]+$ ]] && [[ "$cache_w" =~ ^[0-9]+$ ]] && [[ "$cache_i" =~ ^[0-9]+$ ]]; then
  cache_denom=$(( cache_i + cache_w + cache_r ))
  if [ "$cache_denom" -gt 0 ]; then
    cache_hit=$(( cache_r * 100 / cache_denom ))
    if [ "$cache_hit" -ge 80 ]; then
      cache_color="$GREEN"
    elif [ "$cache_hit" -ge 50 ]; then
      cache_color="$YELLOW"
    else
      cache_color="$RED_BRIGHT"
    fi
    cache_seg="${GRAY}cache${RESET} ${cache_color}${cache_hit}%${RESET}"
    cache_plain="cache ${cache_hit}%"
  fi
fi

# 11. session cost (USD): "$" is left uncolored (plain default foreground, no
# ANSI wrap at all - same idea as the "/" in the lines-changed segment),
# amount dynamic by integer dollars: <1 gray, 1-4 yellow, >=5 bright red.
# Followed, space-separated inside the same segment, by an optional cost
# rate "$X.Y/h" from the history file (needs a same-session row with a
# non-empty cost from >=120s ago within the last hour; cost strings are
# parsed to integer cents in pure bash - see cost_to_cents above).
cost=$(jqr '.cost.total_cost_usd // empty')
cost_seg=""
cost_plain=""
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
  cost_seg="\$${cost_color}${cost_amount}${RESET}"
  cost_plain="\$${cost_amount}"

  costrate_seg=""
  costrate_plain=""
  cost_hist_count=${#cost_values[@]}
  if [ "$cost_hist_count" -ge 2 ]; then
    newest_cost=${cost_values[$((cost_hist_count-1))]}
    newest_cost_epoch=${cost_epochs[$((cost_hist_count-1))]}
    cost_cutoff=$(( newest_cost_epoch - 3600 ))
    cost_oldest_idx=-1
    for ((i=0; i<cost_hist_count; i++)); do
      if [ "${cost_epochs[$i]}" -ge "$cost_cutoff" ]; then
        cost_oldest_idx=$i
        break
      fi
    done
    if [ "$cost_oldest_idx" -ge 0 ] && [ "$cost_oldest_idx" -lt "$((cost_hist_count-1))" ]; then
      old_cost=${cost_values[$cost_oldest_idx]}
      old_cost_epoch=${cost_epochs[$cost_oldest_idx]}
      span_c=$(( newest_cost_epoch - old_cost_epoch ))
      newest_cents=$(cost_to_cents "$newest_cost" 2>/dev/null)
      old_cents=$(cost_to_cents "$old_cost" 2>/dev/null)
      if [[ "$newest_cents" =~ ^[0-9]+$ ]] && [[ "$old_cents" =~ ^[0-9]+$ ]]; then
        delta_cents=$(( newest_cents - old_cents ))
        if [ "$span_c" -ge 120 ] && [ "$delta_cents" -ge 0 ]; then
          cph=$(( delta_cents * 3600 / span_c ))
          cph_x=$(( cph / 100 ))
          cph_y=$(( (cph % 100) / 10 ))
          if [ "$cph_x" -ge 5 ]; then
            costrate_color="$RED_BRIGHT"
          elif [ "$cph_x" -ge 1 ]; then
            costrate_color="$YELLOW"
          else
            costrate_color="$GRAY"
          fi
          costrate_seg="\$${costrate_color}${cph_x}.${cph_y}/h${RESET}"
          costrate_plain="\$${cph_x}.${cph_y}/h"
        fi
      fi
    fi
  fi
  if [ -n "$costrate_seg" ]; then
    cost_seg="${cost_seg} ${costrate_seg}"
    cost_plain="${cost_plain} ${costrate_plain}"
  fi
fi

# 12. lines changed (shown once either field is present; missing side defaults
# to 0) - "+added" green, "/" uncolored, "-removed" red.
added=$(jqr '.cost.total_lines_added // empty')
removed=$(jqr '.cost.total_lines_removed // empty')
lines_seg=""
lines_plain=""
if [ -n "$added" ] || [ -n "$removed" ]; then
  [ -z "$added" ] && added=0
  [ -z "$removed" ] && removed=0
  lines_seg="${GREEN}+${added}${RESET}/${RED}-${removed}${RESET}"
  lines_plain="+${added}/-${removed}"
fi

# 13. rate limits (each window independently optional, each with an optional
# "->reset" suffix guarded by a numeric check before it's handed to `date`).
# Per-part colors per window: "5h"/"7d" label is fixed cyan; "N%" is dynamic
# by that window's own floor(used_percentage) (<50 green, 50-79 yellow, >=80
# bright red); "→reset" (arrow included) is white. Windows are still joined
# by a plain space.
five=$(jqr '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(jqr '.rate_limits.five_hour.resets_at // empty')
week=$(jqr '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(jqr '.rate_limits.seven_day.resets_at // empty')
rl_seg=""
rl_plain=""
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
  five_pct=$(printf '%.0f' "$five")
  five_part="${CYAN}5h${RESET} ${five_color}${five_pct}%${RESET}"
  five_part_plain="5h ${five_pct}%"
  if [[ "$five_reset" =~ ^[0-9]+$ ]]; then
    five_clock=$(date -d "@$five_reset" +%H:%M)
    five_part="${five_part}${WHITE}→${five_clock}${RESET}"
    five_part_plain="${five_part_plain}→${five_clock}"
  fi
  rl_seg="$five_part"
  rl_plain="$five_part_plain"
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
  week_pct=$(printf '%.0f' "$week")
  week_part="${CYAN}7d${RESET} ${week_color}${week_pct}%${RESET}"
  week_part_plain="7d ${week_pct}%"
  if [[ "$week_reset" =~ ^[0-9]+$ ]]; then
    week_clock=$(date -d "@$week_reset" +%m-%d)
    week_part="${week_part}${WHITE}→${week_clock}${RESET}"
    week_part_plain="${week_part_plain}→${week_clock}"
  fi
  if [ -n "$rl_seg" ]; then
    rl_seg="${rl_seg} ${week_part}"
    rl_plain="${rl_plain} ${week_part_plain}"
  else
    rl_seg="$week_part"
    rl_plain="$week_part_plain"
  fi
fi

# 14. session name - gray, prefixed with a "» " marker (both inside the
# same gray span) so the AI-generated name doesn't read like a bare stray
# system message at the end of the line.
session_name=$(jqr '.session_name // empty')
session_name_plain=""
if [ -n "$session_name" ]; then
  session_name_plain="» ${session_name}"
  session_name="${GRAY}» ${session_name}${RESET}"
fi

# Three thematic lines, each assembled independently - Line 1 always has
# at least the clock, so it always prints; lines 2 and 3 are skipped
# entirely (no blank line) when every one of their segments is absent -
# but the " | " separators are aligned into columns ACROSS all three
# lines: for column index i, the padding width is the widest PLAIN-TEXT
# (no ANSI/OSC 8) cell among whichever lines have a cell at i; a line's
# last cell is never padded (no trailing spaces). This uses the
# parts*_plain arrays built alongside every colored segment above (OSC 8
# sequences and color codes are never part of those plain strings, so
# hyperlinks/colors can't skew alignment). Recomputed fresh every refresh.
# Caveat: plain length is a bash CHARACTER count, not a terminal cell
# count - CJK glyphs (e.g. in session_name) occupy two terminal cells, so
# a column containing CJK text would align only approximately; none of
# this script's non-last-cell segments are expected to contain CJK text
# in practice (session_name is always the last cell on line 3 anyway, so
# it is never padded regardless).
SEP="${RESET}${GRAY} | ${RESET}"

# Line 1: identity/location
parts1=()
parts1_plain=()
[ -n "$clock" ]        && { parts1+=("$clock"); parts1_plain+=("$clock_plain"); }
[ -n "$model_seg" ]    && { parts1+=("$model_seg"); parts1_plain+=("$model_plain"); }
[ -n "$dir_display" ]  && { parts1+=("$dir_display"); parts1_plain+=("$dir_plain"); }
[ -n "$wt_seg" ]       && { parts1+=("$wt_seg"); parts1_plain+=("$wt_plain"); }
[ -n "$repo" ]         && { parts1+=("$repo"); parts1_plain+=("$repo_plain"); }
[ -n "$branch" ]       && { parts1+=("$branch"); parts1_plain+=("$branch_plain"); }
[ -n "$pr_seg" ]       && { parts1+=("$pr_seg"); parts1_plain+=("$pr_plain"); }

# Line 2: context engine
parts2=()
parts2_plain=()
[ -n "$ctx_seg" ]     && { parts2+=("$ctx_seg"); parts2_plain+=("$ctx_plain"); }
[ -n "$tokrate_seg" ] && { parts2+=("$tokrate_seg"); parts2_plain+=("$tokrate_plain"); }
[ -n "$cache_seg" ]   && { parts2+=("$cache_seg"); parts2_plain+=("$cache_plain"); }

# Line 3: spend/quota
parts3=()
parts3_plain=()
[ -n "$cost_seg" ]     && { parts3+=("$cost_seg"); parts3_plain+=("$cost_plain"); }
[ -n "$lines_seg" ]    && { parts3+=("$lines_seg"); parts3_plain+=("$lines_plain"); }
[ -n "$rl_seg" ]       && { parts3+=("$rl_seg"); parts3_plain+=("$rl_plain"); }
[ -n "$session_name" ] && { parts3+=("$session_name"); parts3_plain+=("$session_name_plain"); }

max_cols=${#parts1[@]}
[ "${#parts2[@]}" -gt "$max_cols" ] && max_cols=${#parts2[@]}
[ "${#parts3[@]}" -gt "$max_cols" ] && max_cols=${#parts3[@]}

col_widths=()
for ((ci=0; ci<max_cols; ci++)); do
  w=0
  if [ "$ci" -lt "${#parts1_plain[@]}" ]; then
    l=$(disp_width "${parts1_plain[$ci]}")
    [ "$l" -gt "$w" ] && w=$l
  fi
  if [ "$ci" -lt "${#parts2_plain[@]}" ]; then
    l=$(disp_width "${parts2_plain[$ci]}")
    [ "$l" -gt "$w" ] && w=$l
  fi
  if [ "$ci" -lt "${#parts3_plain[@]}" ]; then
    l=$(disp_width "${parts3_plain[$ci]}")
    [ "$l" -gt "$w" ] && w=$l
  fi
  col_widths+=("$w")
done

# Renders one line: $1/$2 are the NAMES of its colored/plain arrays
# (nameref, bash 4.3+). Every cell but the last is right-padded with
# spaces to col_widths[i] before the separator; the last cell is bare.
render_line() {
  local -n cparts="$1"
  local -n pparts="$2"
  local n=${#cparts[@]}
  local out="" ci cell plen w pad padding
  for ((ci=0; ci<n; ci++)); do
    cell="${cparts[$ci]}"
    if [ "$ci" -lt "$((n-1))" ]; then
      plen=$(disp_width "${pparts[$ci]}")
      w="${col_widths[$ci]}"
      pad=$(( w - plen ))
      padding=""
      [ "$pad" -gt 0 ] && padding=$(printf '%*s' "$pad" '')
      out="${out}${cell}${padding}${SEP}"
    else
      out="${out}${cell}"
    fi
  done
  printf '%s' "$out"
}

line1=$(render_line parts1 parts1_plain)
line2=$(render_line parts2 parts2_plain)
line3=$(render_line parts3 parts3_plain)

printf '%s\n' "${line1}${RESET}"
[ -n "$line2" ] && printf '%s\n' "${line2}${RESET}"
[ -n "$line3" ] && printf '%s\n' "${line3}${RESET}"
