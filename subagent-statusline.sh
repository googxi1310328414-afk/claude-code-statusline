#!/bin/bash
# Claude Code SUBAGENT status line
#
# Contract (differs from the main statusLine!): stdin is ONE JSON object per
# refresh covering ALL rows: {"columns": <number>, "tasks": [{...}, ...]}.
# For each element of .tasks[] this script emits ONE compact JSON line to
# stdout: {"id": "<task.id>", "content": "<ANSI row string>"}. Tasks without
# an id produce no line. An empty/absent tasks array produces no output.
#
# Per-task fields consumed: id, name, type, status, description, label,
# startTime (unix seconds or milliseconds), tokenCount, contextWindowSize,
# effort. (cwd and model are part of the contract but unused here - no model
# is shown on agent rows, deliberately different from the main statusline.)
#
# Row segments, each cleanly omitted when its data is absent, joined with
# the same gray " | " separator as the main script:
#   1  "▸ " (gray) + identity - first non-empty of name/label/type - in
#      BRIGHT MAGENTA (deliberately different from the main statusline's
#      bright-cyan identity, so agent rows are instantly distinguishable);
#      identity absent -> whole segment omitted. Only when .effort is
#      present (an explicit per-agent override; its absence means the agent
#      inherits the session effort) a gray "·" + the effort value is
#      appended, heat-colored the same as the main script (low gray /
#      medium green / high yellow / xhigh bright magenta / max bright red /
#      anything else incl. numeric budgets yellow)
#   2  status: running/in_progress green, pending/queued/starting yellow,
#      failed/error/cancelled/killed bright red, completed/done/finished
#      gray, anything else yellow
#   3  context battery - only when tokenCount + contextWindowSize are both
#      present, numeric, and contextWindowSize > 0. Same bar math as the
#      main script's ctx segment: 5-cell bar, "!" + bright red when
#      remaining <20%, "Nk" white, "/Nk" gray
#   4  elapsed since startTime - white; values > 1e12 are treated as
#      milliseconds; "Nm" under 1h else "XhYm"
#   5  description - gray, width-budgeted against `columns` (default 120):
#      budget = columns - (plain width of segments 1-4 incl. separators,
#      "▸ " included) - 3; omitted if budget < 8, else cut to budget-1
#      chars + "…" when longer than budget
#
# Example row content (id omitted here):
#   ▸ code-reviewer·max | running | ███░░ 66% 68k/200k | 3m | Review auth module for…
#
# Colors are the basic 16-color ANSI palette via bash ANSI-C quoting
# ($'\e[..m'); output is always plain %s - jq's -cn/--arg handles JSON
# escaping of the embedded ANSI bytes.

input=$(cat)

RESET=$'\e[0m'
GRAY=$'\e[90m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
WHITE=$'\e[37m'
RED_BRIGHT=$'\e[91m'
MAGENTA_BRIGHT=$'\e[95m'
SEP="${RESET}${GRAY} | ${RESET}"

columns=$(printf '%s' "$input" | jq -r '.columns // empty')
[[ "$columns" =~ ^[0-9]+$ ]] || columns=120

tjq() { printf '%s' "$task" | jq -r "$1"; }

printf '%s' "$input" | jq -c '.tasks[]?' | while IFS= read -r task; do
  id=$(tjq '.id // empty')
  [ -z "$id" ] && continue

  # 1. "▸ " (gray) + identity (bright magenta) + optional "·effort" (gray
  # dot, heat-colored effort). Identity absent -> whole segment omitted.
  identity_plain=$(tjq 'if (.name != null and .name != "") then .name elif (.label != null and .label != "") then .label elif (.type != null and .type != "") then .type else empty end')
  effort=$(tjq '.effort // empty')
  seg1_plain=""
  seg1=""
  if [ -n "$identity_plain" ]; then
    seg1_plain="▸ ${identity_plain}"
    seg1="${GRAY}▸ ${RESET}${MAGENTA_BRIGHT}${identity_plain}${RESET}"
    if [ -n "$effort" ]; then
      case "$effort" in
        low) effort_color="$GRAY" ;;
        medium) effort_color="$GREEN" ;;
        high) effort_color="$YELLOW" ;;
        xhigh) effort_color="$MAGENTA_BRIGHT" ;;
        max) effort_color="$RED_BRIGHT" ;;
        *) effort_color="$YELLOW" ;;
      esac
      seg1_plain="${seg1_plain}·${effort}"
      seg1="${seg1}${GRAY}·${RESET}${effort_color}${effort}${RESET}"
    fi
  fi

  # 2. status
  status=$(tjq '.status // empty')
  status_seg=""
  if [ -n "$status" ]; then
    case "$status" in
      running|in_progress) status_color="$GREEN" ;;
      pending|queued|starting) status_color="$YELLOW" ;;
      failed|error|cancelled|killed) status_color="$RED_BRIGHT" ;;
      completed|done|finished) status_color="$GRAY" ;;
      *) status_color="$YELLOW" ;;
    esac
    status_seg="${status_color}${status}${RESET}"
  fi

  # 3. context battery - only when both fields are present/numeric/positive;
  # identical bar math to the main script's ctx segment.
  token_count=$(tjq '.tokenCount // empty')
  ctx_window_size=$(tjq '.contextWindowSize // empty')
  ctx_seg=""
  ctx_plain=""
  if [ -n "$token_count" ] && [ -n "$ctx_window_size" ] && [[ "$token_count" =~ ^[0-9]+$ ]] && [[ "$ctx_window_size" =~ ^[0-9]+$ ]] && [ "$ctx_window_size" -gt 0 ]; then
    used_pct=$(( token_count * 100 / ctx_window_size ))
    [ "$used_pct" -lt 0 ] && used_pct=0
    [ "$used_pct" -gt 100 ] && used_pct=100
    remaining=$(( 100 - used_pct ))
    ctx_color="$GREEN"
    ctx_warn=""
    if [ "$remaining" -lt 20 ]; then
      ctx_warn="1"
      ctx_color="$RED_BRIGHT"
    elif [ "$remaining" -lt 50 ]; then
      ctx_color="$YELLOW"
    fi
    filled=$(( (remaining + 10) / 20 ))
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
    used_k=$(( (token_count + 500) / 1000 ))
    total_k=$(( (ctx_window_size + 500) / 1000 ))
    warn_plain=""
    [ -n "$ctx_warn" ] && warn_plain="!"
    [ -n "$ctx_warn" ] && ctx_seg="${RED_BRIGHT}!${RESET}"
    ctx_seg="${ctx_seg}${bar} ${ctx_color}${remaining}%${RESET} ${WHITE}${used_k}k${RESET}${GRAY}/${total_k}k${RESET}"
    ctx_plain="${warn_plain}${bar_filled}${bar_empty} ${remaining}% ${used_k}k/${total_k}k"
  fi

  # 4. elapsed since startTime; values > 1e12 are treated as milliseconds
  start_time=$(tjq '.startTime // empty')
  elapsed_seg=""
  elapsed_text=""
  if [ -n "$start_time" ] && [[ "$start_time" =~ ^[0-9]+$ ]]; then
    start_s="$start_time"
    if [ "$start_time" -gt 1000000000000 ]; then
      start_s=$(( start_time / 1000 ))
    fi
    now_s=$(date +%s)
    elapsed=$(( now_s - start_s ))
    [ "$elapsed" -lt 0 ] && elapsed=0
    elapsed_min=$(( elapsed / 60 ))
    if [ "$elapsed_min" -ge 60 ]; then
      elapsed_text="$(( elapsed_min / 60 ))h$(( elapsed_min % 60 ))m"
    else
      elapsed_text="${elapsed_min}m"
    fi
    elapsed_seg="${WHITE}${elapsed_text}${RESET}"
  fi

  # 5. description - gray, width-budgeted against columns so the row fits
  description=$(tjq '.description // empty')
  desc_seg=""
  if [ -n "$description" ]; then
    plain_parts=()
    [ -n "$seg1_plain" ] && plain_parts+=("$seg1_plain")
    [ -n "$status" ] && plain_parts+=("$status")
    [ -n "$ctx_plain" ] && plain_parts+=("$ctx_plain")
    [ -n "$elapsed_text" ] && plain_parts+=("$elapsed_text")
    plain_row=""
    for pp in "${plain_parts[@]}"; do
      if [ -z "$plain_row" ]; then
        plain_row="$pp"
      else
        plain_row="${plain_row} | ${pp}"
      fi
    done
    used_width=${#plain_row}
    budget=$(( columns - used_width - 3 ))
    if [ "$budget" -ge 8 ]; then
      desc_len=${#description}
      if [ "$desc_len" -gt "$budget" ]; then
        cut=$(( budget - 1 ))
        desc_text="${description:0:$cut}…"
      else
        desc_text="$description"
      fi
      desc_seg="${GRAY}${desc_text}${RESET}"
    fi
  fi

  row_parts=()
  [ -n "$seg1" ]        && row_parts+=("$seg1")
  [ -n "$status_seg" ]  && row_parts+=("$status_seg")
  [ -n "$ctx_seg" ]     && row_parts+=("$ctx_seg")
  [ -n "$elapsed_seg" ] && row_parts+=("$elapsed_seg")
  [ -n "$desc_seg" ]    && row_parts+=("$desc_seg")

  row=""
  for rp in "${row_parts[@]}"; do
    if [ -z "$row" ]; then
      row="$rp"
    else
      row="${row}${SEP}${rp}"
    fi
  done
  row="${row}${RESET}"

  jq -cn --arg id "$id" --arg content "$row" '{id:$id, content:$content}'
done
