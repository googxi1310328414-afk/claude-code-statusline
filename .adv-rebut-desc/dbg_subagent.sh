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
# an id produce no line. An empty/absent tasks array produces no output. If
# jq itself is missing, the script exits cleanly (0) with no output at all
# - there's no id to key a fallback line on in this contract, unlike the
# main script's single-line fallback.
#
# PERFORMANCE: ONE jq invocation for the ENTIRE payload - previously 3
# whole-payload calls (scalars, raw-JSON-per-task, per-task TSV rows)
# PLUS one more small jq call PER TASK for the tokenSamples sub-parse
# (3+N total). That per-task call is now folded into the SAME single
# invocation, inside the same per-task iteration that builds each task's
# row - see the extraction site's own PERF comment (right above the jq
# call itself) for exactly how the two are interleaved in one output
# stream and split back apart in bash with zero further jq/awk/grep
# calls. `date` is never called - bash's own `printf '%(fmt)T' epoch`
# builtin (4.2+, zero process spawns) is used everywhere a timestamp is
# needed.
#
# NO-FORK HELPER RETURNS: disp_width() and short_model() write to the
# global REPLY variable instead of printf-to-stdout, and every call site
# does `fn args; x="$REPLY"` - NEVER `x=$(fn args)`, because bash's
# command substitution forks a subshell on MSYS2/Windows (~2.5ms each)
# even around a pure-bash function with no external program in it.
# disp_width() in particular is called per task in PASS 1 AND per
# CHARACTER of a task's description in PASS 2's truncation loop, so
# $(disp_width ...) was, before this conversion, capable of costing
# dozens of forks for a single long description in a single row.
# `printf -v var 'fmt' args` (never `var=$(printf ...)`) is used the same
# way for every other formatted value, including the padding `%*s` form,
# not just %()T dates.
#
# EXPECTED REMAINING SPAWN INVENTORY per render, after this pass: exactly
# ONE jq invocation, full stop, regardless of task count - the 3+N
# per-task jq exception from the prior de-spawn round is fully closed.
# Nothing else in this script forks: every helper call, every %()T/%*s
# format, every per-task/per-character loop is a bash builtin or
# parameter expansion.
#
# Per-task fields consumed: id, name, type, status, description, label,
# startTime (unix seconds or milliseconds), tokenCount, contextWindowSize,
# effort, model, tokenSamples (undocumented structure, defensively parsed).
# cwd is part of the contract but unused here.
#
# Column layout: up to 6 semantic columns, 1=identity 2=spend 3=sparkline+
# rate 4=share 5=elapsed 6=description. Unlike the main script (which
# omits-and-shifts), this script column-ALIGNS every row's " | "
# separators against every OTHER row in the same payload: a two-pass
# design first computes every task's 6 cells (colored + a parallel plain
# twin, no ANSI/OSC 8, used only for width measurement), tracks the max
# plain width per column (1-5; description is always last and never
# padded) across ALL rows, then determines which of columns 1-5 are
# ACTIVE (at least one row's plain width there is >0) - any column no row
# ever used is dropped from the layout entirely, for every row (no
# placeholder cell, no separator; otherwise a column empty across the
# WHOLE payload, e.g. token share with a single task, would still print
# an empty padded cell and produce a stray "| |") - before a second pass
# pads and emits each row using only the active columns. A task missing
# an ACTIVE middle column (e.g. no token share on THIS row, but some
# other row in the payload has it) still renders an EMPTY padded cell
# there so later present columns stay aligned; only TRAILING absent
# columns (nothing from there to the end of that row) are dropped per-
# row, and a row's last rendered cell is never padded. Column widths and
# which columns are active are both recomputed fresh every payload/
# refresh.
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
#      .type is non-empty and differs from the chosen identity text + "·" +
#      effort (heat-colored: low
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
#   1b model cell: the short model name (cyan; "claude-" prefix and the
#      "-20"+date suffix stripped, a trailing "[1m]"-style capacity tag
#      KEPT verbatim) as its OWN standalone column right after identity -
#      user request: not glued to the task name. Unconditional whenever
#      .model is present; when no task in the payload has a model the
#      whole column is dropped by the active-column pass. majority_model
#      is still emitted by jq (JL scalar index stability) but no longer
#      used for display at all.
#   2  raw cumulative spend - unconditional whenever tokenCount is
#      numeric: "<Nk>" white 37 + space + "tok" gray 90, e.g. "221k tok".
#      (There is deliberately no context-window battery/percentage here
#      anymore: tokenCount is cumulative spend, not window occupancy, so a
#      percentage claim would be misleading on a long-running agent;
#      contextWindowSize is no longer read at all.)
#   3  sparkline + burn rate, ONE combined segment (each half
#      independently optional; both absent -> segment empty for this
#      row), joined by a single space when both are present. Sparkline
#      PRIMARY source: this script's OWN 10s sampling of each task's
#      cumulative tokenCount into a state file (see the block above
#      PASS 1) - last 9 samples -> up to 8 bars, each spanning a KNOWN
#      ~10s. FALLBACK (fewer than 2 own samples yet, e.g. a just-spawned
#      task): .tokenSamples from the payload - defensively parsed (any
#      failure or fewer than 2 usable numeric samples -> omitted
#      silently, never crashes the row); numbers come from raw numeric
#      entries or from an object entry's .tokens/.tokenCount/.count/
#      .value/.v field; the last 8 are kept. Either way: if the sequence
#      is non-decreasing (a cumulative counter)
#      it's converted to consecutive deltas first; the result is
#      normalized min..max onto 6 glyphs ▁▂▃▄▅▆ (all-equal -> all ▃) -
#      capped at ▆, never ▇/█, so a full-height cell in one row can't
#      visually fuse with a bottom-aligned ▁ in the row above/below it
#      when multiple task rows are stacked at zero line spacing. Burn
#      rate - only when tokenCount is numeric and elapsed seconds
#      >= 60: tokens/minute, shown as "N/m" or, at or above 1000/min, one
#      decimal in k as "N.Nk/m"; colored by the integer per-minute rate:
#      <5000 gray, 5000-14999 yellow, >=15000 bright red. The sparkline
#      glyphs themselves take that SAME tier color when a rate is present;
#      cyan only when the sparkline renders alone (no rate).
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
# ($'\e[..m'), and every row's content string starts with a leading
# reset (defends against host/terminal dim-styling bleeding in). JSON
# escaping of each row (id + content, including the embedded ANSI bytes)
# is done inline in pure bash at the emit site (PASS 2, bottom of this
# file), not via `jq -cn`/--arg - seeing PERF comment there for why.

# Zero-fork stdin slurp, CHUNKED (see the main script's identical block
# for the full rationale): `read -d ''` byte-reads pipes (~550ms/100KB on
# MSYS - and THIS script's payload carries tokenSamples, which can get
# big); `read -N` buffers (~114ms/100KB), zero spawns. Final partial
# chunk arrives with read's nonzero EOF return, hence the trailing append.
input=""
while IFS= read -r -N 65536 slurp_chunk; do input+="$slurp_chunk"; done
input+="$slurp_chunk"

# jq guard: if jq is missing, every row below is unusable - emit nothing
# useful is impossible in this contract (no id to key a line on), so just
# exit cleanly rather than erroring or hanging.
command -v jq >/dev/null 2>&1 || exit 0

RESET=$'\e[0m'
GRAY=$'\e[90m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
CYAN=$'\e[36m'
WHITE=$'\e[37m'
RED_BRIGHT=$'\e[91m'
MAGENTA_BRIGHT=$'\e[95m'
# N6: alignment padding and the grid separator's surrounding spaces use
# NBSP (U+00A0), not a plain space, so VSCode-style terminals can't trim
# them and break column alignment; semantic single spaces inside a
# segment are left as plain spaces. disp_width() already counts NBSP as
# 1 cell (codepoint 160, outside every wide/fullwidth range).
NBSP=$'\xc2\xa0'
SEP="${RESET}${GRAY}${NBSP}|${NBSP}${RESET}"

# NO-FORK RETURN via global REPLY (see disp_width's comment below for the
# full rationale - every pure-bash helper in this script follows the same
# pattern now: call sites do `short_model "$x"; y="$REPLY"`, never
# `y=$(short_model "$x")`, since $(...) forks a subshell on MSYS2 even
# around a pure-bash function).
short_model() {
  local m="${1#claude-}"
  # a trailing "[1m]"-style capacity tag is KEPT verbatim (user likes it);
  # note it also makes the date-suffix regex a no-op on tagged ids, which
  # is fine - tagged ids don't carry date suffixes in practice
  if [[ "$m" =~ ^(.*)-20[0-9]{6}$ ]]; then
    m="${BASH_REMATCH[1]}"
  fi
  REPLY="$m"
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
# NO-FORK RETURN via global REPLY - this is the hottest helper in the
# script (called per-task in PASS 1 AND per-CHARACTER in PASS 2's
# description-cut loop); $(disp_width ...) forked a subshell PER CALL on
# MSYS2 even though the function is pure bash, which for a long
# description could mean dozens of forks for ONE cell of ONE row.
disp_width() {
  local s="$1"
  if [[ "$s" != *[![:ascii:]]* ]]; then
    REPLY="${#s}"
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
  REPLY="$total"
}

# PERF: ONE jq invocation for the ENTIRE payload - the four payload-wide
# scalars, every per-task field, AND the tokenSamples sub-parse are all
# emitted by this single call now (previously 3 whole-payload calls +
# 1 more per task, i.e. 3+N total). The tokenSamples slicing/type-
# checking that used to need its own small per-task call (it doesn't fit
# a flat delimited row) is done here too, inside the SAME `range($tcount)`
# iteration that builds each task's row, emitting a companion "samples
# line" tagged "S<index>" right after that task's row line. A tag (not
# just position) is used deliberately: a task with fewer than 2 usable
# samples still emits a samples line (just the bare tag, no numbers), so
# every task ALWAYS contributes exactly 2 output lines - if that ever
# stopped being true for any reason, the tag lets the bash side detect
# and reject a misaligned line instead of silently reading garbage into
# the wrong task's sparkline.
#
# Output line order: columns, majority_model, total_tokens, tokened_count,
# then per task (i = 0..tcount-1, same order as .tasks[]): row_i,
# samples_i. Bash captures ALL of it into one array (JL); JL[0..3] are the
# four scalars, JL[4+2*i] is task i's row, JL[4+2*i+1] is task i's samples
# line - task_count_total is derived from (total line count - 4) / 2, not
# read from anywhere else, so it can never disagree with the array it
# indexes into.
#
# CANONICAL COLUMN ORDER - the jq array below and the `read` variable
# list in the PASS 1 loop MUST stay exactly parallel; if a field is ever
# added/removed/reordered, update BOTH sites together:
#   1 id  2 identity  3 type  4 model  5 effort  6 status  7 startTime
#   8 tokenCount  9 description
#
# NOT read as literal TSV, on purpose: every text field is first run
# through `def clean` IN JQ - tab/LF/CR fold to a single space (so a
# newline typed into a description can never split a row) and every
# OTHER C0 control char is stripped outright. The strip is load-bearing
# twice over (adversarial review, 2026-08-14): a raw 0x1F inside a field
# (JSON \u001f is legal, @tsv passes it through) used to split that row
# at the wrong places - startTime landed in the tokenCount slot and got
# WRITTEN INTO the trend file - and any other raw C0 walked straight
# into the emitted JSON string, which the spec forbids, so the host
# dropped the whole row. After clean, the ONLY escape @tsv can still
# produce is backslash -> "\\" (its tab/LF/CR escapes have nothing left
# to fire on), and PASS 1 decodes that with ONE order-safe expansion per
# text field - a multi-escape decode has no safe order ("\" then "t"
# adjacent in cleartext is indistinguishable from an escaped tab), which
# is exactly why the escapes are neutralized jq-side instead. Every real
# separator tab @tsv inserts BETWEEN fields is then rewritten, in BASH
# after capture (parameter-expansion replace of the raw tab BYTE, whole
# blob in one shot), to the ASCII Unit Separator 0x1F. That rewrite is
# required, not cosmetic: space/tab/newline are BASH "IFS-whitespace",
# so `IFS=$'\t' read` silently COLLAPSES runs of consecutive tabs -
# i.e. every empty field, and most tasks have several - shifting every
# later field into the wrong variable (this hit production). 0x1F is not
# IFS-whitespace, so empty fields survive exactly; every `read` below
# uses IFS=$'\x1f' to match.
jq_all_out=$(jq -r '
  def clean: tostring | gsub("[\t\n\r]"; " ") | gsub("[\u0001-\u001f]"; "");
  (.columns // "") as $columns
  | (.tasks // []) as $tasks_raw
  | ($tasks_raw | if type == "array" then . else [] end) as $tasks
  | ($tasks | length) as $tcount
  | ([$tasks[]? | .model // empty | select(length>0)] | group_by(.) | max_by(length) | .[0] // "") as $majority_model
  | ([$tasks[]? | .tokenCount // 0 | select(type=="number")] | add // 0 | tostring) as $total_tokens
  | ([$tasks[]? | .tokenCount // empty | select(type=="number" and . > 0)] | length | tostring) as $tokened_count
  | $columns, ($majority_model | clean), $total_tokens, $tokened_count,
    (
      range(0; $tcount) as $i
      | ($tasks[$i]) as $task
      | (
          [
            ($task.id // "" | clean),
            ((if ($task.name != null and $task.name != "") then $task.name elif ($task.label != null and $task.label != "") then $task.label elif ($task.type != null and $task.type != "") then $task.type else "" end) | clean),
            ($task.type // "" | clean),
            ($task.model // "" | clean),
            ($task.effort // "" | clean),
            ($task.status // "" | clean),
            ($task.startTime // "" | tostring),
            ($task.tokenCount // "" | tostring),
            ($task.description // "" | clean)
          ] | @tsv
        ),
        (
          ([$task.tokenSamples[]? | if type=="number" then . elif type=="object" then (.tokens // .tokenCount // .count // .value // .v // empty) else empty end | select(type=="number")]) as $n
          | (["S" + ($i|tostring)] + (if ($n|length) >= 2 then ($n[-8:] | map(tostring)) else [] end)) | @tsv
        )
    )
# #z")
' <<< "$input" 2>/dev/null)
jq_all_out=${jq_all_out//$'\r'/}
jq_all_out=${jq_all_out//$'\t'/$'\x1f'}
mapfile -t JL <<< "$jq_all_out"
columns="${JL[0]}"
majority_model="${JL[1]}"
total_tokens="${JL[2]}"
tokened_count="${JL[3]}"
[[ "$columns" =~ ^[0-9]+$ ]] || columns=120
[[ "$total_tokens" =~ ^[0-9]+$ ]] || total_tokens=0
[[ "$tokened_count" =~ ^[0-9]+$ ]] || tokened_count=0

# ---------- own 10s token sampling (state file) ----------
# The host's .tokenSamples cadence is undocumented and uncontrollable, so
# each task's cumulative tokenCount is ALSO sampled here, at most one row
# per task every 10s, into a small state file - giving every sparkline
# bar a KNOWN ~10s span (the main script's history file does the same
# for the session chart at a 20s step). Row shape: epoch/task_id/count,
# 0x1F-separated like every other state file in this pair. Reads apply
# strict whole-row validation (exactly 3 columns, numeric epoch/count -
# malformed rows dropped whole, never partially trusted) plus a 1h read
# window (the trend needs ~90s of samples; churned-away task ids age out
# with it); expired rows vanish for good at the next slack-triggered
# rewrite. Multiple concurrent
# sessions share the file: task ids are globally unique so rows never
# clash logically, and the rewrite (after PASS 1) goes through a per-PID
# tmp + atomic mv, so a same-tick race is last-writer-wins with the
# loser's newest sample simply re-taken ~10s later - no corruption, no
# error spam. Fully guarded end to end: an unreadable/unwritable file
# only costs the sparkline its preferred source, never the row.
subagent_trend_file="${STATUSLINE_SUBAGENT_TREND_FILE:-$HOME/.claude/statusline-subagent-trend.tsv}"
printf -v samp_now '%(%s)T' -1
declare -A trend_csv_by_id trend_epoch_by_id
trend_dirty=0
if [ -r "$subagent_trend_file" ]; then
  mapfile -t trend_raw_lines < "$subagent_trend_file" 2>/dev/null
  # COMPACT TREND STATE - one row per task: id / last-sample epoch / csv
  # of the last <=9 cumulative counts. The per-render cost is bounded by
  # the LIVE task count and never scales with sampling history: the
  # previous design (an append log of one row per sample) re-scanned
  # hundreds of rows on every 5s panel tick, and on MSYS bash costs
  # ~20-40us PER STATEMENT, so a ~10-statement row loop burned ~0.3ms
  # per row - measured at ~330-400ms of every frame, i.e. most of the
  # visible "default rows flash" window while the host waits for us.
  # Rows are split/validated with parameter expansions and glob tests
  # (exactly 3 columns; csv strictly digits+commas); a row whose task
  # went >=30min without an update is a dead churned-away agent - it's
  # skipped here and (trend_dirty) swept out by the next rewrite.
  for trend_line in "${trend_raw_lines[@]}"; do
    t_id=${trend_line%%$'\x1f'*}
    trend_rest=${trend_line#*$'\x1f'}
    t_epoch=${trend_rest%%$'\x1f'*}
    t_csv=${trend_rest#*$'\x1f'}
    [[ "$trend_line" != *$'\x1f'* ]] && continue
    [[ "$trend_rest" != *$'\x1f'* ]] && continue
    [[ "$t_csv" == *$'\x1f'* ]] && continue
    [ -n "$t_id" ] || continue
    [[ "$t_epoch" =~ ^[0-9]+$ ]] || continue
    [ -n "$t_csv" ] || continue
    [[ "$t_csv" == *[!0-9,]* ]] && continue
    # CLOCK-ROLLBACK GUARD: a row stamped in the future (wall clock
    # stepped back since it was written) would block the >=10s sampling
    # throttle below until the clock re-passes it - purge it instead;
    # sampling restarts cleanly on this very render.
    [ "$t_epoch" -gt $(( samp_now + 60 )) ] && { trend_dirty=1; continue; }
    [ $(( samp_now - t_epoch )) -gt 1800 ] && { trend_dirty=1; continue; }
    trend_csv_by_id[$t_id]=$t_csv
    trend_epoch_by_id[$t_id]=$t_epoch
  done
fi

# ---------- PASS 1: compute every row's 6 cells + track column maxima ----------
ids=()
descriptions=()
col0_c=(); col0_p=()   # identity
col1_c=(); col1_p=()   # raw spend
col2_c=(); col2_p=()   # sparkline+rate
col3_c=(); col3_p=()   # token share
col4_c=(); col4_p=()   # elapsed
col5_c=(); col5_p=()   # model (standalone cell; rendered 2nd, see active_cols)
col_max=(0 0 0 0 0 0)

jl_count=${#JL[@]}
task_count_total=$(( (jl_count - 4) / 2 ))
[ "$task_count_total" -lt 0 ] && task_count_total=0
# @tsv decode constants (see the jq call's header comment): after jq-side
# `clean`, backslash is the ONLY escape @tsv can still emit, so decoding
# is one expansion per text field - order-safe by construction.
BSL1='\'
BSL2='\\'
for ((ti=0; ti<task_count_total; ti++)); do
  row_idx=$(( 4 + 2*ti ))
  # Field order matches the CANONICAL COLUMN ORDER comment above exactly.
  # IFS is the Unit Separator (0x1F), NOT tab - see that comment for why a
  # literal tab here would silently corrupt any row with an empty field.
  IFS=$'\x1f' read -r id identity_plain task_type model effort status start_time token_count description <<< "${JL[$row_idx]}"
  [ -z "$id" ] && continue
  # @tsv DECODE (adversarial review fix, 2026-08-14): undo the doubled
  # backslashes @tsv wrote (its only remaining escape after jq-side
  # clean) on the user-text fields - Windows paths in descriptions/names
  # rendered as C:\\Users\\... and were width-budgeted at the inflated
  # length. Enum-shaped fields (status/effort/model id) can't carry
  # backslashes and skip the expansion.
  identity_plain=${identity_plain//"$BSL2"/"$BSL1"}
  task_type=${task_type//"$BSL2"/"$BSL1"}
  description=${description//"$BSL2"/"$BSL1"}

  # column 1: identity segment: "▸ " + identity (bright magenta) + "(type)"
  # (gray) + "·"+short-model (cyan, always when present) + "·"+effort
  # (heat-colored) + " "+status glyph
  # (identity_plain/task_type/model/effort/status split from task_rows above)
  seg1_plain=""
  seg1=""
  if [ -n "$identity_plain" ]; then
    seg1_plain="▸ ${identity_plain}"
    seg1="${GRAY}▸ ${RESET}${MAGENTA_BRIGHT}${identity_plain}${RESET}"

    if [ -n "$task_type" ] && [ "$task_type" != "$identity_plain" ]; then
      seg1_plain="${seg1_plain}(${task_type})"
      seg1="${seg1}${GRAY}(${task_type})${RESET}"
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
  # (token_count already split from task_rows above)
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
  # (start_time already split from task_rows above)
  elapsed_s=""
  elapsed_seg=""
  elapsed_text=""
  elapsed_plain=""
  if [ -n "$start_time" ] && [[ "$start_time" =~ ^[0-9]+$ ]]; then
    start_s="$start_time"
    if [ "$start_time" -gt 1000000000000 ]; then
      start_s=$(( start_time / 1000 ))
    fi
    printf -v now_s '%(%s)T' -1
    elapsed_s=$(( now_s - start_s ))
    [ "$elapsed_s" -lt 0 ] && elapsed_s=0
    if [ "$elapsed_s" -lt 60 ]; then
      elapsed_text="${elapsed_s}s"
    elif [ "$elapsed_s" -lt 3600 ]; then
      elapsed_text="$(( elapsed_s / 60 ))m$(( elapsed_s % 60 ))s"
    else
      elapsed_text="$(( elapsed_s / 3600 ))h$(( (elapsed_s % 3600) / 60 ))m$(( elapsed_s % 60 ))s"
    fi
    printf -v start_clock '%(%H:%M:%S)T' "$start_s" 2>/dev/null
    elapsed_seg="${WHITE}${elapsed_text}${RESET}"
    elapsed_plain="$elapsed_text"
    if [ -n "$start_clock" ]; then
      elapsed_seg="${elapsed_seg}${GRAY}@${start_clock}${RESET}"
      elapsed_plain="${elapsed_plain}@${start_clock}"
    fi
  fi

  # column 1b: model as its OWN standalone cell (user request - not glued
  # to the task name; see header item 1b). Cyan short name, unconditional
  # when present; the active-column pass drops the whole column when no
  # task carries a model.
  model_seg=""
  model_plain=""
  if [ -n "$model" ]; then
    short_model "$model"; model_short="$REPLY"
    if [ -n "$model_short" ]; then
      model_seg="${CYAN}${model_short}${RESET}"
      model_plain="$model_short"
    fi
  fi

  # Advance this task's trend state (at most one sample every 10s - see
  # the state block above PASS 1): append the cumulative count to the
  # csv, keep only the last 9 values (comma-count trim, pure expansions).
  # Taken BEFORE the sparkline below so a just-taken sample is part of
  # this very render's chart, mirroring the main script's "reflect the
  # just-appended row" behavior.
  if [[ "$token_count" =~ ^[0-9]+$ ]]; then
    trend_prev_epoch="${trend_epoch_by_id[$id]:-}"
    if [ -z "$trend_prev_epoch" ] || [ $(( samp_now - trend_prev_epoch )) -ge 10 ]; then
      trend_new_csv="${trend_csv_by_id[$id]:+${trend_csv_by_id[$id]},}${token_count}"
      while :; do
        trend_commas=${trend_new_csv//[!,]/}
        [ "${#trend_commas}" -lt 9 ] && break
        trend_new_csv=${trend_new_csv#*,}
      done
      trend_csv_by_id[$id]=$trend_new_csv
      trend_epoch_by_id[$id]=$samp_now
      trend_dirty=1
    fi
  fi

  # column 3: sparkline + burn rate, ONE combined segment (each half
  # independently optional), matching the main script's token-rate layout.
  # PERF: the tokenSamples extraction, the >=2-usable-numbers check, and
  # the last-8 slice are now computed by the SAME single consolidated jq
  # call above (no per-task jq call left at all - see that call's own PERF
  # comment). Its companion "samples line" for this task is JL[row_idx+1],
  # tagged "S<ti>"; the tag is checked against this row's own index before
  # trusting the numbers, so a shifted/misaligned line (which should never
  # happen, but costs nothing to guard) degrades to "no sparkline" instead
  # of feeding a wrong task's samples into this one's chart. A task with
  # fewer than 2 usable samples still has a samples line (bare tag, no
  # numbers), so nums ends up empty and the numeric-regex/count checks
  # below naturally reject it - no special-casing needed for that case.
  spark_seg=""
  spark_plain=""
  samp_idx=$(( row_idx + 1 ))
  samples_line="${JL[$samp_idx]:-}"
  IFS=$'\x1f' read -r -a sfields <<< "$samples_line"
  nums=()
  if [ "${#sfields[@]}" -ge 1 ] && [ "${sfields[0]}" = "S${ti}" ]; then
    nums=("${sfields[@]:1}")
  fi
  # PRIMARY sparkline source: the own 10s trend state advanced above
  # (>=2 values for this task id; already capped at the last 9 -> up to
  # 8 bars of ~10s each). The host .tokenSamples parse above remains as
  # the cold-start fallback so a just-spawned task can still chart
  # before two own samples exist.
  if [ -n "${trend_csv_by_id[$id]:-}" ]; then
    IFS=, read -r -a samp_own_all <<< "${trend_csv_by_id[$id]}"
    if [ "${#samp_own_all[@]}" -ge 2 ]; then
      nums=("${samp_own_all[@]}")
    fi
  fi
  if [ "${#nums[@]}" -ge 1 ]; then
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
          # Capped at 6 levels (▁-▆, no ▇/█): with multiple task rows
          # stacked at zero line spacing, a full-height █ in one row can
          # visually fuse with a bottom-aligned ▁ in the row above/below
          # it; stopping at ▆ keeps a >=1/4-cell gap at every cell top so
          # rows can never connect.
          glyph_chars=("▁" "▂" "▃" "▄" "▅" "▆")
          if [ "$max_v" -eq "$min_v" ]; then
            for v in "${values[@]}"; do
              spark_plain="${spark_plain}▃"
            done
          else
            range=$(( max_v - min_v ))
            for v in "${values[@]}"; do
              idx=$(( (v - min_v) * 5 / range ))
              [ "$idx" -lt 0 ] && idx=0
              [ "$idx" -gt 5 ] && idx=5
              spark_plain="${spark_plain}${glyph_chars[$idx]}"
            done
          fi
          # coloring deferred until burn rate (below) is known - item 9
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

  # item 9: sparkline glyphs take the burn rate's tier color when a rate
  # is present, cyan only when the sparkline renders alone (no rate).
  spark_seg=""
  if [ -n "$spark_plain" ]; then
    if [ -n "$burn_seg" ]; then
      spark_color="$burn_color"
    else
      spark_color="$CYAN"
    fi
    spark_seg="${spark_color}${spark_plain}${RESET}"
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

  # (description already split from task_rows above)

  ids+=("$id")
  descriptions+=("$description")
  col0_c+=("$seg1");          col0_p+=("$seg1_plain")
  col5_c+=("$model_seg");     col5_p+=("$model_plain")
  col1_c+=("$spend_seg");     col1_p+=("$spend_plain")
  col2_c+=("$sparkburn_seg"); col2_p+=("$sparkburn_plain")
  col3_c+=("$share_seg");     col3_p+=("$share_plain")
  col4_c+=("$elapsed_seg");   col4_p+=("$elapsed_plain")

  disp_width "$seg1_plain"; dw0="$REPLY"
  disp_width "$spend_plain"; dw1="$REPLY"
  disp_width "$sparkburn_plain"; dw2="$REPLY"
  disp_width "$share_plain"; dw3="$REPLY"
  disp_width "$elapsed_plain"; dw4="$REPLY"
  [ "$dw0" -gt "${col_max[0]}" ] && col_max[0]=$dw0
  [ "$dw1" -gt "${col_max[1]}" ] && col_max[1]=$dw1
  [ "$dw2" -gt "${col_max[2]}" ] && col_max[2]=$dw2
  [ "$dw3" -gt "${col_max[3]}" ] && col_max[3]=$dw3
  [ "$dw4" -gt "${col_max[4]}" ] && col_max[4]=$dw4
  disp_width "$model_plain"; dw5="$REPLY"
  [ "$dw5" -gt "${col_max[5]}" ] && col_max[5]=$dw5
done

# Persist the own-samples state (only when this render actually took at
# least one new sample). Retention was already applied at read time, so
# the in-memory rows ARE the post-trim file; the count cap is a runaway
# backstop only. Per-PID tmp + atomic mv, same pattern as every other
# state writer in this pair; all failure modes silenced.
# Persist the trend state: one row per live task, so the file is tiny
# (task count, not history length) and a plain rewrite IS the cheap
# path - no append/rewrite split needed. Cross-session rows were loaded
# and re-emitted above, so concurrent sessions merge; a lost race is
# re-derived from the loser's own next sample tick. Per-PID tmp +
# atomic mv, all failures silenced.
if [ "$trend_dirty" -eq 1 ]; then
  trend_out_lines=()
  for t_key in "${!trend_csv_by_id[@]}"; do
    trend_out_lines+=("${t_key}"$'\x1f'"${trend_epoch_by_id[$t_key]:-0}"$'\x1f'"${trend_csv_by_id[$t_key]}")
  done
  if [ "${#trend_out_lines[@]}" -gt 0 ]; then
    printf '%s\n' "${trend_out_lines[@]}" > "${subagent_trend_file}.tmp.$$" 2>/dev/null &&
      mv -f "${subagent_trend_file}.tmp.$$" "$subagent_trend_file" 2>/dev/null
  fi
fi

# ---------- PASS 2: build the uniform description budget, pad, emit ----------
# ALIGNMENT FIX: a column that's empty for EVERY row in this payload (e.g.
# token share with only 1 task in the whole payload - correctly never
# shown per the >=2-tasks rule - or no task anywhere having a sparkline)
# used to still render as a padded-blank placeholder + separator on every
# row, producing a stray "| |" double separator with nothing between.
# active_cols lists only the original column indices (0-4) that at least
# ONE row actually used (col_max>0); PASS 2 below renders/pads ONLY
# those, by position within active_cols, not by the original 0-4 index -
# a column no row ever used is dropped entirely, no placeholder cell and
# no separator for it, on any row.
active_cols=()
active_col_width_sum=0
# iteration order IS the display order: index 5 (the standalone model
# cell) deliberately rides SECOND, between identity and spend, without
# renumbering any existing column
for ci in 0 5 1 2 3 4; do
  cw="${col_max[$ci]}"
  if [ "$cw" -gt 0 ]; then
    active_cols+=("$ci")
    active_col_width_sum=$(( active_col_width_sum + cw ))
  fi
done
active_col_count=${#active_cols[@]}
# Description width budget only counts surviving (active) columns and
# their separators (one "|" per active column, description always last).
desc_budget=$(( columns - active_col_width_sum - 3 * active_col_count )); echo "DEBUG active_col_count=$active_col_count active_col_width_sum=$active_col_width_sum desc_budget=$desc_budget active_cols=${active_cols[*]}" >&2

row_total=${#ids[@]}
for ((r=0; r<row_total; r++)); do
  id="${ids[$r]}"

  present0=0; [ -n "${col0_p[$r]}" ] && present0=1
  present1=0; [ -n "${col1_p[$r]}" ] && present1=1
  present2=0; [ -n "${col2_p[$r]}" ] && present2=1
  present3=0; [ -n "${col3_p[$r]}" ] && present3=1
  present4=0; [ -n "${col4_p[$r]}" ] && present4=1
  present5=0; [ -n "${col5_p[$r]}" ] && present5=1

  # description - gray, cut to the UNIFORM budget computed above (same for
  # every row, since alignment pads columns 1-5 to the same widths
  # whenever description follows)
  description="${descriptions[$r]}"
  desc_seg=""
  if [ -n "$description" ] && [ "$desc_budget" -ge 8 ]; then
    disp_width "$description"; desc_disp_len="$REPLY"
    if [ "$desc_disp_len" -gt "$desc_budget" ]; then
      # Cut by accumulated DISPLAY width, not character count: walk
      # characters, keep adding while the running total stays within
      # budget-1 cells (leaving exactly 1 cell for the "…" appended after).
      # PERF: this is per-CHARACTER of the description - the single
      # hottest spot for forks before the REPLY-pattern conversion (a
      # long description could mean dozens of $(disp_width "$dc") forks
      # for ONE cell of ONE row); now zero forks regardless of length.
      target=$(( desc_budget - 1 ))
      desc_chars=${#description}
      acc=0
      cut_pos=0
      for ((di=0; di<desc_chars; di++)); do
        dc="${description:di:1}"
        disp_width "$dc"; dw="$REPLY"
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

  # row_last_idx = highest POSITION WITHIN active_cols (0..active_col_
  # count-1 for mid columns, active_col_count = description) that has
  # real content for this row; only trailing-absent slots past it are
  # dropped, everything up to it renders (empty-padded if absent). A
  # column dropped from active_cols entirely (see PASS 2's own comment
  # above) never becomes a slot for any row, so it can never leave a
  # stray placeholder/separator behind.
  row_last_idx=-1
  for ((ai=0; ai<active_col_count; ai++)); do
    ci="${active_cols[$ai]}"
    case $ci in
      0) [ "$present0" -eq 1 ] && row_last_idx=$ai ;;
      1) [ "$present1" -eq 1 ] && row_last_idx=$ai ;;
      2) [ "$present2" -eq 1 ] && row_last_idx=$ai ;;
      3) [ "$present3" -eq 1 ] && row_last_idx=$ai ;;
      4) [ "$present4" -eq 1 ] && row_last_idx=$ai ;;
      5) [ "$present5" -eq 1 ] && row_last_idx=$ai ;;
    esac
  done
  [ -n "$desc_seg" ] && row_last_idx=$active_col_count

  # N0(b): every emitted content string starts with a literal reset, to
  # defend against host/terminal dim-styling bleeding in from whatever
  # was printed just before this line.
  row="$RESET"
  if [ "$row_last_idx" -ge 0 ]; then
    for ((ai=0; ai<=row_last_idx; ai++)); do
      if [ "$ai" -lt "$active_col_count" ]; then
        ci="${active_cols[$ai]}"
        case $ci in
          0) cell_c="${col0_c[$r]}"; cell_p="${col0_p[$r]}" ;;
          1) cell_c="${col1_c[$r]}"; cell_p="${col1_p[$r]}" ;;
          2) cell_c="${col2_c[$r]}"; cell_p="${col2_p[$r]}" ;;
          3) cell_c="${col3_c[$r]}"; cell_p="${col3_p[$r]}" ;;
          4) cell_c="${col4_c[$r]}"; cell_p="${col4_p[$r]}" ;;
          5) cell_c="${col5_c[$r]}"; cell_p="${col5_p[$r]}" ;;
        esac
        w="${col_max[$ci]}"
      else
        cell_c="$desc_seg"
        cell_p=""
        w=0
      fi
      if [ "$ai" -eq "$row_last_idx" ]; then
        row="${row}${cell_c}"
      else
        disp_width "$cell_p"; plen="$REPLY"
        pad=$(( w - plen ))
        padding=""
        if [ "$pad" -gt 0 ]; then
          printf -v padding '%*s' "$pad" ''
          padding=${padding// /$NBSP}
        fi
        row="${row}${cell_c}${padding}${SEP}"
      fi
    done
  fi
  row="${row}${RESET}"

  # PERF: this is the hottest spot in the whole script (runs once per row
  # per render) - a jq -cn/--arg call here would fork a process per row.
  # JSON string escaping is instead done inline in pure bash (order
  # matters: backslash first, so later-inserted backslashes from the
  # following substitutions are never themselves re-escaped): backslash,
  # then double quote, then ESC (0x1B - the ANSI color codes baked into
  # $id/$row are raw ESC bytes, which JSON forbids unescaped, hence
  #  - a JSON/terminal consumer decodes that back to a real ESC
  # byte, so this is a lossless re-encoding, not a color-stripping step),
  # then tab, then newline. Deliberately NOT a helper function called as
  # $(esc "$x") - that would still fork a subshell per call (bash forks
  # for command substitution even around pure-bash functions), which on
  # Windows/MSYS2 is comparably expensive to spawning an external
  # process and would defeat the point; inlining keeps this row's emit at
  # zero forks.
  esc_id="$id"
  esc_id=${esc_id//\\/\\\\}
  esc_id=${esc_id//\"/\\\"}
  esc_id=${esc_id//$'\e'/\\u001b}
  esc_id=${esc_id//$'\t'/\\t}
  esc_id=${esc_id//$'\n'/\\n}

  esc_row="$row"
  esc_row=${esc_row//\\/\\\\}
  esc_row=${esc_row//\"/\\\"}
  esc_row=${esc_row//$'\e'/\\u001b}
  esc_row=${esc_row//$'\t'/\\t}
  esc_row=${esc_row//$'\n'/\\n}

  printf '{"id":"%s","content":"%s"}\n' "$esc_id" "$esc_row"
done
