#!/bin/bash
# Force a UTF-8 locale: this environment's LANG is empty (POSIX/C locale),
# under which bash's ${#var}, ${var:0:N}, and =~ character classes are all
# BYTE-based, silently over-counting every multibyte glyph used below
# (▸ ● ✓ ✗ · █ ░ ▁-█ … ⎇ » Σ →) and throwing off column alignment. Must be
# set before any string measurement happens (i.e. before every other line
# in this script). The CJK width-2-terminal-cells limitation (documented
# below) is unrelated and unaffected - characters are now counted
# correctly, but a CJK character still occupies two terminal cells while
# counting as one character.
export LC_ALL=C.UTF-8
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
# Column layout: 6 FIXED semantic columns, 1=identity 2=spend 3=sparkline+
# rate 4=share 5=elapsed 6=description. Unlike the main script (which
# omits-and-shifts), this script column-ALIGNS every row's " | "
# separators against every OTHER row in the same payload: a two-pass
# design first computes every task's 6 cells (colored + a parallel plain
# twin, no ANSI/OSC 8, used only for width measurement), tracks the max
# plain width per column (1-5; description is always last and never
# padded) across ALL rows, then a second pass pads and emits each row. A
# task missing a MIDDLE column (e.g. no token share) still renders an
# EMPTY padded cell there (spaces + separator) so later present columns
# stay aligned; only TRAILING absent columns (nothing from there to the
# end of that row) are dropped entirely, and a row's last rendered cell is
# never padded. Column widths are recomputed fresh every payload/refresh.
# Width is measured in true terminal DISPLAY cells via disp_width() (see
# its own comment below), not raw character count, so East Asian wide/
# fullwidth identity names and descriptions (this script's most likely
# carriers of CJK text) align correctly rather than just approximately.
# The glyphs this script draws itself count as 1 cell, matching Windows
# Terminal's default profile - see disp_width()'s comment if your terminal
# is configured for East-Asian ambiguous-wide instead.
#
#   1  identity segment: "▸ " (gray) + identity text (bright magenta, first
#      non-empty of name/label/type; identity absent -> the WHOLE segment
#      is empty for this row, i.e. a padded blank column here unless it's
#      also this row's trailing-absent point) + "(type)" in gray when
#      .type is non-empty and differs from the chosen identity text + "·"
#      + short model name (cyan 36) when .model is non-empty and differs
#      from the payload-wide majority model (majority computed once
#      before pass 1; if every task shares one model, or none have one,
#      this marker never shows anywhere) + "·" + effort (heat-colored: low
#      gray / medium green / high yellow / xhigh bright magenta / max
#      bright red / anything else incl. numeric budgets yellow) + " " + a
#      status glyph: running/in_progress "●" green, pending/queued/
#      starting "○" yellow, failed/error/cancelled/killed "✗" bright red,
#      completed/done/finished "✓" green (same green as running - the
#      glyph shape, not the color, differentiates them), any other
#      non-empty value "?" yellow, absent status -> no glyph. Short model
#      name = id with a leading "claude-" and a trailing "-20"+6-digits
#      date suffix both stripped (e.g. "claude-haiku-4-5-20251001" ->
#      "haiku-4-5").
#   2  raw cumulative spend - unconditional whenever tokenCount is
#      numeric: "<Nk>" white 37 + space + "tok" gray 90, e.g. "221k tok".
#      (There is deliberately no context-window battery/percentage here
#      anymore: tokenCount is cumulative spend, not window occupancy, so a
#      percentage claim would be misleading on a long-running agent;
#      contextWindowSize is no longer read at all.)
#   3  sparkline + burn rate, ONE combined segment (each half
#      independently optional; both absent -> segment empty for this
#      row), joined by a single space when both are present. Sparkline
#      (cyan) from .tokenSamples - defensively parsed (any failure or
#      fewer than 2 usable numeric samples -> omitted silently, never
#      crashes the row). Numbers come from raw numeric entries or from an
#      object entry's .tokens/.tokenCount/.count/.value/.v field; the last
#      8 are kept; if that subsequence is non-decreasing (a cumulative
#      counter) it's converted to consecutive deltas first; the result is
#      normalized min..max onto the 8 glyphs ▁▂▃▄▅▆▇█ (all-equal -> all
#      ▄). Burn rate - only when tokenCount is numeric and elapsed seconds
#      >= 60: tokens/minute, shown as "N/m" or, at or above 1000/min, one
#      decimal in k as "N.Nk/m"; colored by the integer per-minute rate:
#      <5000 gray, 5000-14999 yellow, >=15000 bright red
#   4  token share "Σ<N>%" of this payload's total tokens - only when at
#      least 2 tasks have a positive tokenCount and this task's own
#      tokenCount and the payload total are both positive: "Σ" gray, "N%"
#      dynamic (<50 gray, 50-74 yellow, >=75 bright red - token-hog
#      highlighting)
#   5  elapsed since startTime - white; values > 1e12 are treated as
#      milliseconds; "<N>s" under 1 minute, "<N>m<N>s" under 1 hour, else
#      "<N>h<N>m<N>s"; when shown, immediately (no space) followed by
#      "@HH:MM:SS" in gray - the local clock time startTime normalizes to
#   6  description - gray, width-budgeted against `columns` (default 120),
#      the budget measured in display CELLS, not characters. Because
#      alignment forces columns 1-5 to their globally padded widths
#      whenever description follows, the budget is UNIFORM across every
#      row in the payload (not per-row): budget = columns - (sum of the
#      five columns' max display widths) - 15 (5 columns' worth of " | "
#      separators, one between each pair plus one before the description
#      itself). Omitted if budget < 8, else cut - by accumulating each
#      character's disp_width() until budget-1 cells are used - + "…"
#      when longer than budget.
#
# Example row content (id omitted here):
#   ▸ 0.2.79 收尾与发布(local_agent) ● | 221k tok | ▁▂▄ 11.2k/m | Σ84% | 19m41s@07:41:30 | 描述…
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

# True terminal DISPLAY width of a plain (no ANSI) string, in cells, for
# column-alignment math and description-budget truncation - ${#s} alone
# is a character count, which under-counts East Asian wide/fullwidth text
# (2 cells each; identity names and descriptions are the columns most
# likely to carry it). Fast path: pure-ASCII strings return ${#s} (cheap,
# covers the common case). Otherwise walks characters (relies on
# LC_ALL=C.UTF-8 above so ${s:i:1}/${#s} are character-, not byte-,
# based), looks up each non-ASCII character's Unicode codepoint via
# printf's "'c" numeric-value extension, and adds 2 for the standard
# wide/fullwidth ranges, else 1. The glyphs this script uses on its own
# (▸ ● ✓ ✗ · → Σ █ ░ ▁-█ …) are all deliberately counted as 1 cell here,
# matching how Windows Terminal's default (non-East-Asian-ambiguous-wide)
# profile renders them - a terminal configured for East-Asian
# ambiguous-wide would need those bumped to 2 to match its own rendering.
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

mapfile -t all_tasks < <(printf '%s' "$input" | jq -c '.tasks[]?' 2>/dev/null | tr -d '\r')

# ---------- PASS 1: compute every row's 6 cells + track column maxima ----------
ids=()
descriptions=()
col0_c=(); col0_p=()   # identity
col1_c=(); col1_p=()   # raw spend
col2_c=(); col2_p=()   # sparkline+rate
col3_c=(); col3_p=()   # token share
col4_c=(); col4_p=()   # elapsed
col_max=(0 0 0 0 0)

for task in "${all_tasks[@]}"; do
  id=$(tjq '.id // empty')
  [ -z "$id" ] && continue

  # column 1: identity segment: "▸ " + identity (bright magenta) + "(type)"
  # (gray) + "·"+short-model (cyan, only when minority) + "·"+effort
  # (heat-colored) + " "+status glyph
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

  # column 2: raw cumulative spend - unconditional whenever tokenCount is
  # numeric; no context-window battery/percentage (tokenCount is
  # cumulative spend, not occupancy; contextWindowSize is not read).
  token_count=$(tjq '.tokenCount // empty')
  spend_seg=""
  spend_plain=""
  if [[ "$token_count" =~ ^[0-9]+$ ]]; then
    spend_k=$(( (token_count + 500) / 1000 ))
    spend_seg="${WHITE}${spend_k}k${RESET} ${GRAY}tok${RESET}"
    spend_plain="${spend_k}k tok"
  fi

  # (shared) elapsed seconds since startTime; values > 1e12 treated as ms.
  # Computed here (ahead of the burn-rate half of column 3, which needs
  # elapsed_s) even though the elapsed segment itself sits in column 5.
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

  # column 3: sparkline + burn rate, ONE combined segment (each half
  # independently optional), matching the main script's token-rate layout.
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

  # column 4: token share of the whole payload's tokens
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

  description=$(tjq '.description // empty')

  ids+=("$id")
  descriptions+=("$description")
  col0_c+=("$seg1");          col0_p+=("$seg1_plain")
  col1_c+=("$spend_seg");     col1_p+=("$spend_plain")
  col2_c+=("$sparkburn_seg"); col2_p+=("$sparkburn_plain")
  col3_c+=("$share_seg");     col3_p+=("$share_plain")
  col4_c+=("$elapsed_seg");   col4_p+=("$elapsed_plain")

  dw0=$(disp_width "$seg1_plain")
  dw1=$(disp_width "$spend_plain")
  dw2=$(disp_width "$sparkburn_plain")
  dw3=$(disp_width "$share_plain")
  dw4=$(disp_width "$elapsed_plain")
  [ "$dw0" -gt "${col_max[0]}" ] && col_max[0]=$dw0
  [ "$dw1" -gt "${col_max[1]}" ] && col_max[1]=$dw1
  [ "$dw2" -gt "${col_max[2]}" ] && col_max[2]=$dw2
  [ "$dw3" -gt "${col_max[3]}" ] && col_max[3]=$dw3
  [ "$dw4" -gt "${col_max[4]}" ] && col_max[4]=$dw4
done

# ---------- PASS 2: build the uniform description budget, pad, emit ----------
desc_budget=$(( columns - (col_max[0]+col_max[1]+col_max[2]+col_max[3]+col_max[4]) - 15 ))

row_total=${#ids[@]}
for ((r=0; r<row_total; r++)); do
  id="${ids[$r]}"

  present0=0; [ -n "${col0_p[$r]}" ] && present0=1
  present1=0; [ -n "${col1_p[$r]}" ] && present1=1
  present2=0; [ -n "${col2_p[$r]}" ] && present2=1
  present3=0; [ -n "${col3_p[$r]}" ] && present3=1
  present4=0; [ -n "${col4_p[$r]}" ] && present4=1

  # description - gray, cut to the UNIFORM budget computed above (same for
  # every row, since alignment pads columns 1-5 to the same widths
  # whenever description follows)
  description="${descriptions[$r]}"
  desc_seg=""
  if [ -n "$description" ] && [ "$desc_budget" -ge 8 ]; then
    desc_disp_len=$(disp_width "$description")
    if [ "$desc_disp_len" -gt "$desc_budget" ]; then
      # Cut by accumulated DISPLAY width, not character count: walk
      # characters, keep adding while the running total stays within
      # budget-1 cells (leaving exactly 1 cell for the "…" appended after).
      target=$(( desc_budget - 1 ))
      desc_chars=${#description}
      acc=0
      cut_pos=0
      for ((di=0; di<desc_chars; di++)); do
        dc="${description:di:1}"
        dw=$(disp_width "$dc")
        [ "$(( acc + dw ))" -gt "$target" ] && break
        acc=$(( acc + dw ))
        cut_pos=$(( di + 1 ))
      done
      desc_text="${description:0:$cut_pos}…"
    else
      desc_text="$description"
    fi
    desc_seg="${GRAY}${desc_text}${RESET}"
  fi

  # last_idx = highest column index (0-4 mid columns, 5 = description)
  # that has real content for this row; only trailing-absent columns past
  # it are dropped, everything up to it renders (empty-padded if absent).
  last_idx=-1
  [ "$present0" -eq 1 ] && last_idx=0
  [ "$present1" -eq 1 ] && last_idx=1
  [ "$present2" -eq 1 ] && last_idx=2
  [ "$present3" -eq 1 ] && last_idx=3
  [ "$present4" -eq 1 ] && last_idx=4
  [ -n "$desc_seg" ]    && last_idx=5

  row=""
  if [ "$last_idx" -ge 0 ]; then
    for ((i=0; i<=last_idx; i++)); do
      if [ "$i" -lt 5 ]; then
        case $i in
          0) cell_c="${col0_c[$r]}"; cell_p="${col0_p[$r]}" ;;
          1) cell_c="${col1_c[$r]}"; cell_p="${col1_p[$r]}" ;;
          2) cell_c="${col2_c[$r]}"; cell_p="${col2_p[$r]}" ;;
          3) cell_c="${col3_c[$r]}"; cell_p="${col3_p[$r]}" ;;
          4) cell_c="${col4_c[$r]}"; cell_p="${col4_p[$r]}" ;;
        esac
      else
        cell_c="$desc_seg"
        cell_p=""
      fi
      if [ "$i" -eq "$last_idx" ]; then
        row="${row}${cell_c}"
      else
        plen=$(disp_width "$cell_p")
        w="${col_max[$i]}"
        pad=$(( w - plen ))
        padding=""
        [ "$pad" -gt 0 ] && padding=$(printf '%*s' "$pad" '')
        row="${row}${cell_c}${padding}${SEP}"
      fi
    done
  fi
  row="${row}${RESET}"

  jq -cn --arg id "$id" --arg content "$row" '{id:$id, content:$content}'
done
