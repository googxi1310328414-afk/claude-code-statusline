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
# effort, model, tokenSamples (undocumented structure, defensively parsed).
# cwd is part of the contract but unused here.
#
# Row segments, each cleanly omitted when its data is absent, joined with
# the same gray " | " separator as the main script. Order:
# identity(+status icon) | battery-or-rawtokens | sparkline+burn-rate | token-share | elapsed(+start clock) | description
#
#   1  identity segment: "▸ " (gray) + identity text (bright magenta, first
#      non-empty of name/label/type; identity absent -> the WHOLE segment
#      is omitted) + "(type)" in gray when .type is non-empty and differs
#      from the chosen identity text + "·" + short model name (cyan 36)
#      when .model is non-empty and differs from the payload-wide majority
#      model (majority computed once before the loop; if every task shares
#      one model, or none have one, this marker never shows anywhere) +
#      "·" + effort (heat-colored: low gray / medium green / high yellow /
#      xhigh bright magenta / max bright red / anything else incl. numeric
#      budgets yellow) + " " + a status glyph: running/in_progress "●"
#      green, pending/queued/starting "○" yellow, failed/error/cancelled/
#      killed "✗" bright red, completed/done/finished "✓" green (same
#      green as running - the glyph shape, not the color, differentiates
#      them), any other non-empty value "?" yellow, absent status -> no
#      glyph. Short model
#      name = id with a leading "claude-" and a trailing "-20"+6-digits
#      date suffix both stripped (e.g. "claude-haiku-4-5-20251001" ->
#      "haiku-4-5").
#   2  context battery, or raw cumulative spend. .tokenCount is the task's
#      CUMULATIVE token spend, not a context-window occupancy figure - a
#      long-running agent can burn far past its context window, since the
#      window gets compacted/reset along the way. So: only when tokenCount
#      and contextWindowSize are both present/numeric/positive AND
#      tokenCount <= contextWindowSize is a battery rendered (same bar
#      math as the main script's ctx segment: 5-cell bar, "!" + bright red
#      when remaining <20%, "Nk" white, "/Nk" gray) - that's a valid
#      occupancy approximation early in the window's life. Once tokenCount
#      > contextWindowSize there's no percentage claim left to make: this
#      slot instead renders a full bright-red bar "█████" (no "!" - that's
#      an occupancy signal, not a spend signal) followed by the raw
#      cumulative spend "<Nk> tok" (white/gray, e.g. "█████ 447k tok").
#      When contextWindowSize is absent/not >0 but tokenCount alone is
#      present/numeric, this slot falls back to the same raw-spend form,
#      "<Nk> tok".
#   3  sparkline + burn rate, ONE combined segment (each half
#      independently optional; both absent -> segment omitted), joined by
#      a single space when both are present. Sparkline (cyan) from
#      .tokenSamples - defensively parsed (any failure or fewer than 2
#      usable numeric samples -> omitted silently, never crashes the row).
#      Numbers come from raw numeric entries or from an object entry's
#      .tokens/.tokenCount/.count/.value/.v field; the last 8 are kept; if
#      that subsequence is non-decreasing (a cumulative counter) it's
#      converted to consecutive deltas first; the result is normalized
#      min..max onto the 8 glyphs ▁▂▃▄▅▆▇█ (all-equal -> all ▄). Burn rate
#      - only when tokenCount is numeric and elapsed seconds >= 60:
#      tokens/minute, shown as "N/m" or, at or above 1000/min, one decimal
#      in k as "N.Nk/m"; colored by the integer per-minute rate: <5000
#      gray, 5000-14999 yellow, >=15000 bright red
#   4  token share "Σ<N>%" of this payload's total tokens - only when at
#      least 2 tasks have a positive tokenCount and this task's own
#      tokenCount and the payload total are both positive: "Σ" gray, "N%"
#      dynamic (<50 gray, 50-74 yellow, >=75 bright red - token-hog
#      highlighting)
#   5  elapsed since startTime - white; values > 1e12 are treated as
#      milliseconds; "<N>s" under 1 minute, "<N>m<N>s" under 1 hour, else
#      "<N>h<N>m<N>s"; when shown, immediately (no space) followed by
#      "@HH:MM:SS" in gray - the local clock time startTime normalizes to
#   6  description - gray, width-budgeted against `columns` (default 120):
#      budget = columns - (plain width of segments 1-5 incl. separators,
#      "▸ " included) - 3; omitted if budget < 8, else cut to budget-1
#      chars + "…" when longer than budget
#
# Example row content (id omitted here):
#   ▸ code-reviewer(general)·haiku-4-5·max ● | ███░░ 66% 68k/200k | ▂▃▅█▆ 22.6k/m | Σ68% | 3m0s@14:32:07 | Review auth module for…
# Cumulative-spend-exceeds-window example (battery slot only):
#   █████ 447k tok
#
# Colors are the basic 16-color ANSI palette via bash ANSI-C quoting
# ($'\e[..m'); output is always plain %s - jq's -cn/--arg handles JSON
# escaping of the embedded ANSI bytes.

input=$(cat)

RESET=$'\e[0m'
GRAY=$'\e[90m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
CYAN=$'\e[36m'
WHITE=$'\e[37m'
RED_BRIGHT=$'\e[91m'
MAGENTA_BRIGHT=$'\e[95m'
SEP="${RESET}${GRAY} | ${RESET}"

columns=$(printf '%s' "$input" | jq -r '.columns // empty')
[[ "$columns" =~ ^[0-9]+$ ]] || columns=120

majority_model=$(printf '%s' "$input" | jq -r '[.tasks[]? | .model // empty | select(length>0)] | group_by(.) | max_by(length) | .[0] // empty')
total_tokens=$(printf '%s' "$input" | jq -r '[.tasks[]? | .tokenCount // 0 | select(type=="number")] | add // 0')
tokened_count=$(printf '%s' "$input" | jq -r '[.tasks[]? | .tokenCount // empty | select(type=="number" and . > 0)] | length')
[[ "$total_tokens" =~ ^[0-9]+$ ]] || total_tokens=0
[[ "$tokened_count" =~ ^[0-9]+$ ]] || tokened_count=0

tjq() { printf '%s' "$task" | jq -r "$1"; }

short_model() {
  local m="${1#claude-}"
  if [[ "$m" =~ ^(.*)-20[0-9]{6}$ ]]; then
    m="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$m"
}

printf '%s' "$input" | jq -c '.tasks[]?' | while IFS= read -r task; do
  id=$(tjq '.id // empty')
  [ -z "$id" ] && continue

  # 1. identity segment: "▸ " + identity (bright magenta) + "(type)" (gray)
  # + "·"+short-model (cyan, only when minority) + "·"+effort (heat-colored)
  identity_plain=$(tjq 'if (.name != null and .name != "") then .name elif (.label != null and .label != "") then .label elif (.type != null and .type != "") then .type else empty end')
  task_type=$(tjq '.type // empty')
  model=$(tjq '.model // empty')
  effort=$(tjq '.effort // empty')
  status=$(tjq '.status // empty')
  seg1_plain=""
  seg1=""
  if [ -n "$identity_plain" ]; then
    seg1_plain="▸ ${identity_plain}"
    seg1="${GRAY}▸ ${RESET}${MAGENTA_BRIGHT}${identity_plain}${RESET}"

    if [ -n "$task_type" ] && [ "$task_type" != "$identity_plain" ]; then
      seg1_plain="${seg1_plain}(${task_type})"
      seg1="${seg1}${GRAY}(${task_type})${RESET}"
    fi

    if [ -n "$model" ] && [ "$model" != "$majority_model" ]; then
      model_short=$(short_model "$model")
      seg1_plain="${seg1_plain}·${model_short}"
      seg1="${seg1}${GRAY}·${RESET}${CYAN}${model_short}${RESET}"
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
      seg1_plain="${seg1_plain}·${effort}"
      seg1="${seg1}${GRAY}·${RESET}${effort_color}${effort}${RESET}"
    fi

    if [ -n "$status" ]; then
      case "$status" in
        running|in_progress) status_icon="●"; status_color="$GREEN" ;;
        pending|queued|starting) status_icon="○"; status_color="$YELLOW" ;;
        failed|error|cancelled|killed) status_icon="✗"; status_color="$RED_BRIGHT" ;;
        completed|done|finished) status_icon="✓"; status_color="$GREEN" ;;
        *) status_icon="?"; status_color="$YELLOW" ;;
      esac
      seg1_plain="${seg1_plain} ${status_icon}"
      seg1="${seg1} ${status_color}${status_icon}${RESET}"
    fi
  fi

  # 2. context battery, or (when contextWindowSize is absent/not >0 but
  # tokenCount is present/numeric) the raw-token fallback "Nk tok" in this
  # same slot. tokenCount is the task's CUMULATIVE token spend, which can
  # exceed contextWindowSize on a long-running agent - the battery is only
  # a valid occupancy approximation while spend <= window. When spend >
  # window there's no percentage claim to make: render a full bright-red
  # bar plus the raw cumulative spend instead (no "!" - that's an
  # occupancy signal, and this isn't one).
  token_count=$(tjq '.tokenCount // empty')
  ctx_window_size=$(tjq '.contextWindowSize // empty')
  battery_seg=""
  battery_plain=""
  if [ -n "$token_count" ] && [ -n "$ctx_window_size" ] && [[ "$token_count" =~ ^[0-9]+$ ]] && [[ "$ctx_window_size" =~ ^[0-9]+$ ]] && [ "$ctx_window_size" -gt 0 ]; then
    if [ "$token_count" -gt "$ctx_window_size" ]; then
      spend_k=$(( (token_count + 500) / 1000 ))
      battery_seg="${RED_BRIGHT}█████${RESET} ${WHITE}${spend_k}k${RESET} ${GRAY}tok${RESET}"
      battery_plain="█████ ${spend_k}k tok"
    else
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
      [ -n "$ctx_warn" ] && battery_seg="${RED_BRIGHT}!${RESET}"
      battery_seg="${battery_seg}${bar} ${ctx_color}${remaining}%${RESET} ${WHITE}${used_k}k${RESET}${GRAY}/${total_k}k${RESET}"
      battery_plain="${warn_plain}${bar_filled}${bar_empty} ${remaining}% ${used_k}k/${total_k}k"
    fi
  elif [ -n "$token_count" ] && [[ "$token_count" =~ ^[0-9]+$ ]]; then
    tok_k=$(( (token_count + 500) / 1000 ))
    battery_seg="${WHITE}${tok_k}k${RESET} ${GRAY}tok${RESET}"
    battery_plain="${tok_k}k tok"
  fi

  # (shared) elapsed seconds since startTime; values > 1e12 treated as ms.
  # Computed here (ahead of the burn-rate half of segment 3, which needs
  # elapsed_s) even though the elapsed segment itself is displayed later.
  start_time=$(tjq '.startTime // empty')
  elapsed_s=""
  elapsed_seg=""
  elapsed_text=""
  elapsed_plain=""
  if [ -n "$start_time" ] && [[ "$start_time" =~ ^[0-9]+$ ]]; then
    start_s="$start_time"
    if [ "$start_time" -gt 1000000000000 ]; then
      start_s=$(( start_time / 1000 ))
    fi
    now_s=$(date +%s)
    elapsed_s=$(( now_s - start_s ))
    [ "$elapsed_s" -lt 0 ] && elapsed_s=0
    if [ "$elapsed_s" -lt 60 ]; then
      elapsed_text="${elapsed_s}s"
    elif [ "$elapsed_s" -lt 3600 ]; then
      elapsed_text="$(( elapsed_s / 60 ))m$(( elapsed_s % 60 ))s"
    else
      elapsed_text="$(( elapsed_s / 3600 ))h$(( (elapsed_s % 3600) / 60 ))m$(( elapsed_s % 60 ))s"
    fi
    start_clock=$(date -d "@$start_s" +%H:%M:%S 2>/dev/null)
    elapsed_seg="${WHITE}${elapsed_text}${RESET}"
    elapsed_plain="$elapsed_text"
    if [ -n "$start_clock" ]; then
      elapsed_seg="${elapsed_seg}${GRAY}@${start_clock}${RESET}"
      elapsed_plain="${elapsed_plain}@${start_clock}"
    fi
  fi

  # 3. sparkline + burn rate, ONE combined segment (each half independently
  # optional; both absent -> segment omitted), matching the main script's
  # token-rate segment layout.
  spark_seg=""
  spark_plain=""
  numbers=$(printf '%s' "$task" | jq -c '[.tokenSamples[]? | if type=="number" then . elif type=="object" then (.tokens // .tokenCount // .count // .value // .v // empty) else empty end | select(type=="number")]' 2>/dev/null)
  if [ -n "$numbers" ]; then
    num_count=$(printf '%s' "$numbers" | jq 'length' 2>/dev/null)
    if [[ "$num_count" =~ ^[0-9]+$ ]] && [ "$num_count" -ge 2 ]; then
      mapfile -t nums < <(printf '%s' "$numbers" | jq -r '.[-8:] | .[]' 2>/dev/null | tr -d '\r')
      n_ok=1
      for nv in "${nums[@]}"; do
        [[ "$nv" =~ ^-?[0-9]+$ ]] || n_ok=0
      done
      n_count=${#nums[@]}
      if [ "$n_ok" -eq 1 ] && [ "$n_count" -ge 2 ]; then
        is_nondecreasing=1
        for ((i=1; i<n_count; i++)); do
          if [ "${nums[$i]}" -lt "${nums[$((i-1))]}" ]; then
            is_nondecreasing=0
            break
          fi
        done
        values=()
        if [ "$is_nondecreasing" -eq 1 ]; then
          for ((i=1; i<n_count; i++)); do
            values+=( "$(( nums[i] - nums[i-1] ))" )
          done
        else
          values=("${nums[@]}")
        fi
        if [ "${#values[@]}" -ge 1 ]; then
          min_v=${values[0]}
          max_v=${values[0]}
          for v in "${values[@]}"; do
            [ "$v" -lt "$min_v" ] && min_v=$v
            [ "$v" -gt "$max_v" ] && max_v=$v
          done
          glyph_chars=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
          if [ "$max_v" -eq "$min_v" ]; then
            for v in "${values[@]}"; do
              spark_plain="${spark_plain}▄"
            done
          else
            range=$(( max_v - min_v ))
            for v in "${values[@]}"; do
              idx=$(( (v - min_v) * 7 / range ))
              [ "$idx" -lt 0 ] && idx=0
              [ "$idx" -gt 7 ] && idx=7
              spark_plain="${spark_plain}${glyph_chars[$idx]}"
            done
          fi
          spark_seg="${CYAN}${spark_plain}${RESET}"
        fi
      fi
    fi
  fi

  burn_seg=""
  burn_plain=""
  if [ -n "$token_count" ] && [[ "$token_count" =~ ^[0-9]+$ ]] && [ -n "$elapsed_s" ] && [ "$elapsed_s" -ge 60 ]; then
    rate=$(( token_count * 60 / elapsed_s ))
    if [ "$rate" -ge 1000 ]; then
      rate10=$(( token_count * 60 / (elapsed_s * 100) ))
      burn_text="$(( rate10 / 10 )).$(( rate10 % 10 ))k/m"
    else
      burn_text="${rate}/m"
    fi
    if [ "$rate" -ge 15000 ]; then
      burn_color="$RED_BRIGHT"
    elif [ "$rate" -ge 5000 ]; then
      burn_color="$YELLOW"
    else
      burn_color="$GRAY"
    fi
    burn_seg="${burn_color}${burn_text}${RESET}"
    burn_plain="$burn_text"
  fi

  sparkburn_seg=""
  sparkburn_plain=""
  if [ -n "$spark_seg" ] && [ -n "$burn_seg" ]; then
    sparkburn_seg="${spark_seg} ${burn_seg}"
    sparkburn_plain="${spark_plain} ${burn_plain}"
  elif [ -n "$spark_seg" ]; then
    sparkburn_seg="$spark_seg"
    sparkburn_plain="$spark_plain"
  elif [ -n "$burn_seg" ]; then
    sparkburn_seg="$burn_seg"
    sparkburn_plain="$burn_plain"
  fi

  # 4. token share of the whole payload's tokens - only when at least 2
  # tasks have a positive tokenCount and this task's own tokenCount is a
  # positive number and the payload total is positive.
  share_seg=""
  share_plain=""
  if [ "$tokened_count" -ge 2 ] && [ -n "$token_count" ] && [[ "$token_count" =~ ^[0-9]+$ ]] && [ "$token_count" -gt 0 ] && [ "$total_tokens" -gt 0 ]; then
    share=$(( token_count * 100 / total_tokens ))
    if [ "$share" -ge 75 ]; then
      share_color="$RED_BRIGHT"
    elif [ "$share" -ge 50 ]; then
      share_color="$YELLOW"
    else
      share_color="$GRAY"
    fi
    share_seg="${GRAY}Σ${RESET}${share_color}${share}%${RESET}"
    share_plain="Σ${share}%"
  fi

  # 6. description - gray, width-budgeted against columns so the row fits;
  # the plain-text width must account for every segment above (5. elapsed
  # is computed earlier, above, but still counted here).
  description=$(tjq '.description // empty')
  desc_seg=""
  if [ -n "$description" ]; then
    plain_parts=()
    [ -n "$seg1_plain" ] && plain_parts+=("$seg1_plain")
    [ -n "$battery_plain" ] && plain_parts+=("$battery_plain")
    [ -n "$sparkburn_plain" ] && plain_parts+=("$sparkburn_plain")
    [ -n "$share_plain" ] && plain_parts+=("$share_plain")
    [ -n "$elapsed_plain" ] && plain_parts+=("$elapsed_plain")
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
  [ -n "$seg1" ]          && row_parts+=("$seg1")
  [ -n "$battery_seg" ]   && row_parts+=("$battery_seg")
  [ -n "$sparkburn_seg" ] && row_parts+=("$sparkburn_seg")
  [ -n "$share_seg" ]     && row_parts+=("$share_seg")
  [ -n "$elapsed_seg" ]   && row_parts+=("$elapsed_seg")
  [ -n "$desc_seg" ]      && row_parts+=("$desc_seg")

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
