#!/bin/bash
# Force a UTF-8 locale: this environment's LANG is empty (POSIX/C locale),
# under which bash's ${#var}, ${var:0:N}, and =~ character classes are all
# BYTE-based, silently over-counting every multibyte glyph used below
# (▸ ● ✓ ✗ · █ ░ ▁-█ … ⎇ » Σ →) and throwing off column alignment. Must be
# set before any string measurement happens (i.e. before every other line
# in this script).
export LC_ALL=C.UTF-8

# PERMANENT ERROR BLACK BOX (not a temp diagnostic - kept intentionally):
# captures every command's real stderr in this script to a single log
# file, append-only, for after-the-fact diagnosis of failures that would
# otherwise be invisible (this is exactly how the fork-exhaustion root
# cause behind the graceful-degradation guard further down was actually
# found - a blank statusline alone gives no clue why).
# SELF-ROTATION: pure-bash line-count heuristic, not a precise byte-size
# check (that would need `stat`/`wc -c`, both external spawns this script
# avoids everywhere else) - reusing the same no-fork `mapfile` file-read
# pattern already used for the history file, count the existing log's
# lines and truncate it to empty (`: > file`, no external `truncate`/
# `cp`) once it passes ~500 lines, a rough proxy for ~64KB rather than an
# exact one. Runs BEFORE the `exec` below opens the append redirect for
# this render, so a rotation this render triggers starts the file fresh
# immediately; checked every render rather than on any schedule, but
# cheap either way since the file is kept capped at ~500 lines by this
# same mechanism.
statusline_err_log="$HOME/.claude/statusline-err.log"
# ROTATION MOVED OFF THE PER-FRAME PATH (round-6): this used to read up
# to 501 log lines on EVERY frame just to decide whether to truncate.
# After a fork storm leaves ~450 lines (~30KB) the file never crosses
# the 500-line trip point, so every later frame paid a measured
# ~60-100ms re-read before rendering even started - a permanent tax
# bought by a check that almost never fires. The truncation now rides
# the rare (~30min) history-rewrite path further down, where a single
# `find -size` test decides it; the blackbox stays bounded, at a
# cadence appropriate for a debug log.
exec 2>>"$statusline_err_log"
# Claude Code status line (detailed layout, ANSI colors, FOUR printed
# lines, column-aligned, narrow-terminal adaptive)
#
# PERFORMANCE: after the jq-missing guard, every stdin field this script
# needs is read via ONE jq invocation into the F[] array (see the mapfile
# block below), not one jq call per field. The git branch+dirty+stash
# check is ONE `git status --porcelain=v2 --branch --show-stash` call
# instead of separate git invocations. TODAY/WEEK TOTAL is a pure-bash scan over the same
# in-memory history rows already loaded for the token-rate/sparkline
# segment - no background job or transcript scan of its own. Almost every
# `date` call has been replaced by bash's own `printf '%(fmt)T' epoch`
# builtin (4.2+, zero process spawns; -1 means "now").
#
# NO-FORK HELPER RETURNS: every pure-bash helper function in this script
# (cost_to_cents, fmt_k_or_m, fmt_small_or_k, disp_width, wk_label_for,
# render_line) writes its result to the global REPLY variable instead of
# printf-to-stdout, and every call site does `fn args; x="$REPLY"` -
# NEVER `x=$(fn args)`. This matters because bash's command substitution
# `$(...)` forks a subshell on MSYS2/Windows (~2.5ms each) even when the
# command inside is a pure-bash function with no external program in it;
# with disp_width() and cost_to_cents() each called per history row / per
# cell / per character in various loops, this was measured as the single
# largest source of forks in this script (thousands/render on a long
# history file) before this conversion. `printf -v var 'fmt' args` (never
# `var=$(printf ...)`) is used the same way for every other formatted
# value, including plain %.0f/%.2f/%*s forms, not just %()T dates. File
# reads that only need one line use `read -r var < file`, not
# `var=$(< file)`, for the same reason.
#
# EXPECTED REMAINING SPAWN INVENTORY per render, after this pass:
#   - jq: exactly 1 (the consolidated F[] extraction)
#   - git: exactly 1 (status --porcelain=v2 --branch --show-stash)
#   - tail+awk: 0 or 1 pipe (N3/N4's shared transcript-tail read AND its
#     line pre-filter in one pipeline; only in wide mode when
#     transcript_path is set, the file exists, and both tools are on
#     PATH - narrow terminals skip the whole block, whose segments they
#     never render)
#   - date: 0 or 1 (N4's ISO-8601 parse; only when the awk stage above
#     actually selected a candidate cache-activity line to parse)
#   - find: 0 or 1, ONLY on the rare (~30min) history full-rewrite path
#     (orphaned .tmp.<pid> sweep) - never on an ordinary frame
#   - cat: 0 - the stdin payload is slurped by the `read -N` chunk-loop
#     builtin, never `$(cat)` (which cost a subshell + a cat exec)
#   - detached background jobs (never block this render, may spawn gh/
#     curl/jq/grep/find internally on their OWN next-render cadence):
#     the PR CI refresh and N2's OAuth usage refresh
# Everything else - every helper call, every %()T/%.Nf/%*s format, every
# single-line file read, every history/tail-row loop - is a bash builtin
# or parameter expansion with zero forks.
#
# NARROW-TERMINAL ADAPTIVE: reads $COLUMNS (set by Claude Code v2.1.153+;
# falls back to 120 if unset/non-numeric). Under 100 columns, the whole
# 4-line aligned grid is replaced by ONE compact line: clock | model name
# only | dir's last path component only | branch(+*) | ctx bar+pct only |
# $cost only | 5h pct only - same colors/omission rules, no alignment
# pass, and the transcript tail block (whose two segments exist only in
# the wide grid) is skipped entirely. 100+ columns: the 4-line grid
# described below, unchanged.
#
# TRUNCATION/OSC-8 SAFETY: this script itself never truncates a segment
# mid-string (the directory abbreviation collapses whole path COMPONENTS,
# never cuts inside one). The only character-level truncation anywhere in
# this statusline pair is the SUBAGENT script's task-description cut, and
# that field never carries an OSC 8 hyperlink - keep it that way: if a
# future segment needs both truncation and a hyperlink, the cut must
# happen only on text outside the OSC_OPEN..OSC_CLOSE span, never inside
# it (an OSC 8 sequence split mid-escape can leave the terminal's
# hyperlink state stuck open for everything printed after it).
#
# Reads the JSON payload once from stdin and (at 100+ columns) prints up
# to FOUR lines to stdout (Claude Code renders each printed line as its
# own status-line row; ANSI colors and OSC 8 hyperlinks work on every
# line). Each line is assembled independently - same colors/per-segment
# omission rules regardless of line - with its own trailing RESET. Line 1
# always has at least the clock, so it always prints; lines 2, 3 and 4
# are skipped ENTIRELY (no blank line) when every one of their segments
# is absent - e.g. a fresh minimal session can render as just line 1 + a
# short line 4, with no lines 2 or 3 at all. The " | " separators are
# COLUMN-ALIGNED across all four lines: every segment tracks a parallel
# plain-text twin (no ANSI, no OSC 8 - hyperlinks and colors are
# zero-width and never factor into alignment) purely for width
# measurement, measured in true terminal DISPLAY cells via disp_width()
# (not raw character count) so East Asian wide/fullwidth text (e.g. in
# session_name, or any repo/branch/worktree name) aligns correctly too;
# see disp_width()'s own comment for the wide-character ranges used and
# the render_line()/col_widths block near the bottom for the actual
# padding logic.
#
# LINE 1 (identity/location), joined with " | ":
#   1  clock time HH:MM:SS (not from stdin; only advances on refresh)  - bright white
#   2  model short id name (panel-synced rule: "claude-" prefix and
#      "-20"+date suffix stripped, a "[1m]"-style capacity tag kept
#      verbatim; falls back to display_name when .model.id is absent)
#      + ·effort + ·think, each part colored individually
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
#   6b stash count: gray "⚑" + count yellow (bright red from 5 up). Rides
#      the SAME single git call as segment 6 (--show-stash): git only
#      emits the "# stash <N>" v2 header when at least one stash entry
#      exists AND git is >=2.35, so zero stashes, non-repo dirs and older
#      gits all hide the segment for free. Deliberately independent of
#      segment 6's branch name: a detached HEAD blanks the branch but
#      stashes still exist and still show.
#   7  PR: "PR#N" magenta, an OSC 8 hyperlink to .pr.url when present
#      (plain text otherwise); review state (if any) stays outside the
#      link and keeps its own dynamic color (approved green /
#      changes_requested bright red / draft gray / other yellow); a
#      cached, non-blocking CI glyph may follow - "✓CI" green (passing),
#      "✗CI" bright red (failing), "●CI" yellow (pending) - from a
#      single-row PER-(repo,PR) cache file
#      ~/.claude/statusline-ci-cache.<owner>-<name>-<pr> entry <60s old
#      (key in the FILENAME: concurrent sessions on different PRs no
#      longer evict each other every frame); otherwise no glyph this
#      render, and a detached `gh pr checks` background job refreshes
#      the cache for next time - writing state "none" (no glyph, no
#      respawn until TTL) when gh returns nothing, so an unauthenticated/
#      offline gh is re-probed once a minute, not once a frame
#   (The former ⚡bypass warning segment was REMOVED 2026-08-13 by
#   explicit user instruction - the host's own "⏵⏵ bypass permissions
#   on" banner carries the same information. Do NOT restore it as
#   "missing/broken"; see the inline comment at its old code site.)
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
#      "N%" dynamic. AUTO-COMPACT MARK (~80% community convention, not an
#      official threshold): cell index 4 (floor(0.8*5), the last cell)
#      renders as a fixed bright-white "│" instead of gray "░" whenever
#      the bar hasn't filled past it yet (filled<=4); omitted once the
#      bar is completely full (filled=5). Each of the two token numbers
#      is formatted
#      independently by fmt_k_or_m(): "<N>k" (white) while under 1000k,
#      else "<N>M" or "<N>.<N>M" (one decimal, omitted when zero) - e.g.
#      1000000 -> "1M", 1500000 -> "1.5M" - with "/" gray between them.
#      (The total_output_tokens read here is unrelated to and unaffected
#      by the removal of the old standalone "out" segment - see below.)
#   9  token rate + sparkline, derived from ~/.claude/statusline-history.tsv
#      (see the history block below); sparkline (cyan) is up to 8
#      consecutive token deltas over the last up-to-9 samples, normalized
#      onto ▁▂▃▄▅▆ (capped at 6 levels, not 8 - ▇/█ are deliberately never
#      used by any sparkline, only by single-line gauges like the ctx
#      battery, so a full-height cell here can never visually fuse with
#      the row above/below it); rate is tokens/min over the last 5
#      minutes, "N/m" or ">=1000/min" as "X.Yk/m", tiered <5000 gray /
#      5000-14999 yellow / >=15000 bright red; either half, or the whole
#      segment, may be absent
#   10 cache hit rate "cache <N.N>%" - gray label; one decimal place, tier
#      by the integer part (>=80 green / 50-79 yellow / <50 bright red);
#      only when current_usage has all of input/cache_creation/cache_read
#      tokens and their sum is > 0; followed by a gray " r<X>·w<Y>" read/
#      write breakdown (fmt_small_or_k: raw integer under 1000, one-
#      decimal-k at/above - e.g. "r435.2k" - never M, unlike fmt_k_or_m),
#      omitted when both read and creation tokens are 0/absent. N4 CACHE
#      FRESHNESS COUNTDOWN (unofficial - TTL is an assumption, not a
#      documented API contract) appends directly to this same segment,
#      space-separated, only when it itself is showing: scans the tail of
#      .transcript_path (see item 10b below) newest-first for the latest
#      assistant/non-sidechain line with nonzero cache activity and a
#      parseable ISO timestamp, then remaining = $STATUSLINE_CACHE_TTL_
#      SECONDS (default 3600) - 5 - (now - that timestamp). UX: an active
#      session keeps re-warming the cache, so a raw countdown sits near
#      TTL almost continuously and reads as frozen rather than healthy -
#      remaining/ttl >0.9 collapses to a static green "hot" instead of a
#      number; below that, the countdown itself - "47m" or "9m42s" white
#      when remaining/ttl >0.5, yellow >0.2, bright red >0, gray "cold" at
#      or below 0. Absent entirely when no candidate line is found. The
#      ISO timestamp needs one `date -d` spawn (no pure-bash ISO parse) -
#      fired only when a candidate was actually found, never per-render.
#   10b compaction counter - gray "↻" + white count of `"subtype":
#      "compact_boundary"` lines (skipping any marked `"isSidechain":
#      true`) seen in the same transcript tail-read as N4 above; when the
#      sum of (preTokens-postTokens) across those boundaries is > 0, a
#      gray " ↓" + white k-or-M-formatted total follows. Hidden when the
#      count is 0. Both this and N4 read from ONE shared tail read (512KiB
#      default, STATUSLINE_TRANSCRIPT_TAIL_BYTES overrides)
#      of .transcript_path - the only two accepted external-process
#      exceptions in this script (see that shared read's own comment for
#      why, and its documented "may miss data outside the tail window"
#      limitation).
#
# (The standalone "out" segment, total_output_tokens shown on its own, has
# been removed entirely - variables, formatting, and its parts2+= entry.)
#
# LINE 3 (spend), joined with " | ":
#   11 session cost: "$" uncolored (plain default foreground, like the "/" in
#      lines changed), amount dynamic (<$1 gray / $1-4 yellow / >=$5 bright
#      red); optionally followed by a space and a history-derived cost rate
#      "$X.Y/h" whose "$" is ALSO uncolored (bare, matching the amount's),
#      with only "X.Y/h" itself in its own dynamic color by whole
#      dollars/hour: <1 gray / 1-4 yellow / >=5 bright red. ZERO-HIDE: the
#      whole segment is hidden when the amount rounds to 0.00 AND no rate
#      is displayable.
#   (TODAY/WEEK TOTAL, right after cost: gray "today"/"week" + white
#   "$X.XX" each - fed by a TWO-TIER store: the fine-grained history
#   file (trimmed to 3h; it only needs to serve sparkline/rate/$-per-
#   hour) plus a tiny per-day rollup file (statusline-daily.tsv) that
#   carries each (day, session)'s monotonic-run spend state forward
#   incrementally (a /clear resets a session's cost column, so a simple
#   max would undercount) - zero spawns, no transcript scanning, and no
#   re-walk of days of rows every render; see the inline comment above
#   their code for the algorithm, the watermark/concurrency story and
#   caveats. TODAY only shows when it exceeds the current session's own
#   cost by >=1 cent; WEEK (last 7 local calendar days incl today) has
#   no such comparison.)
#   12 lines changed +added/-removed - "+" green / "/" uncolored / "-" red.
#      ZERO-HIDE: hidden when added and removed are both 0.
#
# LINE 4 (quota & session), joined with " | ":
#   13 rate limits: "5h"/"7d" label fixed cyan, "N%" dynamic per window (<50
#      green / 50-79 yellow / >=80 bright red), "→reset" white. PACE CURSOR:
#      when resets_at is valid, a gray "·t<N>%" (how far through the window,
#      0-100%, clamped) follows the usage percent before "→reset"; pace =
#      usage% - time%, and pace>=15 forces the usage percent to bright red,
#      0<pace<15 forces at least yellow (never downgrades an already-red
#      tier), pace<=0 leaves the absolute tier alone.
#   (N2 WEEKLY/EXTRA USAGE, right after rate limits: gray "wk" + per-model
#   entries "<CyanLabel><tiered%>" space-joined - the current session's
#   model always shown (when the cache has it), other models only past a
#   50% warning threshold, current first then others descending by usage
#   - followed by gray "extra" + white "$used/$limit" when enabled. Cached
#   + background-refreshed from an UNOFFICIAL API; whole segment absent
#   without a fresh-enough cache entry. See the inline comment above its
#   code for the full cache/refresh/backoff design.)
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
# Full example (four lines):
#   14:32:07 | Fable 5·max·think | ~\proj\webapp | ⎇ wt-fix→main | acme/webapp | main* | PR#42 approved
#   ctx ████│ 71% 294k/1M | ▂▅▆▃ 5.6k/m | cache 82%
#   $0.42 $0.6/h | +156/-23
#   5h 37%·t56%→09:00 7d 12%·t23%→08-15 | wk Fab45% Son67% | » my-session
# Low-context example (line 2 only, illustrating the "!" warning bar):
#   ctx !█░░░│ 12% 176k/200k
# Minimal example (fresh session: line 1 + a bare line 4, no lines 2/3):
#   14:32:07 | Fable 5 | ~
#   » my-session
# (These examples predate the CI glyph/cache r-w/today-week-total
# additions and the narrow-terminal compact line; see each segment's own
# comment above and inline in the code for those. The ctx battery's "│"
# (N5) IS the current rendering, kept accurate; the rate-limit windows'
# "·tNN%" pace cursor shown above is also current (the N1 micro-bar was
# tried and reverted - see item 13's own comment), as is the wk per-model
# restyle. Padding/separator NBSP (N6) is invisible in plain text so
# isn't shown either way. Not
# otherwise kept in perfect sync on every addition, to avoid a wall of
# mutually-inconsistent numbers.)

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

# N6: alignment padding (column-width filler spaces) and the grid
# separator's surrounding spaces use NBSP (U+00A0) instead of a plain
# space, so VSCode-style terminals that trim trailing/run whitespace on
# render can't collapse them and break the column alignment. Semantic
# single spaces INSIDE a segment (e.g. between "5h" and its bar) are
# deliberately left as plain spaces - only these two structural uses are
# affected. disp_width() already counts NBSP as 1 cell (its codepoint,
# 160, falls outside every wide/fullwidth range), so plain-width
# bookkeeping needs no other change.
NBSP=$'\xc2\xa0'

# OSC 8 terminal hyperlinks (experimental - terminals without support just
# render the plain colored text, which is fine). A link is
# OSC_OPEN + url + OSC_CLOSE + <visible text, with its own color codes
# inside as usual> + OSC_OPEN + OSC_CLOSE (an empty-URL open ends the link).
OSC_OPEN=$'\e]8;;'
OSC_CLOSE=$'\e\\'

# Zero-fork stdin slurp, CHUNKED: `$(cat)` cost a subshell + a cat exec
# per render, but the obvious builtin replacement (`read -d ''`) does
# BYTE-AT-A-TIME reads on pipes - measured ~550ms per 100KB on MSYS,
# a regression for big payloads. `read -N` never has to push back past
# a delimiter, so bash buffers its reads: ~114ms for the same 100KB
# (vs ~139ms for $(cat)), with zero spawns. The loop appends full
# 64Ki-char chunks; read returns nonzero at EOF with the final partial
# chunk still delivered, hence the trailing append (an exact-multiple
# payload just appends ""). Multibyte chars can't tear: -N counts
# characters, not bytes, under the UTF-8 locale set above.
input=""
while IFS= read -r -N 65536 slurp_chunk; do input+="$slurp_chunk"; done
input+="$slurp_chunk"

# jq guard: if jq is missing, every segment below is unusable - degrade to
# one line (clock via the bash date builtin, no process spawn) and exit
# cleanly rather than emitting nothing or erroring.
command -v jq >/dev/null 2>&1 || { printf '\e[0m\e[97m%(%H:%M:%S)T\e[0m | statusline: jq missing\n' -1; exit 0; }

# PERF: one jq invocation for the whole script instead of one per field.
# Every field is null-guarded with `// ""` (not `// empty`) so each always
# emits exactly one line, keeping the fixed field order below intact for
# positional mapfile assignment. The output is captured into a variable,
# CR-stripped with a parameter expansion (Windows jq can emit CRLF), then
# split with a herestring `mapfile` - no `tr`/pipe/subshell spawn anywhere
# in this step. The tokenSamples-equivalent concept doesn't exist in this
# script; nothing else needs jq after this block.
jq_main_out=$(jq -r '
  # clean: every STRING field is newline-sanitized IN JQ, because the
  # one-line-per-field protocol below is what positional mapfile mapping
  # rests on - a free-text field (session_name is AI-generated) carrying
  # an embedded LF would otherwise shift every later F[] index, land the
  # sentinel off F[30], and false-trip the "degraded (fork)" line on a
  # perfectly healthy payload, permanently for that session. CR is folded
  # too (the bash-side global CR strip would otherwise eat it anyway).
  # tostring first so a weird non-string value can never make gsub abort
  # the whole extraction. Numeric fields skip this (numbers cannot carry
  # control characters).
  # clean, PANEL-GRADE (round-2 fix): fold tab/LF/CR to a space and
  # STRIP every other C0 outright - the first version only folded
  # CR/LF, so a session_name carrying raw ESC/BEL walked straight
  # into stdout as a working terminal escape (an OSC-0 title
  # injection was demonstrated), and a raw TAB rendered at tabstop
  # width while counting as 1 char in the plain twin, skewing that
  # whole column of col_widths. Same def as the panel renderer.
  # TYPE-SAFE PATHS (round-7): every nested access uses `?` so a
  # container that arrives as a SCALAR or ARRAY (upstream schema
  # drift - `effort` is already a bare scalar in the SUBAGENT payload
  # shape) yields empty for that one field instead of aborting the
  # WHOLE filter with "Cannot index string with ...", which used to
  # truncate the output, knock the sentinel off F[30] and collapse the
  # entire bar into a misleading "degraded (fork)" every single frame.
  # EVERY field gets clean (round-6): "numeric fields cannot carry
  # control chars" only holds if they REALLY are numbers. A host or
  # upstream that ships pr.number (or any numeric field) as a STRING
  # with an embedded newline printed across two lines here, shifted
  # every later F[] index, knocked the __END__ sentinel off F[30] and
  # false-tripped the whole-bar "degraded (fork)" line; pr.number was
  # additionally rendered verbatim with no numeric guard, so raw
  # ESC/BEL in it reached the terminal (the OSC-injection class fixed
  # for session_name in round 2). clean does tostring first, so a real
  # numeric 42 passes through untouched.
  def clean: tostring | gsub("[\t\n\r]"; " ") | gsub("[\u0001-\u001f]"; "");
  (.session_id? // "" | clean),
  (.model?.display_name? // "" | clean),
  (.effort?.level? // "" | clean),
  # `// false` is load-bearing: `.thinking?.enabled?` yields EMPTY (not
  # null) when .thinking is a scalar/array, and `if empty then` prints
  # NO line at all - which shifts every later F[] index, knocks the
  # sentinel off F[30] and collapses the whole bar into "degraded
  # (fork)" every frame. Every field in this list must emit exactly one
  # line, unconditionally.
  (if ((.thinking?.enabled?) // false) == true then "think" else "" end),
  (.workspace?.current_dir? // "" | clean),
  (.workspace?.repo?.owner? // "" | clean),
  (.workspace?.repo?.name? // "" | clean),
  (.workspace?.repo?.host? // "github.com" | clean),
  (.worktree?.name? // "" | clean),
  (.worktree?.branch? // "" | clean),
  (.pr?.number? // "" | clean),
  (.pr?.review_state? // "" | clean),
  (.pr?.url? // "" | clean),
  (.context_window?.remaining_percentage? // "" | clean),
  (.context_window?.total_input_tokens? // "" | clean),
  (.context_window?.context_window_size? // "" | clean),
  (.context_window?.total_output_tokens? // "" | clean),
  (.context_window?.current_usage?.cache_read_input_tokens? // "" | clean),
  (.context_window?.current_usage?.cache_creation_input_tokens? // "" | clean),
  (.context_window?.current_usage?.input_tokens? // "" | clean),
  (.cost?.total_cost_usd? // "" | clean),
  (.cost?.total_lines_added? // "" | clean),
  (.cost?.total_lines_removed? // "" | clean),
  (.rate_limits?.five_hour?.used_percentage? // "" | clean),
  (.rate_limits?.five_hour?.resets_at? // "" | clean),
  (.rate_limits?.seven_day?.used_percentage? // "" | clean),
  (.rate_limits?.seven_day?.resets_at? // "" | clean),
  (.session_name? // "" | clean),
  (.transcript_path? // "" | clean),
  (.model?.id? // "" | clean),
  ("__END__")
' <<< "$input" 2>/dev/null)
jq_main_out=${jq_main_out//$'\r'/}
mapfile -t F <<< "$jq_main_out"

# GRACEFUL DEGRADATION: distinct from the command-v guard above (which
# only catches jq being ABSENT) - this catches jq being PRESENT but its
# spawn failing anyway, e.g. Windows/MSYS2 fork exhaustion under a large
# process tree ("fork: retry: Resource temporarily unavailable"). In that
# case $(jq ...) captures nothing, but a herestring `mapfile` on a truly
# empty string still yields ONE element (an empty string - <<< "" feeds
# just a trailing newline to stdin), never a zero-length array, so
# emptiness alone isn't a reliable signal on its own.
#
# A naive "count the lines" check (even though every field above is
# `// ""`, never `// empty`, specifically to keep the field count fixed)
# is ALSO not reliable by itself, for a subtler reason: bash's $(...)
# command substitution strips ALL trailing newlines from what it
# captures - not just one. If the payload's trailing field(s) (e.g.
# transcript_path, last in the list) are empty, jq's raw output ends in
# multiple consecutive newlines (one ending the last non-empty field's
# line, then one per empty line after it), and $() strips them ALL,
# silently deleting those trailing empty fields before mapfile ever sees
# them - a perfectly healthy jq run then LOOKS short by exactly the
# number of empty trailing fields, which would have produced a false
# "degraded" trigger on totally ordinary payloads (this was caught for
# real: a fixture/payload with no transcript_path tripped it, even
# though jq had run fine).
#
# FIX: a literal, never-empty SENTINEL ("__END__") is appended as one
# more field after the final real field (model.id). Because it can never
# itself be empty, it always survives $()'s trailing-newline stripping
# regardless of how many REAL fields before it were blank - so its
# presence at F[30] is a reliable "jq's output stream reached the end
# intact" signal that the raw line count alone can't give. Degraded when
# EITHER fewer than 31 elements exist (the sentinel and/or other
# trailing fields were stripped entirely - spawn produced too little
# output) OR F[30] isn't literally "__END__" (shouldn't be reachable if
# the count check passed, but costs nothing to also check directly
# rather than trust the count alone). F[0..29] indices are unchanged
# everywhere else in this script.
# Every other internal failure path in this script already degrades to
# omitting a segment, never to dying - this is the one point where a
# totally absent/truncated jq result would otherwise fall through to a
# blank statusline instead of at least one line.
if [ "${#F[@]}" -lt 31 ] || [ "${F[30]}" != "__END__" ]; then
  printf '\e[0m\e[97m%(%H:%M:%S)T\e[0m\e[90m | statusline: degraded (fork)\e[0m\n' -1
  exit 0
fi

session_id="${F[0]}";    model="${F[1]}";      effort="${F[2]}";     thinking="${F[3]}"
dir="${F[4]}";           repo_owner="${F[5]}"; repo_name="${F[6]}"; repo_host="${F[7]}"
wt_name="${F[8]}";       wt_branch="${F[9]}";  pr_number="${F[10]}"; pr_state="${F[11]}"
pr_url="${F[12]}";       remaining="${F[13]}"; in_tokens="${F[14]}"; win_size="${F[15]}"
out_tokens_ctx="${F[16]}"; cache_r="${F[17]}"; cache_w="${F[18]}";  cache_i="${F[19]}"
cost="${F[20]}";         added="${F[21]}";     removed="${F[22]}"
five="${F[23]}";         five_reset="${F[24]}"; week="${F[25]}";   week_reset="${F[26]}"
session_name="${F[27]}"; transcript_path="${F[28]}"; model_id="${F[29]}"

# NUMERIC MAGNITUDE NORMALIZATION (round-6): every numeric field is
# capped at 12 digits AT THE SOURCE, once, instead of at each use site.
# Bash arithmetic is int64: a 17-18 digit token count (each value still
# inside int64, so `[ -gt ]` never errors) made `occupied*100` and
# `cache_r*1000` WRAP AROUND silently - the wrap rendered a full green
# "ctx █████ 100%" all-clear on a payload that was nothing of the sort,
# or a fake "!░░░░│ 0%" alarm, plus 13-digit token text that blew the
# whole 4-line grid's column widths apart. Over-cap values are blanked,
# so the segment disappears (the project's "never render a fake
# reading" line) instead of lying. Same discipline as the {1,3}/{1,9}/
# {1,13} caps on remaining/cost/resets_at.
for _numf in in_tokens win_size out_tokens_ctx cache_r cache_w cache_i added removed; do
  if [ -n "${!_numf}" ] && [[ ! "${!_numf}" =~ ^[0-9]{1,12}$ ]]; then
    printf -v "$_numf" '%s' ""
  fi
done

# model display SYNCED with the panel's naming (user request): when
# .model.id is present, the short id form replaces display_name - strip
# the "claude-" prefix and any "-20"+date suffix, KEEP a trailing
# "[1m]"-style capacity tag verbatim (same rule as the panel's
# short_model). display_name stays as the fallback for id-less payloads;
# both the 4-line grid and the narrow compact line inherit this via the
# one $model variable.
if [ -n "$model_id" ]; then
  model="${model_id#claude-}"
  [[ "$model" =~ ^(.*)-20[0-9]{6}$ ]] && model="${BASH_REMATCH[1]}"
fi

# PERF: bash's printf '%(fmt)T' builtin (bash 4.2+) replaces every `date`
# call in this script - zero process spawns. -1 means "now".
printf -v now_epoch '%(%s)T' -1

# HOME auto-detect: prefer $USERPROFILE (native Windows backslash form;
# forward-slash twin derived by replacing every backslash); if unset, fall
# back to $HOME for both forms (correct as-is on a POSIX box; on a
# hypothetical Windows box missing USERPROFILE, $HOME's own form - usually
# already POSIX-style under Git Bash - is used verbatim rather than
# attempting a POSIX-to-Windows path conversion, since that's an edge case
# this deployment shouldn't hit in practice).
if [ -n "$USERPROFILE" ]; then
  home_bs="$USERPROFILE"
  home_fs="${USERPROFILE//\\//}"
elif [ -n "$HOME" ]; then
  home_bs="$HOME"
  home_fs="$HOME"
else
  home_bs=""
  home_fs=""
fi

# Parses a cost string ("12", "12.5", "12.34...") to integer cents in pure
# bash: no bc/awk. Decimal part is TRUNCATED (not rejected) to exactly 2
# digits - zero-padded if fewer than 2 decimal digits are present
# (including a bare trailing "." with nothing after it, treated as
# ".00") - so a raw payload float with 10+ decimal digits (e.g.
# "1031.5312969999", straight off the live JSON) parses exactly like a
# clean 2-decimal string. Only the INTEGER part's shape is actually
# validated (must be all digits, non-empty) - anything else there is
# rejected outright (return 1, REPLY left empty). 10#$decpart forces
# base-10 so a leading zero (e.g. "05") is never misread as octal.
# (Moved ahead of the history block below since the TODAY/WEEK TOTAL
# computation needs it.)
#
# THIS IS THE ONLY COST-TO-CENTS PARSER IN THE SCRIPT - every consumer
# (the cost-rate segment, TODAY TOTAL, WEEK TOTAL, and the history
# session-filter/append paths that decide whether a cost value is usable
# at all) calls this function directly and uses ITS success/failure as
# the sole validity gate; none of them run a separate regex first. A
# prior version had a redundant `[[ $x =~ ^[0-9]+(\.[0-9]+)?$ ]]` regex
# pre-check at some call sites in addition to this function - textually
# equivalent to this function's own validation at the time, but a second
# copy of the same rule that could silently drift from this one on a
# future edit to either side. Removed; every site below calls this
# function only. The append path also rounds new rows to 2 decimals at
# write time (see hist_cost_now below) so fresh rows are canonical
# cents-precision on disk - but that's a courtesy for readability, not a
# correctness requirement, since this function tolerates any decimal
# length either way (needed regardless, for old rows already on disk).
# NO-FORK RETURN: writes to global REPLY instead of printf+stdout: this is
# called once per history row inside the today/week loops below (up to a
# few hundred times on a long-lived history file) - $(cost_to_cents ...)
# would fork a subshell PER CALL even though the function is pure bash
# (MSYS2 forks for command substitution regardless of what's inside it,
# ~2.5ms each - this was the single largest source of forks measured in
# this script). REPLY is cleared first so a failed call (return 1, e.g.
# unparseable input) never leaks a PREVIOUS call's value to a caller that
# forgets to check the return status - always check `$?`/the function's
# own return value, not just whether REPLY looks numeric, when precision
# matters (every call site below does check).
cost_to_cents() {
  REPLY=""
  local c="$1"
  local intpart decpart
  intpart="${c%%.*}"
  if [[ "$c" == *.* ]]; then
    decpart="${c#*.}"
  else
    decpart=""
  fi
  # {1,9} DIGIT CAP (round-5): this is the ONE parsing gate every cost
  # consumer funnels through (history write, $/h rate, today/week fold),
  # and it was the only numeric gate left uncapped - a 20-digit cost
  # overflowed intpart*100 into a garbage cents value that the rollup
  # then PERMANENTLY closed into closed_cents (9-day retention, no
  # self-heal), and a 12-digit one sailed through display caps into a
  # "week $123456789012.00" render. One cap here covers them all.
  [[ "$intpart" =~ ^[0-9]{1,9}$ ]] || return 1
  decpart="${decpart:0:2}"
  while [ "${#decpart}" -lt 2 ]; do
    decpart="${decpart}0"
  done
  [[ "$decpart" =~ ^[0-9]{2}$ ]] || return 1
  REPLY=$(( intpart * 100 + 10#$decpart ))
}

# --- history state file (used by the token-rate/sparkline and cost-rate
# sub-segments below, and by TODAY/WEEK TOTAL further down): PERF: the
# file is read ONCE via builtin redirection (`mapfile -t hist_all_lines <
# file` - no pipe, no cat/tr spawn; any stray \r is stripped per-line via
# parameter expansion instead of `tr`), then every extraction (this
# session's rows for the rate/sparkline arrays, the append+trim, and
# TODAY/WEEK TOTAL's cross-session scan) is a pure-bash loop over that
# one in-memory array - no awk/grep/cut/tail anywhere below.
#
# $STATUSLINE_HISTORY_FILE (env var, optional): overrides the history
# file path below; default is ~/.claude/statusline-history.tsv. ALL
# history reads/writes/trims (this whole block, plus the append and the
# trim/rewrite further down) go through the one `history_file` variable,
# so setting this env var redirects every one of them together - meant
# for tests/diagnostics to point at an isolated temp path so a real
# session's shared history file is never read, appended to, or
# rewritten by a test run (also sidesteps needing to back up/swap/
# restore the real file around a test, and the race that implies).
#
# CANONICAL ROW FORMAT (writer, below): 4 fields joined by the ASCII Unit
# Separator (0x1F), "epoch<0x1F>session_id<0x1F>tokens<0x1F>cost" -
# written directly via printf's \x1f escape, not tab. BACK-COMPAT
# (reader, both loops below): every line is normalized with
# `line=${line//$'\t'/$'\x1f'}` BEFORE splitting, so pre-this-deploy rows
# (which used a literal tab) parse identically to current rows - one
# 0x1F split handles both formats forever, and the trim/rewrite below
# rewrites the whole file in the canonical 0x1F form on every render that
# appends, so a file self-migrates off tabs within one render cycle.
#
# WHOLE-ROW VALIDATION: split via `read -r -a` into an array and require
# EXACTLY 4 fields before touching ANY of them - a malformed/foreign line
# (wrong delimiter, wrong field count, truncated write) is skipped in its
# entirety rather than letting a partially-parsed field (e.g. a shifted
# value that still happens to satisfy a later numeric regex) leak into a
# sum. Each individual field is then still separately regex-validated
# before use, but only after the row has already passed the shape check.
# All history reads tolerate/skip malformed lines this way - a row only
# counts once its epoch parses as a plain non-negative integer, on top of
# the 4-field shape check. The derived rate/sparkline segments stay
# silently absent while history is too thin for their window - that's
# correct, not an error.
history_file="${STATUSLINE_HISTORY_FILE:-$HOME/.claude/statusline-history.tsv}"
hist_all_lines=()
[ -f "$history_file" ] && mapfile -t hist_all_lines < "$history_file"

tok_epochs=(); tok_values=()
cost_epochs=(); cost_values=()
last_hist_epoch=""

# DAILY ROLLUP STATE LOAD - hoisted ABOVE the fine-row walk so ONE merged
# loop below can fold rows against the watermark while it also collects
# this session's rate/sparkline arrays and the trim set. The old layout
# walked hist_all_lines TWICE (session scan, then trim+rollup), each pass
# repeating the CR/TAB normalization and the 4-field shape check per row
# - measured ~300-700ms of EVERY render on a realistic 3-session
# 1260-row steady-state file, all of it duplicate work. See the TWO-TIER
# STORE comment further down for the file format and the monotonic-run
# state-machine semantics; only the ORDER moved here.
daily_file="${STATUSLINE_DAILY_FILE:-$HOME/.claude/statusline-daily.tsv}"
max_persisted_wm=0
declare -A du_closed du_peak du_prev du_epoch
declare -A du_watermark
printf -v today_str '%(%Y%m%d)T' -1
if [ -f "$daily_file" ]; then
  mapfile -t daily_raw_lines < "$daily_file" 2>/dev/null
  for dline in "${daily_raw_lines[@]}"; do
    dline=${dline//$'\r'/}
    # split via parameter expansions, NOT `read <<<` - a herestring costs
    # ~0.25ms per row on MSYS (same law as the fine-file HOT LOOP below;
    # this loop runs every frame over days x sessions rows)
    d_day=${dline%%$'\x1f'*};   d_rest=${dline#*$'\x1f'}
    d_sid=${d_rest%%$'\x1f'*};  d_rest=${d_rest#*$'\x1f'}
    d_closed=${d_rest%%$'\x1f'*}; d_rest=${d_rest#*$'\x1f'}
    d_peak=${d_rest%%$'\x1f'*};   d_rest=${d_rest#*$'\x1f'}
    d_prev=${d_rest%%$'\x1f'*}
    d_epoch=${d_rest#*$'\x1f'}
    # whole-row shape check, 6 exact columns (5 separators, none left in
    # the last field), every numeric field guarded - malformed/foreign
    # rows dropped whole, same discipline as the fine file's reader below
    [ "$d_prev" = "$d_rest" ] && continue
    [[ "$d_epoch" == *$'\x1f'* ]] && continue
    [[ "$d_day" =~ ^[0-9]{8}$ ]] || continue
    [ -n "$d_sid" ] || continue
    # digit caps (round-5): cents fields at 12 digits (multi-session
    # multi-day sums stay far below; keeps every later addition inside
    # bash integer range even summed), epoch at 13 (same as resets_at)
    [[ "$d_closed" =~ ^[0-9]{1,12}$ ]] || continue
    [[ "$d_peak" =~ ^[0-9]{1,12}$ ]] || continue
    [[ "$d_prev" =~ ^[0-9]{1,12}$ ]] || continue
    [[ "$d_epoch" =~ ^[0-9]{1,13}$ ]] || continue
    # CLOCK-ROLLBACK GUARDS: state stamped in the FUTURE (wall clock
    # stepped back after it was persisted - NTP step correction, VM
    # snapshot restore) is untrustworthy rollback-era output, and it is
    # dropped WHOLE, not patched: the first fix here only zeroed the
    # watermark but kept the row's closed/peak/prev, and the replayed
    # fine rows then walked the monotonic state machine AGAINST that
    # stale state - a replayed value below the stale prev "closed" the
    # stale peak into closed_cents a second time, permanently double-
    # counting today/week. Dropping the whole row makes the replay
    # rebuild that (day, session) from zero - by-design replay-safe;
    # spend older than the fine window may be undercounted for that day,
    # which is the accepted direction (never inflate). A future d_day
    # (only reachable with a hand-forged epoch, since row_day derives
    # from the epoch) is dropped by the same test for the same reason:
    # it would otherwise sit in the week sum as ghost spend for days.
    [ "$d_epoch" -gt $(( now_epoch + 60 )) ] && continue
    [ "$d_day" -gt "$today_str" ] && continue
    dkey="${d_day}"$'\x1f'"${d_sid}"
    du_closed[$dkey]=$d_closed
    du_peak[$dkey]=$d_peak
    du_prev[$dkey]=$d_prev
    du_epoch[$dkey]=$d_epoch
    [ "$d_epoch" -gt "${du_watermark[$d_sid]:-0}" ] && du_watermark[$d_sid]=$d_epoch
    [ "$d_epoch" -gt "$max_persisted_wm" ] && max_persisted_wm=$d_epoch
  done
fi

# One monotonic-run state-machine step for one fine row (semantics: the
# TWO-TIER STORE comment below). A function so the merged walk and the
# just-appended-row path can never drift apart; it is only ever reached
# for rows that already passed the watermark gate (steady state: one or
# two calls per render), keeping bash's function-call overhead off the
# per-row hot path.
fold_daily_row() { # $1=epoch $2=sid $3=cents
  printf -v row_day '%(%Y%m%d)T' "$1"
  dkey="${row_day}"$'\x1f'"$2"
  d_prev=${du_prev[$dkey]:-}
  if [ -z "$d_prev" ]; then
    du_closed[$dkey]=${du_closed[$dkey]:-0}
    du_peak[$dkey]=$3
  elif [ "$3" -lt "$d_prev" ]; then
    du_closed[$dkey]=$(( ${du_closed[$dkey]:-0} + ${du_peak[$dkey]:-0} ))
    du_peak[$dkey]=$3
  else
    [ "$3" -gt "${du_peak[$dkey]:-0}" ] && du_peak[$dkey]=$3
  fi
  du_prev[$dkey]=$3
  du_epoch[$dkey]=$1
  du_watermark[$2]=$1
  daily_dirty=1
}

# RETENTION 90min (round-7, was 3h): the widest consumer window is the
# $/h rate at 60min, so 3 hours of rows were kept purely to be read,
# split and thrown away - and the whole-file `mapfile` split is priced
# per BYTE on MSYS (~2.8-3.5us/B), i.e. a per-frame tax the tail-first
# walk could not remove (it skips PARSING old rows, not SPLITTING
# them). 90min keeps 30min of slack past the widest window.
# Watermark-only step for a row that carries NO parseable cost (the
# payload contract allows a missing total_cost_usd). Round-7 advanced
# the watermark in MEMORY only, but the rollup file is written from the
# du_peak keys that ONLY fold_daily_row creates - so such a session
# never got a row, reloaded at watermark 0 next frame, its rows never
# looked inert, the 3-in-a-row early stop never armed, and every
# session sharing the file paid the full double walk forever (the very
# regression round-7 claimed to fix). A zero-cents row persists the
# watermark; it adds nothing to today/week and leaves the monotonic run
# untouched (prev defaults to 0, so a later real cost row seeds the
# peak exactly as a first observation would).
mark_daily_seen() { # $1=epoch $2=sid
  printf -v row_day '%(%Y%m%d)T' "$1"
  dkey="${row_day}"$''"$2"
  du_closed[$dkey]=${du_closed[$dkey]:-0}
  du_peak[$dkey]=${du_peak[$dkey]:-0}
  du_prev[$dkey]=${du_prev[$dkey]:-0}
  du_epoch[$dkey]=$1
  du_watermark[$2]=$1
  daily_dirty=1
}

hist_time_cutoff=$(( now_epoch - 5400 ))
hist_future_cutoff=$(( now_epoch + 3600 ))
hist_trimmed=()
hist_oldest_epoch=""
daily_dirty=0
# HOT PATH, TAIL-FIRST (round-4, early-stop test REBUILT in round-5):
# every steady-state consumer of this file lives in the TAIL - $/h needs
# 60min, the token rate 5min, the sparkline the last 9 samples, the
# rollup only rows above each session's watermark. Phase 1 walks
# BACKWARDS with a cheap probe per row; phase 2 replays just the
# surviving tail slice FORWARDS through the full parse + arrays + fold
# (the fold state machine is order-sensitive, hence the replay).
#
# The early-stop verdict is PER-ROW against that row's OWN session
# watermark - round 4 used the global minimum watermark across every
# session the rollup knew, but the rollup retains 9 days of (day, sid)
# rows while the fine file holds ~3.5h: ANY session idle longer than
# the fine window (a yesterday session, or one that just went quiet
# today) pinned that minimum below every fine row and the early stop
# NEVER fired on a real machine - the "-30%" win existed only in
# single-session sandboxes while real frames paid a full probe pass ON
# TOP of the full parse. A row is inert iff it is older than the 65min
# consumer horizon AND at-or-below its own sid's watermark; THREE
# consecutive inert rows trigger the stop (the streak absorbs the
# seconds-level epoch interleaving concurrent O_APPEND writers can
# produce - a single inert row mid-tail is not proof the tail ended).
# A row of an unknown sid (watermark 0) can never look inert, so the
# seeding run still scans everything. Probe separators accept BOTH 0x1f
# and legacy TAB (round-5: the epoch-only probe missed the TAB
# normalization the full parser does, so a legacy-format file yielded
# zero valid probes - no oldest epoch -> the rewrite/migration path
# never fired and the file grew to the 10k cap while every frame paid
# a full-file double walk).
hist_scan_horizon=$(( now_epoch - 3900 ))
hist_count=${#hist_all_lines[@]}
hist_tail_start=0
hist_stop_streak=0
for (( hi=hist_count-1; hi>=0; hi-- )); do
  hline=${hist_all_lines[hi]}
  h_epoch=${hline%%[$'\x1f\t']*}
  h_epoch=${h_epoch//$'\r'/}
  [[ "$h_epoch" =~ ^[0-9]+$ ]] || { hist_stop_streak=0; continue; }
  if [ "$h_epoch" -lt "$hist_scan_horizon" ]; then
    h_psid=${hline#*[$'\x1f\t']}
    h_psid=${h_psid%%[$'\x1f\t']*}
    if [ -n "$h_psid" ] && [ "$h_epoch" -le "${du_watermark[$h_psid]:-0}" ]; then
      hist_stop_streak=$(( hist_stop_streak + 1 ))
      if [ "$hist_stop_streak" -ge 3 ]; then
        hist_tail_start=$(( hi + 1 ))
        break
      fi
      continue
    fi
  fi
  hist_stop_streak=0
done
# oldest VALID epoch, for the rewrite-due decision: probe forward from
# the head - the first few rows suffice (a bounded 20-row cap keeps a
# pathological all-garbage head from re-importing a full scan)
hist_probe_failed=0
for (( hi=0; hi<hist_count && hi<20; hi++ )); do
  h_epoch=${hist_all_lines[hi]%%[$'\x1f\t']*}
  h_epoch=${h_epoch//$'\r'/}
  if [[ "$h_epoch" =~ ^[0-9]+$ ]] && [ "$h_epoch" -le "$hist_future_cutoff" ]; then
    hist_oldest_epoch="$h_epoch"
    break
  fi
done
# probe found nothing usable in the head (all 20 rows garbage or
# future-stamped - the natural end state of a clock jump forward
# followed by an NTP correction): remember it explicitly, because the
# append path below defaults hist_oldest_epoch to now_epoch, which
# would otherwise read as "brand new file" and disable trimming for
# good (only the 10000-row cap left).
[ -z "$hist_oldest_epoch" ] && [ "$hist_count" -gt 0 ] && hist_probe_failed=1
for (( hi=hist_tail_start; hi<hist_count; hi++ )); do
  hline=${hist_all_lines[hi]}
  hline=${hline//$'\r'/}
  hline=${hline//$'\t'/$'\x1f'}
  h_epoch=${hline%%$'\x1f'*}
  h_rest=${hline#*$'\x1f'}
  h_sid=${h_rest%%$'\x1f'*}
  h_rest2=${h_rest#*$'\x1f'}
  h_tok=${h_rest2%%$'\x1f'*}
  h_cost=${h_rest2#*$'\x1f'}
  [[ "$hline" != *$'\x1f'* ]] && continue
  [[ "$h_rest" != *$'\x1f'* ]] && continue
  [[ "$h_rest2" != *$'\x1f'* ]] && continue
  [[ "$h_cost" == *$'\x1f'* ]] && continue
  [[ "$h_epoch" =~ ^[0-9]+$ ]] || continue
  # CLOCK-ROLLBACK GUARD: rows stamped >1h in the future (wall clock
  # stepped back since they were written) are dropped whole - folding
  # them would book their spend onto a future day and re-poison the
  # watermark the guard above just reset.
  [ "$h_epoch" -gt "$hist_future_cutoff" ] && continue

  # this session's rate/sparkline arrays + the throttle's last epoch
  if [ -n "$session_id" ] && [ "$h_sid" = "$session_id" ]; then
    last_hist_epoch="$h_epoch"
    if [[ "$h_tok" =~ ^[0-9]+$ ]]; then
      tok_epochs+=("$h_epoch")
      tok_values+=("$h_tok")
    fi
    # Validity is decided by actually calling cost_to_cents (the one
    # shared cost parser - see its own comment), not a separate regex:
    # the only gate a cost value goes through anywhere in this script,
    # so it can never diverge from what the rate/today/week consumers
    # get when they parse the SAME stored string later. Handles old 3+
    # decimal rows (cost_to_cents truncates, never rejects) identically
    # to freshly-written 2-decimal ones.
    if cost_to_cents "$h_cost"; then
      cost_epochs+=("$h_epoch")
      cost_values+=("$h_cost")
    fi
  fi

  # daily-rollup fold (ALL sessions): the watermark gate runs BEFORE any
  # cost parsing, so rows already folded on an earlier render cost just
  # these two tests - in steady state each render folds only the handful
  # of rows that appeared since its previous render.
  [ -z "$h_sid" ] && continue
  [ "$h_epoch" -le "${du_watermark[$h_sid]:-0}" ] && continue
  # A cost-less row contributes nothing to the rollup, but its
  # watermark MUST still advance (round-7): "skip without advancing"
  # meant one payload without .cost.total_cost_usd pinned that
  # session's watermark at 0 forever, so its rows never looked inert,
  # the 3-in-a-row early-stop streak never completed, and EVERY
  # session sharing the file paid a full-file double walk on every
  # frame, permanently (+82% frame time measured). Re-folding it later
  # is impossible anyway - the parse failure is deterministic.
  if cost_to_cents "$h_cost"; then
    fold_daily_row "$h_epoch" "$h_sid" "$REPLY"
  else
    mark_daily_seen "$h_epoch" "$h_sid"
  fi
done

if [ -n "$session_id" ]; then

  # Sampling throttle: at most one history row per session every 30s,
  # REGARDLESS of refresh cadence (at the default 10s interval that's
  # one row every third render). Each sparkline bar therefore spans ~30s
  # of token change (full chart ~4.5min), and the rate segment's >=60s
  # span gate arms after ~3 samples (~1 min).
  should_append=1
  if [ -n "$last_hist_epoch" ]; then
    hist_age=$(( now_epoch - last_hist_epoch ))
    # negative age = the wall clock stepped backwards past the last row
    # (CLOCK-ROLLBACK GUARD, same family as the rollup's): treat it as
    # due-now rather than freezing sampling until the clock re-passes the
    # stale epoch.
    [ "$hist_age" -ge 0 ] && [ "$hist_age" -lt 30 ] && should_append=0
  fi

  if [ "$should_append" -eq 1 ]; then
    if [[ "$in_tokens" =~ ^[0-9]+$ ]] && [ "$in_tokens" -gt 0 ] && [[ "$win_size" =~ ^[0-9]+$ ]] && [ "$win_size" -gt 0 ]; then
      hist_out_n=0
      [[ "$out_tokens_ctx" =~ ^[0-9]+$ ]] && hist_out_n="$out_tokens_ctx"
      hist_tokens_now=$(( in_tokens + hist_out_n ))
    else
      hist_tokens_now="$in_tokens"
    fi
    # Rounded to 2 decimals at write time (canonical cents precision) -
    # the live payload's cost is a raw float and can carry 10+ decimal
    # digits; every reader-side consumer already tolerates arbitrary
    # decimal length via cost_to_cents's own truncation (see its comment),
    # so this isn't strictly required for correctness, but keeps new rows
    # short/clean and matches history rows written by any older/other
    # tool that already used 2-decimal costs. Guarded so a non-numeric or
    # absent $cost still leaves the field empty (omitted), not "0.00".
    hist_cost_now=""
    if [[ "$cost" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      printf -v hist_cost_now '%.2f' "$cost"
    fi
    printf -v new_hist_line '%s\x1f%s\x1f%s\x1f%s' "$now_epoch" "$session_id" "$hist_tokens_now" "$hist_cost_now"
    # reflect the just-appended row in the in-memory rate/sparkline
    # arrays AND the rollup fold - the old second walk saw it by
    # re-walking hist_all_lines post-append; the tail walk above ran
    # pre-append, so the new row steps in here instead (fold_daily_row
    # is the same state-machine code path). The trim collection is built
    # on demand inside the rare rewrite path below.
    [ -z "$hist_oldest_epoch" ] && hist_oldest_epoch="$now_epoch"
    if [[ "$hist_tokens_now" =~ ^[0-9]+$ ]]; then
      tok_epochs+=("$now_epoch")
      tok_values+=("$hist_tokens_now")
    fi
    if cost_to_cents "$hist_cost_now"; then
      cost_epochs+=("$now_epoch")
      cost_values+=("$hist_cost_now")
      fold_daily_row "$now_epoch" "$session_id" "$REPLY"
    fi
  fi
fi

# TODAY/WEEK TOTAL + HISTORY TRIM + DAILY ROLLUP: all fed by the ONE
# merged walk above (plus the just-appended-row step) - zero extra
# spawns, zero extra passes. This comment block stays here as the
# authoritative spec for the rollup file and its state machine.
#
# TWO-TIER STORE (perf): the fine rows only need to serve the sparkline
# (last ~3min), token rate (5min window) and $/h (60min window), so the
# fine file is trimmed to 3 HOURS (was 8 days). The spend scopes that DID
# need days of data (today/week) read a tiny per-day rollup file instead
# of re-walking days of fine rows every render: at the old retention a
# long-lived multi-session file approached the 50k-row cap, and this
# loop's per-row herestring split alone would have added hundreds of ms
# to EVERY render. Steady state now: fine file ~1k rows, rollup dozens.
#
# ROLLUP FILE (statusline-daily.tsv, override: $STATUSLINE_DAILY_FILE):
# one row per (local day, session):
#   day<0x1F>sid<0x1F>closed_cents<0x1F>peak_cents<0x1F>prev_cents<0x1F>last_epoch
# = the MONOTONIC-RUN state machine for that day+session, carried across
# renders: a session's cost column is a running total that /clear resets
# mid-session, so a plain max would undercount - a value LOWER than prev
# closes the open run (its peak folds into closed_cents) and starts a new
# run at the lower value; display total = closed + peak. Same algorithm
# the old in-loop scan used, now incremental instead of recomputed.
#
# last_epoch is the WATERMARK that makes this replay-safe and concurrency-
# self-healing: each render folds ONLY fine rows newer than the sid's
# watermark into the state, so re-walking old rows can never double-close
# a run; when two sessions rewrite the shared rollup at the same tick
# (per-PID tmp + atomic mv, last-writer-wins), the loser's folds are
# simply re-done from the still-present fine rows on the next render.
# SEEDING IS THE SAME CODE PATH, not a special case: missing rollup file
# = empty state + zero watermarks = the first render folds every fine row
# it has (up to 8 days' worth on the first post-upgrade run) and writes
# the seeded rollup.
#
# SEMANTICS: today = sum over sessions of closed+peak for today's local
# YYYYMMDD; week = the same summed over the last 7 LOCAL CALENDAR DAYS
# including today (day granularity replaces the old rolling 604800s
# window - an edge day is now wholly in or wholly out). A session's first
# observation of a day seeds that day's run at the full cumulative value
# (same straddle behavior as the old per-day scan). TODAY only shows when
# its sum exceeds THIS session's own cost by >= 1 cent (avoids redundancy
# with the cost segment right before it); WEEK has no such comparison.
# Caveat (unchanged): only sessions that actually rendered within a scope
# are counted - today and week are independent sums, not halves.

today_total_cents=0
week_total_cents=0
printf -v week_first_str '%(%Y%m%d)T' "$(( now_epoch - 518400 ))"
for dkey in "${!du_peak[@]}"; do
  d_day="${dkey%%$'\x1f'*}"
  d_total=$(( ${du_closed[$dkey]:-0} + ${du_peak[$dkey]:-0} ))
  [ "$d_day" = "$today_str" ] && today_total_cents=$(( today_total_cents + d_total ))
  [ "$d_day" -ge "$week_first_str" ] && week_total_cents=$(( week_total_cents + d_total ))
done

# Rollup rewrite - only on renders that actually folded something new.
# Retention: 9 local days (7-day week window + margin); the row count is
# naturally tiny (days x sessions), no cap needed.
# PERSIST THROTTLE (round-5): folding marks the state dirty on EVERY
# sampling frame (~30s), which made this rewrite a per-sampling-frame
# tmp+mv fork pair that the documented frame budget never accounted
# for. The rollup is REPLAY-SAFE by construction (a lost write is
# rebuilt from the still-present fine rows on the next render, and
# folding always happens in the same frame BEFORE any trim could drop
# those rows), so persistence can lag: only write when the newest
# in-memory watermark has moved >=300s past what disk already has
# (max_persisted_wm, collected at load). Seeding (empty file, max 0)
# still writes immediately. Worst case on a crash: <=300s of folds
# replayed next render - zero data loss.
daily_persist_due=0
if [ "$daily_dirty" -eq 1 ]; then
  daily_mem_max=0
  for _pk in "${!du_epoch[@]}"; do
    [ "${du_epoch[$_pk]}" -gt "$daily_mem_max" ] && daily_mem_max=${du_epoch[$_pk]}
  done
  [ $(( daily_mem_max - max_persisted_wm )) -ge 300 ] && daily_persist_due=1
  [ "$max_persisted_wm" -eq 0 ] && daily_persist_due=1
fi
if [ "$daily_persist_due" -eq 1 ]; then
  printf -v daily_keep_str '%(%Y%m%d)T' "$(( now_epoch - 777600 ))"
  # SETTLED-DAY MERGE (round-7): rows are keyed (day, session_id) and a
  # fresh session id is minted every time Claude Code starts, so this
  # file grew with USAGE, not with days - "days x sessions, no cap"
  # was wrong (measured: 450 rows added ~350ms to EVERY frame, since
  # each row is re-parsed per render). Days older than yesterday can
  # no longer receive folds (the fine window is 90min), so their rows
  # collapse into ONE row per day under the reserved sid "_agg"
  # carrying the summed cents; today and yesterday stay per-session
  # for the live state machine. A 500-row cap backstops the rest.
  SEP1=$''
  printf -v daily_settled_str '%(%Y%m%d)T' "$(( now_epoch - 172800 ))"
  declare -A daily_agg
  daily_out_lines=()
  for dkey in "${!du_peak[@]}"; do
    d_day="${dkey%%$''*}"
    d_sid="${dkey#*$''}"
    [ "$d_day" -ge "$daily_keep_str" ] || continue
    if [ "$d_day" -lt "$daily_settled_str" ]; then
      daily_agg[$d_day]=$(( ${daily_agg[$d_day]:-0} + ${du_closed[$dkey]:-0} + ${du_peak[$dkey]:-0} ))
      continue
    fi
    daily_out_lines+=("${d_day}"$''"${d_sid}"$''"${du_closed[$dkey]:-0}"$''"${du_peak[$dkey]:-0}"$''"${du_prev[$dkey]:-0}"$''"${du_epoch[$dkey]:-0}")
  done
  for d_day in "${!daily_agg[@]}"; do
    daily_out_lines+=("${d_day}"$''"_agg"$''"${daily_agg[$d_day]}"$''"0"$''"0"$''"0")
  done
  # NO BLIND TAIL SLICE (round-10): the old cap kept the LAST 500 entries
  # of a bash associative-array walk, i.e. HASH order - it silently
  # dropped live today/yesterday per-session state rows (closed/peak/
  # prev), which have no rebuild path once the 90min fine window rolls,
  # so today/week shrank permanently and invisibly. Instead: a row whose
  # own watermark predates the fine window can never receive another
  # fold, so its state is FINAL and merges into that day's _agg row -
  # the file is bounded by ACTIVE sessions, not lifetime session count,
  # and not one cent is lost.
  if [ "${#daily_out_lines[@]}" -gt 400 ]; then
    declare -A daily_agg2
    daily_keep_lines=()
    for dl in "${daily_out_lines[@]}"; do
      dl_day=${dl%%$SEP1*}
      dl_rest=${dl#*$SEP1}
      dl_sid=${dl_rest%%$SEP1*}
      dl_ep=${dl##*$SEP1}
      if [ "$dl_sid" != "_agg" ] && [[ "$dl_ep" =~ ^[0-9]+$ ]] && [ "$dl_ep" -lt "$(( now_epoch - 7200 ))" ]; then
        dl_r2=${dl_rest#*$SEP1}
        dl_closed=${dl_r2%%$SEP1*}
        dl_r3=${dl_r2#*$SEP1}
        dl_peak=${dl_r3%%$SEP1*}
        daily_agg2[$dl_day]=$(( ${daily_agg2[$dl_day]:-0} + ${dl_closed:-0} + ${dl_peak:-0} ))
      else
        daily_keep_lines+=("$dl")
      fi
    done
    for dl_day in "${!daily_agg2[@]}"; do
      daily_keep_lines+=("${dl_day}${SEP1}_agg${SEP1}${daily_agg2[$dl_day]}${SEP1}0${SEP1}0${SEP1}0")
    done
    daily_out_lines=("${daily_keep_lines[@]}")
  fi
  if [ "${#daily_out_lines[@]}" -gt 0 ]; then
    printf '%s\n' "${daily_out_lines[@]}" > "${daily_file}.tmp.$$" 2>/dev/null && mv -f "${daily_file}.tmp.$$" "$daily_file" 2>/dev/null
  fi
fi

# APPEND-FIRST WRITE: a full trim+rewrite used to run on EVERY appending
# render (~25KB tmp+mv every 20s per session) even though it only added
# one row - and in steady state the 3h cutoff expires roughly one row per
# tick, so "rewrite whenever anything expired" would still rewrite every
# time. Instead the on-disk file gets 30min of SLACK past the 3h read
# window (every consumer filters by its own window, so stale-but-present
# rows cost nothing), and the full rewrite runs only when the oldest row
# exceeds window+slack (~every 30min) or the row cap trips; malformed
# rows just wait for that pass (they're skipped at read time anyway).
# Between rewrites the new row goes out as ONE O_APPEND write, which
# concurrent sessions interleave safely - and a rare rewrite clobbering
# a concurrent append now costs one sparkline point at worst (the spend
# is already carried by the rollup), ~90x less often than the old
# every-tick rewrite race.
if [ -n "$session_id" ] && [ "$should_append" -eq 1 ]; then
  hist_rewrite_due=0
  [ -n "$hist_oldest_epoch" ] && [ $(( now_epoch - hist_oldest_epoch )) -gt 7200 ] && hist_rewrite_due=1
  # probe found NOTHING usable in the first 20 rows (e.g. a clock jump
  # forward wrote future-stamped rows, then the clock was corrected -
  # every head row now reads as future): force the rewrite instead of
  # falling back to "oldest = now", which pinned the age test at 0 and
  # disabled trimming forever, leaving only the 10000-row cap. The
  # rewrite itself discards future rows, so one frame self-heals.
  [ "$hist_probe_failed" -eq 1 ] && hist_rewrite_due=1
  [ "$hist_count" -gt 10000 ] && hist_rewrite_due=1
  if [ "$hist_rewrite_due" -eq 1 ]; then
    # ON-DEMAND TRIM WALK (round-4): the every-frame loop no longer
    # collects the trim set (it stops at the consumer horizon - see the
    # tail-first comment above); this full-file pass runs ONLY here, on
    # the ~30min rewrite cadence, where its cost was always budgeted.
    # Same normalization + whole-row shape checks as the tail walk.
    for hline in "${hist_all_lines[@]}"; do
      hline=${hline//$'\r'/}
      hline=${hline//$'\t'/$'\x1f'}
      h_epoch=${hline%%$'\x1f'*}
      h_rest=${hline#*$'\x1f'}
      h_rest2=${h_rest#*$'\x1f'}
      h_cost=${h_rest2#*$'\x1f'}
      [[ "$hline" != *$'\x1f'* ]] && continue
      [[ "$h_rest" != *$'\x1f'* ]] && continue
      [[ "$h_rest2" != *$'\x1f'* ]] && continue
      [[ "$h_cost" == *$'\x1f'* ]] && continue
      [[ "$h_epoch" =~ ^[0-9]+$ ]] || continue
      [ "$h_epoch" -gt "$hist_future_cutoff" ] && continue
      [ "$h_epoch" -ge "$hist_time_cutoff" ] && hist_trimmed+=("$hline")
    done
    hist_trimmed+=("$new_hist_line")
    hist_trimmed_count=${#hist_trimmed[@]}
    if [ "$hist_trimmed_count" -gt 10000 ]; then
      hist_trimmed=("${hist_trimmed[@]: -10000}")
    fi
    # Per-PID tmp name: two concurrent sessions rewriting at the same tick
    # collided on a shared fixed ".tmp" (Windows: "Device or resource
    # busy", loser dropped its freshly-appended row). Same $$ pattern as
    # the CI/usage cache writers below; the mv stays atomic either way.
    printf '%s\n' "${hist_trimmed[@]}" > "${history_file}.tmp.$$" 2>/dev/null && mv -f "${history_file}.tmp.$$" "$history_file" 2>/dev/null
    # ORPHAN SWEEP, riding this same rare (~30min) path: a render killed
    # by the host's cancel rule between "> tmp.$$" and its mv strands a
    # .tmp.<pid> forever ($$ never repeats usefully), and NOTHING else
    # ever matched those names - they accumulated monotonically. One
    # `find` spawn per ~30min per session is inside the fork budget; the
    # 30min age floor guarantees a concurrent session's in-flight tmp
    # (seconds old at most) can never be swept. Scoped to the state
    # files' own directory so test isolation (env-overridden paths)
    # sweeps its own sandbox, never the real ~/.claude.
    hist_state_dir="${history_file%/*}"
    [ "$hist_state_dir" = "$history_file" ] && hist_state_dir="."
    find "$hist_state_dir" -maxdepth 1 -name 'statusline-*.tmp.*' -mmin +30 -delete 2>/dev/null
    # blackbox rotation rides this same rare path (see the note at the
    # top of the script): one size test, no per-frame cost
    if [ -n "$(find "${statusline_err_log%/*}" -maxdepth 1 -name "${statusline_err_log##*/}" -size +64k -print -quit 2>/dev/null)" ]; then
      : > "$statusline_err_log" 2>/dev/null
    fi
  else
    printf '%s\n' "$new_hist_line" >> "$history_file" 2>/dev/null
  fi
fi

current_cost_cents=0
if [ -n "$cost" ] && cost_to_cents "$cost"; then
  current_cost_cents="$REPLY"
fi
today_seg=""
today_plain=""
if [ "$today_total_cents" -gt 0 ] && [ "$(( today_total_cents - current_cost_cents ))" -ge 1 ]; then
  printf -v today_fmt '%d.%02d' "$(( today_total_cents / 100 ))" "$(( today_total_cents % 100 ))"
  today_seg="${GRAY}today${RESET} ${WHITE}\$${today_fmt}${RESET}"
  today_plain="today \$${today_fmt}"
fi
week_seg=""
week_plain=""
if [ "$week_total_cents" -gt 0 ]; then
  printf -v week_fmt '%d.%02d' "$(( week_total_cents / 100 ))" "$(( week_total_cents % 100 ))"
  week_seg="${GRAY}week${RESET} ${WHITE}\$${week_fmt}${RESET}"
  week_plain="week \$${week_fmt}"
fi

# Formats a raw token count as "<N>k" (as before) unless that would be
# >=1000k, in which case it switches to "<N>M" / "<N>.<N>M" (one decimal,
# omitted when zero). m10 is computed directly from the raw count via a
# single division (not from the already-rounded k value) to avoid
# compounding truncation error, matching the rounding style used elsewhere
# in this script (e.g. the burn-rate segments' rate10).
# NO-FORK RETURN: writes to global REPLY - see cost_to_cents's comment
# above for why (every pure-bash helper in this script follows the same
# pattern; call sites do `fmt_k_or_m "$n"; x="$REPLY"`, never
# `x=$(fmt_k_or_m "$n")`).
fmt_k_or_m() {
  REPLY=""
  local n="$1"
  local k=$(( (n + 500) / 1000 ))
  if [ "$k" -ge 1000 ]; then
    local m10=$(( (n + 50000) / 100000 ))
    local whole=$(( m10 / 10 ))
    local frac=$(( m10 % 10 ))
    if [ "$frac" -eq 0 ]; then
      REPLY="${whole}M"
    else
      REPLY="${whole}.${frac}M"
    fi
  else
    REPLY="${k}k"
  fi
}

# For the cache r/w suffix ONLY (ctx battery and token-count formatting
# elsewhere keep using fmt_k_or_m unchanged): raw integer under 1000
# (k-rounding a small count like 0 or 312 read as broken - e.g. "w0k"),
# one-decimal-k (never switching to M - this value is small/bounded
# enough that M-form isn't useful here) at/above 1000, e.g. "435.2k".
# Integer math only: v10 = n*10/1000. NO-FORK RETURN via REPLY, same as
# fmt_k_or_m above.
fmt_small_or_k() {
  REPLY=""
  local n="$1"
  if [ "$n" -lt 1000 ]; then
    REPLY="$n"
  else
    local v10=$(( n * 10 / 1000 ))
    REPLY="$(( v10 / 10 )).$(( v10 % 10 ))k"
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
# NO-FORK RETURN via global REPLY (see cost_to_cents's comment above) -
# this is the single most-called helper in the script (every segment's
# plain-width measurement, every column-width computation), so
# $(disp_width ...) forking a subshell per call was a major contributor
# to the fork count; call sites now do `disp_width "$s"; w="$REPLY"`.
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

# 1. clock (not from stdin) - bright white
printf -v clock '%(%H:%M:%S)T' -1
clock_plain="$clock"
[ -n "$clock" ] && clock="${WHITE_BRIGHT}${clock}${RESET}"

# 2. model + effort + thinking markers, each part colored individually:
# name bright cyan, · separators gray, effort level dynamic "heat" (low gray,
# medium green, high yellow, xhigh bright magenta, max bright red, any other
# value yellow), think marker magenta. No effort -> no ·effort part; thinking
# not true -> no ·think part; model alone renders as just the cyan name.
# (model/effort/thinking already extracted by the consolidated jq call above)
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
# (dir already extracted by the consolidated jq call above; home_bs/home_fs
# are set by the HOME auto-detect block above too)
dir_display="$dir"
dir_lc="${dir_display,,}"
# BOUNDARY CHECK on the prefix match: the character right after the home
# prefix must be a path separator (either kind) or end-of-string -
# otherwise a SIBLING profile that merely starts with the home string
# (domain-joined Windows: C:\Users\Administrator.DOMAIN next to
# C:\Users\Administrator is routine) would be lied about as "~.DOMAIN\...",
# i.e. shown as inside the home directory when it isn't.
if [[ "$dir_lc" == "${home_bs,,}"* ]]; then
  home_rest="${dir_display:${#home_bs}}"
  if [ -z "$home_rest" ] || [[ "$home_rest" == [\\/]* ]]; then
    dir_display="~${home_rest}"
  fi
elif [[ "$dir_lc" == "${home_fs,,}"* ]]; then
  home_rest="${dir_display:${#home_fs}}"
  if [ -z "$home_rest" ] || [[ "$home_rest" == [\\/]* ]]; then
    dir_display="~${home_rest}"
  fi
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
# (wt_name/wt_branch already extracted by the consolidated jq call above)
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
# (repo_owner/repo_name/repo_host already extracted by the consolidated jq
# call above)
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
# --no-optional-locks keeps this read-only and fast. PERF: still ONE git
# call (`status --porcelain=v2 --branch --show-stash`), now also carrying
# the stash count for segment 6b. v2 output shape: header lines first
# ("# branch.oid <sha|(initial)>", "# branch.head <name|(detached)>",
# optional "# branch.upstream ..."/"# branch.ab ..."/"# stash <N>"), then
# one non-"#" line per changed/untracked path. "# branch.head" gives the
# BARE branch name - no "...upstream" decoration to strip, unlike the old
# v1 "## " line - with "(detached)" mapping to empty (matching `git
# branch --show-current`'s empty-on-detached-HEAD behavior) and unborn
# branches ("No commits yet") still named normally. The first non-"#"
# line means the tree is dirty (untracked included, same signal v1 gave);
# headers always precede entry lines, so the parse loop breaks right
# there and never walks the rest of a big dirty tree's entry list.
# Branch name is always green; a dirty "*" is appended as its own yellow
# token.
# FAILURE SAFETY (confirmed, no change needed): branch/branch_plain/
# stash_count are already initialized empty just below, BEFORE this call -
# if the git spawn itself fails (already stderr-silenced by 2>/dev/null;
# same fork-exhaustion class of failure the jq guard above now handles),
# $git_status_out is simply empty, the `if` below is skipped entirely,
# and they all stay at their empty defaults - the rest of the script
# continues normally with the branch and stash segments omitted, same as
# any other optional segment whose data isn't available. Nothing here can
# abort the script.
branch=""
branch_plain=""
stash_count=""
# [ -n "$dir" ] gate: `git -C ""` is defined by git as "don't change
# directory", so a payload with no workspace.current_dir would run
# status in whatever CWD the host launched this script from and float
# an unrelated repo's branch/dirty/stash onto line 1 (while the
# directory segment itself correctly disappeared) - empty dir must mean
# NO git segments, same silent-omission rule as every other segment.
git_status_out=""
[ -n "$dir" ] && git_status_out=$(git -C "$dir" --no-optional-locks status --porcelain=v2 --branch --show-stash 2>/dev/null)
if [ -n "$git_status_out" ]; then
  # PERF: everything this block needs lives in the header lines (which
  # always precede entry lines) plus "does ANY entry line exist" - but a
  # big dirty tree (vendor drop, mass refactor) can push the full
  # porcelain output into the hundreds of KB, and `mapfile <<<` splits
  # at a measured ~3.5us PER BYTE on MSYS (1-2s per frame at that size,
  # for an array the old loop then abandoned at its first entry line).
  # So: take a fixed 2KiB head slice (headers are <1KiB even with long
  # branch/upstream names; the first entry line therefore always starts
  # inside the slice when one exists at all) and walk ITS lines with
  # parameter expansions - bounded cost regardless of tree size. An
  # entry line cut mid-way by the slice still answers the only question
  # asked of it (a non-"#" line exists => dirty).
  gs_head=${git_status_out:0:2048}
  gs_head=${gs_head//$'\r'/}
  git_dirty=0
  while :; do
    git_line=${gs_head%%$'\n'*}
    case "$git_line" in
      "# branch.head (detached)") ;;
      "# branch.head "*) branch="${git_line#"# branch.head "}" ;;
      "# stash "*)
        stash_count="${git_line#"# stash "}"
        [[ "$stash_count" =~ ^[0-9]+$ ]] || stash_count=""
        ;;
      "#"*) ;;
      ?*) git_dirty=1 ;;
    esac
    [ "$git_dirty" -eq 1 ] && break
    [ "$git_line" = "$gs_head" ] && break
    gs_head=${gs_head#*$'\n'}
  done
  if [ -n "$branch" ]; then
    branch_plain="$branch"
    branch="${GREEN}${branch}${RESET}"
    if [ "$git_dirty" -eq 1 ]; then
      branch="${branch}${YELLOW}*${RESET}"
      branch_plain="${branch_plain}*"
    fi
  fi
fi

# 6b. git stash count, riding the SAME single git call above
# (--show-stash): gray "⚑" flag + count, count yellow normally and
# bright red from 5 up (that many parked changes usually means forgotten
# work). git only prints the "# stash <N>" header when at least one
# stash entry exists (verified: no "# stash 0" line is ever emitted) and
# only on git >=2.35 (older gits silently ignore --show-stash with
# porcelain v2), so an empty stash_count already covers the zero-stash/
# non-repo/old-git cases - the -gt 0 test below is belt-and-suspenders
# for a hypothetical git that DID emit a zero line (stash_count is
# regex-guarded numeric at parse time, so the arithmetic test is safe).
# NOT part of the narrow-mode compact line, which keeps its documented
# minimal segment set.
stash_seg=""
stash_plain=""
if [ -n "$stash_count" ] && [ "$stash_count" -gt 0 ]; then
  stash_color="$YELLOW"
  [ "$stash_count" -ge 5 ] && stash_color="$RED_BRIGHT"
  stash_seg="${GRAY}⚑${RESET}${stash_color}${stash_count}${RESET}"
  stash_plain="⚑${stash_count}"
fi

# 7. PR info: "PR#N" is always magenta, wrapped in an OSC 8 hyperlink to
# .pr.url when that's non-empty and passes the whitespace/ESC paranoia
# guard (plain colored text otherwise); the review state (when present)
# stays OUTSIDE the link and keeps its own dynamic color: approved green,
# changes_requested bright red, draft gray, pending or any other value
# yellow. No state -> just the (possibly linked) magenta PR#N. A cached CI
# status glyph (see below) may be appended after the review state.
# (pr_number/pr_state/pr_url already extracted by the consolidated jq call)
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

  # PR CI status: cached + non-blocking. The cache is one single-row file
  # PER (repo, PR): ~/.claude/statusline-ci-cache.<owner>-<name>-<pr>
  # ("epoch\trepo\tpr\tstate") - the key is IN THE FILENAME, same pattern
  # as the panel daemon's cache.<key>. A single shared file held only one
  # (repo, PR) at a time, so two concurrent sessions on different PRs
  # evicted each other EVERY frame in steady state: the badge never
  # stabilized and each session respawned a detached gh+grep chain every
  # 10s indefinitely - a standing process/network amplifier in exactly
  # the fork-budget regime this script treats as a survival constraint.
  # If the row is <60s old its glyph is appended now; otherwise render
  # without a glyph and fire a detached background `gh` refresh for next
  # time - the render itself never waits on network. NEGATIVE CACHING:
  # the refresh now also writes state "none" when gh returns nothing
  # (not logged in, offline, PR without checks) so misses are re-probed
  # once per TTL, not once per frame; "none" renders no glyph. Guarded to
  # only fire when `gh` exists and we have a repo owner/name + PR number.
  if [ -n "$repo_owner" ] && [ -n "$repo_name" ] && command -v gh >/dev/null 2>&1; then
    ci_key="${repo_owner}-${repo_name}-${pr_number}"
    ci_key=${ci_key//[!A-Za-z0-9._-]/_}
    # prefix env-overridable (round-3 fix): tests were writing real CI
    # cache rows into ~/.claude and spawning real gh for the fixture PR
    ci_cache_file="${STATUSLINE_CI_CACHE_PREFIX:-$HOME/.claude/statusline-ci-cache}.${ci_key}"
    ci_repo_pr="${repo_owner}/${repo_name}"
    ci_state=""
    if [ -f "$ci_cache_file" ]; then
      ci_cache_line=""
      read -r ci_cache_line < "$ci_cache_file"
      ci_cache_line=${ci_cache_line//$'\r'/}
      ci_cache_line=${ci_cache_line//$'\t'/$'\x1f'}
      IFS=$'\x1f' read -r ci_cache_epoch ci_cache_repo ci_cache_pr ci_cache_state <<< "$ci_cache_line"
      if [ "$ci_cache_repo" = "$ci_repo_pr" ] && [ "$ci_cache_pr" = "$pr_number" ] && [[ "$ci_cache_epoch" =~ ^[0-9]+$ ]]; then
        ci_age=$(( now_epoch - ci_cache_epoch ))
        [ "$ci_age" -lt 60 ] && [ "$ci_age" -ge 0 ] && ci_state="$ci_cache_state"
      fi
    fi
    if [ -n "$ci_state" ]; then
      # "none" (negative cache) simply matches no case arm: no glyph, and
      # crucially no respawn until the row ages out.
      ci_glyph_plain=""
      case "$ci_state" in
        passing) pr_seg="${pr_seg} ${GREEN}✓CI${RESET}"; ci_glyph_plain="✓CI" ;;
        failing) pr_seg="${pr_seg} ${RED_BRIGHT}✗CI${RESET}"; ci_glyph_plain="✗CI" ;;
        pending) pr_seg="${pr_seg} ${YELLOW}●CI${RESET}"; ci_glyph_plain="●CI" ;;
      esac
      [ -n "$ci_glyph_plain" ] && pr_plain="${pr_plain} ${ci_glyph_plain}"
    else
      # IN-FLIGHT DEDUP: a slow/hanging gh (offline TCP timeouts run
      # 20-75s) used to get a NEW detached gh chain forked on top of it
      # every 10s frame - a self-amplifier in exactly the fork-budget
      # regime that matters. One epoch-stamped marker file (builtin
      # write, zero spawns on the render path) suppresses respawns for
      # 120s; the job removes it when done, and a marker orphaned by a
      # killed job simply ages out of the gate (plus it matches the
      # statusline-ci-cache.* housekeeping glob).
      ci_inflight="${ci_cache_file}.inflight"
      ci_spawn=1
      if [ -f "$ci_inflight" ]; then
        ci_if_epoch=""
        read -r ci_if_epoch < "$ci_inflight" 2>/dev/null
        if [[ "$ci_if_epoch" =~ ^[0-9]+$ ]]; then
          ci_if_age=$(( now_epoch - ci_if_epoch ))
          [ "$ci_if_age" -ge 0 ] && [ "$ci_if_age" -lt 120 ] && ci_spawn=0
        fi
      fi
      if [ "$ci_spawn" -eq 1 ]; then
      printf '%s\n' "$now_epoch" > "$ci_inflight" 2>/dev/null
      (
        gh_states=$(gh pr checks "$pr_number" --repo "$ci_repo_pr" --json state -q '.[].state' 2>/dev/null)
        new_ci_state="none"
        if [ -n "$gh_states" ]; then
          new_ci_state="passing"
          # Validated against real `gh pr checks` output. Case-insensitive.
          if printf '%s' "$gh_states" | grep -Eqi "FAILURE|CANCELLED|TIMED_OUT|ACTION_REQUIRED|ERROR|STARTUP_FAILURE"; then
            new_ci_state="failing"
          elif printf '%s' "$gh_states" | grep -Eqi "PENDING|IN_PROGRESS|QUEUED|WAITING|REQUESTED|EXPECTED"; then
            new_ci_state="pending"
          fi
        fi
        ci_tmp="${ci_cache_file}.tmp.$$"
        printf '%s\t%s\t%s\t%s\n' "$(printf '%(%s)T' -1)" "$ci_repo_pr" "$pr_number" "$new_ci_state" > "$ci_tmp" 2>/dev/null && mv -f "$ci_tmp" "$ci_cache_file" 2>/dev/null
        # housekeeping, riding the already-detached refresh (never the
        # render path): per-key rows for PRs nobody has rendered in a day
        # + the pre-per-key shared file a previous version left behind
        ci_cache_dir="${ci_cache_file%/*}"
        find "$ci_cache_dir" -maxdepth 1 \( -name 'statusline-ci-cache.*' -o -name 'statusline-ci-cache' \) -mmin +1440 -delete 2>/dev/null
        rm -f "$ci_inflight" 2>/dev/null
      ) >/dev/null 2>&1 &
      disown
      fi
    fi
  fi
fi

# BYPASS WARNING: the main stdin payload has NO live per-session
# permission_mode field, so this APPROXIMATES it from the CONFIGURED
# default in ~/.claude/settings.json instead - this is NOT the live mode
# for this session (a session could have started before a settings
# change, or have its mode toggled at runtime after starting; this only
# reflects what's on disk right now, re-checked fresh every render). File
# is read whole via `read -r -d ''` (reads to EOF/NUL into one variable
# in the current shell, zero forks - deliberately not $(< file), which
# isn't guaranteed fork-free the way redirecting straight into a builtin
# is); `read`'s own non-zero exit at EOF-without-a-delimiter is expected
# and ignored (`|| true`) - the variable is populated either way.
# Detection is two INDEPENDENT substring checks ANDed together (not one
# combined pattern), so incidental JSON formatting/whitespace differences
# (key on its own line vs. inline, spacing, key order) can't defeat the
# match; this is a deliberate proximity-free approximation, not a real
# JSON parse (no jq call here - this must stay a zero-process check), so
# it could in theory false-positive if "bypassPermissions" appeared
# anywhere else in the file for an unrelated reason - an accepted
# tradeoff for a zero-spawn check. Rendered at the END of line 1, after
# PR, only when both substrings are found.
bypass_seg=""
bypass_plain=""
# (⚡bypass 段已按用户明确指令于 2026-08-13 移除——宿主自带的
# "⏵⏵ bypass permissions on" 横条覆盖同一信息。请勿作为"缺失损坏"恢复。)

# 8. context battery bar: [!]<bar> N% [Xk/Yk]. remaining_int truncates the
# fractional part (floor for a non-negative percentage), so the integer
# comparisons below match real-valued thresholds exactly. "!" is prefixed
# when remaining is below 20%. The bar is 5 cells; filled count is
# remaining_int rounded to the nearest fifth via integer math
# ((remaining_int + 10) / 20), clamped to 0..5. Filled cells (█, U+2588) use
# the segment's dynamic color (>=50 green, 20-49 yellow, <20 bright red);
# empty cells (░, U+2591) are gray. "N%" keeps the dynamic color; token
# counts are unchanged: "Nk" white, "/Nk" (slash included) gray.
# (remaining/in_tokens/win_size/out_tokens_ctx already extracted by the
# consolidated jq call above). ctx_compact_seg is the narrow-terminal
# variant used on the single adaptive line (bar+pct only, no "ctx" label,
# no token counts) - see the COLUMNS branch near the bottom.
ctx_seg=""
ctx_plain=""
ctx_compact_seg=""
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
  # N5: auto-compact mark (~80% community convention, not an official
  # Claude Code threshold) - cell index 4 (floor(0.8*5)) renders as a
  # fixed bright-white "|" whenever the bar hasn't reached that cell yet
  # (filled<=4); once the bar is completely full (filled=5) the marker is
  # omitted, since there's no "before autocompact" cell left to mark.
  bar_plain=""
  bar_cells=""
  for ((bi=0; bi<5; bi++)); do
    if [ "$bi" -lt "$filled" ]; then
      bar_cells="${bar_cells}${ctx_color}█${RESET}"
      bar_plain="${bar_plain}█"
    elif [ "$bi" -eq 4 ]; then
      bar_cells="${bar_cells}${WHITE_BRIGHT}│${RESET}"
      bar_plain="${bar_plain}│"
    else
      bar_cells="${bar_cells}${GRAY}░${RESET}"
      bar_plain="${bar_plain}░"
    fi
  done
  bar="$bar_cells"
  ctx_compact_seg="$bar"
  [ -n "$ctx_warn" ] && ctx_compact_seg="${RED_BRIGHT}!${RESET}${ctx_compact_seg}"
  ctx_compact_seg="${ctx_compact_seg} ${ctx_color}${ctx_remaining}%${RESET}"
  ctx_seg="${GRAY}ctx${RESET} "
  ctx_plain="ctx "
  if [ -n "$ctx_warn" ]; then
    ctx_seg="${ctx_seg}${RED_BRIGHT}!${RESET}"
    ctx_plain="${ctx_plain}!"
  fi
  ctx_seg="${ctx_seg}${bar} ${ctx_color}${ctx_remaining}%${RESET}"
  ctx_plain="${ctx_plain}${bar_plain} ${ctx_remaining}%"
  fmt_k_or_m "$occupied"; occ_fmt="$REPLY"
  fmt_k_or_m "$win_size"; total_fmt="$REPLY"
  ctx_seg="${ctx_seg} ${WHITE}${occ_fmt}${RESET}${GRAY}/${total_fmt}${RESET}"
  ctx_plain="${ctx_plain} ${occ_fmt}/${total_fmt}"
elif [[ "$remaining" =~ ^-?[0-9]{1,3}(\.[0-9]+)?$ ]]; then
  # FALLBACK: token fields unavailable, drive everything off the
  # (input-only) remaining_percentage field instead, no token text.
  # DOUBLE GUARD (hard-rule 2): only a numeric remaining enters this arm
  # at all - a garbage string now drops the whole segment silently
  # instead of feeding printf. The {1,3} digit cap (round-4, same as the
  # five/week/cost caps) keeps the -gt comparisons inside bash integer
  # range: an unbounded 24-digit value made every clamp test error out
  # as false and rendered a full green battery + a 24-digit percent that
  # blew up the whole grid's column widths. The value is then CLAMPED to
  # 0..100, mirroring the primary path's clamp: a negative reading
  # (input-only arithmetic can go past the window) renders the same red
  # "!...0%" alarm the primary path would - never an unguarded green.
  if [ "${remaining:0:1}" = "-" ]; then
    remaining_int=0
    remaining_disp="0"
  else
    remaining_int="${remaining%%.*}"
    if [ "$remaining_int" -gt 100 ]; then
      remaining_int=100
      remaining_disp="100"
    else
      printf -v remaining_disp '%.0f' "$remaining" 2>/dev/null || remaining_disp="$remaining_int"
    fi
  fi
  ctx_color="$GREEN"
  ctx_warn=""
  filled=$(( (remaining_int + 10) / 20 ))
  [ "$filled" -gt 5 ] && filled=5
  if [ "$remaining_int" -lt 20 ]; then
    ctx_warn="1"
    ctx_color="$RED_BRIGHT"
  elif [ "$remaining_int" -lt 50 ]; then
    ctx_color="$YELLOW"
  fi
  # N5: auto-compact mark - see the primary path's comment above for the
  # full rationale; same rule (cell index 4, omitted once filled=5).
  bar_plain=""
  bar_cells=""
  for ((bi=0; bi<5; bi++)); do
    if [ "$bi" -lt "$filled" ]; then
      bar_cells="${bar_cells}${ctx_color}█${RESET}"
      bar_plain="${bar_plain}█"
    elif [ "$bi" -eq 4 ]; then
      bar_cells="${bar_cells}${WHITE_BRIGHT}│${RESET}"
      bar_plain="${bar_plain}│"
    else
      bar_cells="${bar_cells}${GRAY}░${RESET}"
      bar_plain="${bar_plain}░"
    fi
  done
  bar="$bar_cells"
  # (remaining_disp already computed, clamped and guarded above)
  ctx_compact_seg="$bar"
  [ -n "$ctx_warn" ] && ctx_compact_seg="${RED_BRIGHT}!${RESET}${ctx_compact_seg}"
  ctx_compact_seg="${ctx_compact_seg} ${ctx_color}${remaining_disp}%${RESET}"
  ctx_seg="${GRAY}ctx${RESET} "
  ctx_plain="ctx "
  if [ -n "$ctx_warn" ]; then
    ctx_seg="${ctx_seg}${RED_BRIGHT}!${RESET}"
    ctx_plain="${ctx_plain}!"
  fi
  ctx_seg="${ctx_seg}${bar} ${ctx_color}${remaining_disp}%${RESET}"
  ctx_plain="${ctx_plain}${bar_plain} ${remaining_disp}%"
fi

# 9. token rate + sparkline, from the history file above (needs >=2
# history rows for this session; silently absent otherwise). Two
# independently-optional halves joined by a space when both are present.
# Sparkline: consecutive deltas (negative deltas, from a post-/compact
# reset, clamp to 0) of the tokens column over the last up-to-9 rows (up to
# 8 deltas), needs >=2 deltas, normalized min..max onto 6 glyphs ▁▂▃▄▅▆
# (all-equal -> all ▃; capped below ▇/█ so a full-height cell can't fuse
# with an adjacent stacked line), cyan. Rate: newest tokens minus the
# oldest row within the last
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
    # Capped at 6 levels (▁-▆, no ▇/█): with multiple rows stacked at zero
    # line spacing (subagent grid), a full-height █ in one row can visually
    # fuse with a bottom-aligned ▁ in the row below; stopping at ▆ keeps a
    # >=1/4-cell gap at every cell top so rows can never connect. The ctx
    # battery bar and rate-limit micro-bar keep █ - those are single-line
    # gauges where this fusion can't happen.
    glyph_chars2=("▁" "▂" "▃" "▄" "▅" "▆")
    if [ "$max_d" -eq "$min_d" ]; then
      for dv in "${deltas[@]}"; do
        spark2_plain="${spark2_plain}▃"
      done
    else
      d_range=$(( max_d - min_d ))
      for dv in "${deltas[@]}"; do
        d_idx=$(( (dv - min_d) * 5 / d_range ))
        [ "$d_idx" -lt 0 ] && d_idx=0
        [ "$d_idx" -gt 5 ] && d_idx=5
        spark2_plain="${spark2_plain}${glyph_chars2[$d_idx]}"
      done
    fi
    # coloring deferred until the rate (below) is known - item 9: the
    # sparkline shares the rate's tier color when a rate is present, cyan
    # only when it renders alone
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

# item 9: sparkline glyphs take the rate's tier color when a rate is
# present, cyan only when the sparkline renders alone (no rate).
spark2_seg=""
if [ -n "$spark2_plain" ]; then
  if [ -n "$rate_seg" ]; then
    spark2_color="$rate_color"
  else
    spark2_color="$CYAN"
  fi
  spark2_seg="${spark2_color}${spark2_plain}${RESET}"
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
# absent - guarded by requiring all three numeric fields; already
# extracted by the consolidated jq call above). One decimal place (integer
# math only: hit10 = r*1000/denom, tier compares hit10/10 i.e. the integer
# part, displayed as (hit10/10).(hit10%10)). Followed by a gray
# " r<X>·w<Y>" read/write breakdown (existing k-or-M formatter), omitted
# when both cache_read and cache_creation are 0/absent.
cache_seg=""
cache_plain=""
if [[ "$cache_r" =~ ^[0-9]+$ ]] && [[ "$cache_w" =~ ^[0-9]+$ ]] && [[ "$cache_i" =~ ^[0-9]+$ ]]; then
  cache_denom=$(( cache_i + cache_w + cache_r ))
  if [ "$cache_denom" -gt 0 ]; then
    cache_hit10=$(( cache_r * 1000 / cache_denom ))
    cache_hit_int=$(( cache_hit10 / 10 ))
    if [ "$cache_hit_int" -ge 80 ]; then
      cache_color="$GREEN"
    elif [ "$cache_hit_int" -ge 50 ]; then
      cache_color="$YELLOW"
    else
      cache_color="$RED_BRIGHT"
    fi
    cache_hit_fmt="$(( cache_hit10 / 10 )).$(( cache_hit10 % 10 ))"
    cache_seg="${GRAY}cache${RESET} ${cache_color}${cache_hit_fmt}%${RESET}"
    cache_plain="cache ${cache_hit_fmt}%"
    cache_rw_show=0
    [ "$cache_r" -gt 0 ] && cache_rw_show=1
    [ "$cache_w" -gt 0 ] && cache_rw_show=1
    if [ "$cache_rw_show" -eq 1 ]; then
      fmt_small_or_k "$cache_r"; cache_r_fmt="$REPLY"
      fmt_small_or_k "$cache_w"; cache_w_fmt="$REPLY"
      cache_seg="${cache_seg}${GRAY} r${cache_r_fmt}·w${cache_w_fmt}${RESET}"
      cache_plain="${cache_plain} r${cache_r_fmt}·w${cache_w_fmt}"
    fi
  fi
fi

# ---------- shared tail-read for N3 (compaction counter) and N4 (cache
# freshness countdown), both below: ONE `tail -c` spawn - one of only two
# explicitly-accepted exceptions to this script's zero-external-process
# policy (see the PERF comment at the top; the other is N4's `date -d`
# below), because scanning transcript JSONL for these two features needs
# its own file read that doesn't fit the single upfront jq/git calls.
# SIMPLIFICATION DISCLOSED: the original request sketched a doubling
# tail-read (32KiB, then 64/128/256, capped at 4 doublings, stopping once
# a non-boundary line older than the first found boundary appears) to
# raise confidence that no compaction boundary was missed just outside
# the window; that would cost up to 5 `tail` spawns in the worst case,
# which conflicts with this script's whole performance mandate, and the
# same request separately concedes "1 tail spawn accepted" - so this
# implementation takes ONE fixed-size read instead (512KiB default,
# STATUSLINE_TRANSCRIPT_TAIL_BYTES to override - see its comment). Both features
# already accept and document a "may miss data outside the window"
# limitation, so this is a difference of degree, not of kind. Silently
# absent (both segments) when transcript_path is empty, unreadable, or
# `tail` itself is missing.
# NARROW-TERMINAL EARLY GATE: $COLUMNS is normalized HERE, not only at
# the assembly branch at the bottom, because the transcript work below is
# wide-mode-only DISPLAY material: the narrow compact line carries no
# compaction/cache-freshness segments, yet it used to pay the full tail
# read + window scan (+ the possible date spawn) every frame anyway -
# measured ~2s/frame of fully invisible work on a filled window. State-
# continuity writes (history sampling/rollup above) are NOT width-gated:
# they must advance regardless of terminal width.
[[ "$COLUMNS" =~ ^[0-9]+$ ]] || COLUMNS=120

tail_lines=()
cache_cand_ts=""
if [ "$COLUMNS" -ge 100 ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && command -v tail >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
  # Window default 512KiB (was 128KiB), env-overridable via
  # STATUSLINE_TRANSCRIPT_TAIL_BYTES: single JSONL entries were measured
  # at 114KiB on a heavy session - ONE entry bigger than the window
  # would leave zero parseable lines inside it and silently blank the
  # freshness/compaction segments. 512KiB keeps ~4x headroom over the
  # largest entry seen while still being one cheap seek+read.
  tail_bytes="${STATUSLINE_TRANSCRIPT_TAIL_BYTES:-524288}"
  [[ "$tail_bytes" =~ ^[0-9]+$ ]] || tail_bytes=524288
  # O(bytes) TRAP FIXED (adversarial review, 2026-08-14): the old
  # `mapfile <<<` split of the whole tail window ran at a measured
  # ~3.5us PER BYTE on MSYS - ~1.8s of EVERY frame once a long session
  # filled the window - while the old comment wrongly booked the block
  # as "per-LINE scans scale with line count" (the SPLIT is itself
  # O(bytes)). The window is now pre-filtered by ONE awk stage riding
  # the same pipe (+1 fork, ~ms at C speed): it emits only the
  # compact-boundary lines ("C"-tagged) and the single NEWEST assistant
  # line with nonzero cache activity and a timestamp ("A"-tagged) - so
  # bash then splits a few hundred bytes, not 512KiB. awk applies the
  # same per-line filters the bash loops applied (non-sidechain;
  # nonzero-first-digit for the cache counts), so N3/N4 semantics are
  # unchanged. awk sits behind the same command -v guard as tail (both
  # are core Git-Bash tools); if either is missing the two segments
  # simply stay absent, like any other optional segment.
  # The "A" record carries ONLY the extracted timestamp VALUE, never the
  # whole matched line: a heavy assistant entry can be >100KiB, and both
  # `mapfile <<<` on it (~3.5us/B) and the later `#*"timestamp"`
  # prefix-strip (bash glob matching goes QUADRATIC on that pattern -
  # measured 13.6s on a 116KiB line) would re-import the exact O(bytes)
  # tax this pipeline exists to remove. Compact-boundary lines are tiny
  # system entries and pass through whole for the N3 parser below.
  tail_scan=$(tail -c "$tail_bytes" -- "$transcript_path" 2>/dev/null | awk '
    /"subtype":"compact_boundary"/ && !/"isSidechain":true/ { print "C" $0; next }
    /"type":"assistant"/ && !/"isSidechain":true/ && (/"cache_read_input_tokens": ?[1-9]/ || /"cache_creation_input_tokens": ?[1-9]/) && match($0, /"timestamp":"[^"]*"/) { last = substr($0, RSTART+13, RLENGTH-14) }
    END { if (last != "") print "A" last }
  ' 2>/dev/null)
  tail_scan=${tail_scan//$'\r'/}
  if [ -n "$tail_scan" ]; then
    mapfile -t tail_scan_lines <<< "$tail_scan"
    for tsl in "${tail_scan_lines[@]}"; do
      case "$tsl" in
        C*) tail_lines+=("${tsl#C}") ;;
        A*) cache_cand_ts="${tsl#A}" ;;
      esac
    done
  fi
fi

# N3: compaction counter. Pure-bash substring scan (grep-free, as
# specified) of tail_lines for `"subtype":"compact_boundary"` lines,
# skipping any with `"isSidechain":true`; reclaimed tokens sum
# preTokens-postTokens out of an embedded "compactMetadata" object when
# both are present and numeric (found via #*"field": prefix-strip then
# %%,* / %%}* suffix-strip - the same defensive "extract, then validate
# with a numeric regex, else silently skip" pattern used everywhere else
# in this script). LIMITATION (by design, documented): only boundaries
# that happen to fall inside the tail window above are counted - a long-
# running session's older compactions can scroll out of the tail window
# and simply won't be seen; this is a lower bound, not an exact count.
compact_count=0
compact_reclaimed=0
for tline in "${tail_lines[@]}"; do
  [[ "$tline" == *'"subtype":"compact_boundary"'* ]] || continue
  [[ "$tline" == *'"isSidechain":true'* ]] && continue
  compact_count=$(( compact_count + 1 ))
  pre_val=""
  if [[ "$tline" == *'"preTokens":'* ]]; then
    pre_rest="${tline#*\"preTokens\":}"
    pre_val="${pre_rest%%,*}"
    pre_val="${pre_val%%\}*}"
    pre_val="${pre_val# }"
  fi
  post_val=""
  if [[ "$tline" == *'"postTokens":'* ]]; then
    post_rest="${tline#*\"postTokens\":}"
    post_val="${post_rest%%,*}"
    post_val="${post_val%%\}*}"
    post_val="${post_val# }"
  fi
  if [[ "$pre_val" =~ ^[0-9]+$ ]] && [[ "$post_val" =~ ^[0-9]+$ ]] && [ "$pre_val" -ge "$post_val" ]; then
    compact_reclaimed=$(( compact_reclaimed + (pre_val - post_val) ))
  fi
done
compact_seg=""
compact_plain=""
if [ "$compact_count" -gt 0 ]; then
  compact_seg="${GRAY}↻${RESET}${WHITE}${compact_count}${RESET}"
  compact_plain="↻${compact_count}"
  if [ "$compact_reclaimed" -gt 0 ]; then
    fmt_k_or_m "$compact_reclaimed"; compact_reclaimed_fmt="$REPLY"
    compact_seg="${compact_seg}${GRAY} ↓${RESET}${WHITE}${compact_reclaimed_fmt}${RESET}"
    compact_plain="${compact_plain} ↓${compact_reclaimed_fmt}"
  fi
fi

# N4: cache freshness countdown (TTL is an assumption, not a documented
# API contract). Consumes the "A"-tagged line the awk stage above already
# selected: the newest assistant (non-sidechain) line with nonzero cache
# activity (cache_read_input_tokens or cache_creation_input_tokens) and a
# "timestamp" key. remaining = ttl - 5 - (now - last);
# ttl from $STATUSLINE_CACHE_TTL_SECONDS, default 3600. There is no
# pure-bash ISO-8601 parse, so this is the one other accepted external-
# process exception in this script: a single `date -d` spawn, fired only
# when a candidate line was actually found (never on every render, and
# never at all when the cache segment itself isn't showing). Appended to
# the cache segment (10) above, space-separated, only when that segment
# is itself already present - a bare countdown with no "cache N%" next
# to it would be a floating, context-less fragment.
if [ -n "$cache_seg" ] && [ -n "$cache_cand_ts" ] && command -v date >/dev/null 2>&1; then
  # awk already filtered for assistant + non-sidechain + nonzero cache
  # counts AND extracted the timestamp VALUE itself (never the whole
  # line - see the pipeline comment above), so bash starts from the
  # ready-made value with zero big-string work.
  cache_ts="$cache_cand_ts"
  if [ -n "$cache_ts" ]; then
    cache_ts_epoch=$(date -d "$cache_ts" +%s 2>/dev/null)
    if [[ "$cache_ts_epoch" =~ ^[0-9]+$ ]]; then
      cache_ttl="${STATUSLINE_CACHE_TTL_SECONDS:-3600}"
      [[ "$cache_ttl" =~ ^[0-9]+$ ]] || cache_ttl=3600
      cache_remaining=$(( cache_ttl - 5 - (now_epoch - cache_ts_epoch) ))
      if [ "$cache_remaining" -le 0 ]; then
        cache_fresh_text="cold"
        cache_fresh_color="$GRAY"
      else
        cache_frac1000=0
        [ "$cache_ttl" -gt 0 ] && cache_frac1000=$(( cache_remaining * 1000 / cache_ttl ))
        if [ "$cache_frac1000" -gt 900 ]; then
          # UX: an active session keeps re-warming the cache, so the
          # countdown sits near TTL almost continuously and reads as
          # frozen/broken rather than "healthy" - collapse anything above
          # 90% remaining into a static "hot" instead of a number.
          cache_fresh_text="hot"
          cache_fresh_color="$GREEN"
        else
          if [ "$cache_remaining" -lt 60 ]; then
            cache_fresh_text="${cache_remaining}s"
          else
            cf_m=$(( cache_remaining / 60 ))
            cf_s=$(( cache_remaining % 60 ))
            if [ "$cf_m" -ge 60 ]; then
              cache_fresh_text="${cf_m}m"
            else
              cache_fresh_text="${cf_m}m${cf_s}s"
            fi
          fi
          if [ "$cache_frac1000" -gt 500 ]; then
            cache_fresh_color="$WHITE"
          elif [ "$cache_frac1000" -gt 200 ]; then
            cache_fresh_color="$YELLOW"
          else
            cache_fresh_color="$RED_BRIGHT"
          fi
        fi
      fi
      cache_seg="${cache_seg} ${cache_fresh_color}${cache_fresh_text}${RESET}"
      cache_plain="${cache_plain} ${cache_fresh_text}"
    fi
  fi
fi

# 11. session cost (USD): "$" is left uncolored (plain default foreground, no
# ANSI wrap at all - same idea as the "/" in the lines-changed segment),
# amount dynamic by integer dollars: <1 gray, 1-4 yellow, >=5 bright red.
# Followed, space-separated inside the same segment, by an optional cost
# rate "$X.Y/h" from the history file (needs a same-session row with a
# non-empty cost from >=120s ago within the last hour; cost strings are
# parsed to integer cents in pure bash - see cost_to_cents above).
# (cost already extracted by the consolidated jq call above). cost_compact
# is the narrow-terminal variant (amount only, no rate).
cost_seg=""
cost_plain=""
cost_compact_seg=""
# DOUBLE GUARD (hard-rule 2, same as the ctx fallback): only a NUMERIC
# cost enters at all - the old [ -n ] let a garbage string reach printf,
# which errored into the blackbox and rendered a fake "$0.00" (and next
# to a real historical $/h rate that fake reads as a live figure). Digit
# cap keeps the later integer comparisons inside bash arithmetic range.
if [[ "$cost" =~ ^[0-9]{1,9}(\.[0-9]+)?$ ]]; then
  cost_int="${cost%%.*}"
  cost_color="$GRAY"
  if [ "$cost_int" -ge 5 ]; then
    cost_color="$RED_BRIGHT"
  elif [ "$cost_int" -ge 1 ]; then
    cost_color="$YELLOW"
  fi
  printf -v cost_amount '%.2f' "$cost"
  cost_seg="\$${cost_color}${cost_amount}${RESET}"
  cost_plain="\$${cost_amount}"
  cost_compact_seg="$cost_seg"

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
      newest_cents=""
      cost_to_cents "$newest_cost" && newest_cents="$REPLY"
      old_cents=""
      cost_to_cents "$old_cost" && old_cents="$REPLY"
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
  # zero-hide: amount rounds to 0.00 AND no rate is displayable -> hide
  # the whole segment (compact variant included).
  if [ "$cost_amount" = "0.00" ] && [ -z "$costrate_seg" ]; then
    cost_seg=""
    cost_plain=""
    cost_compact_seg=""
  fi
fi

# 12. lines changed (shown once either field is present; missing side defaults
# to 0) - "+added" green, "/" uncolored, "-removed" red.
# (added/removed already extracted by the consolidated jq call above)
lines_seg=""
lines_plain=""
if [ -n "$added" ] || [ -n "$removed" ]; then
  [ -z "$added" ] && added=0
  [ -z "$removed" ] && removed=0
  # zero-hide: both zero -> hide the whole segment
  added_is_zero=0
  [[ "$added" =~ ^[0-9]+$ ]] && [ "$added" -eq 0 ] && added_is_zero=1
  removed_is_zero=0
  [[ "$removed" =~ ^[0-9]+$ ]] && [ "$removed" -eq 0 ] && removed_is_zero=1
  if [ "$added_is_zero" -eq 0 ] || [ "$removed_is_zero" -eq 0 ]; then
    lines_seg="${GREEN}+${added}${RESET}/${RED}-${removed}${RESET}"
    lines_plain="+${added}/-${removed}"
  fi
fi

# 13. rate limits (each window independently optional, each with an optional
# "->reset" suffix guarded by a numeric check before it's handed to `date`).
# Per-part colors per window: "5h"/"7d" label is fixed cyan; "N%" is dynamic
# by that window's own floor(used_percentage) (<50 green, 50-79 yellow, >=80
# bright red); "→reset" (arrow included) is white. Windows are still joined
# by a plain space.
# (five/five_reset/week/week_reset already extracted by the consolidated
# jq call above). PACE CURSOR: for a window with a valid resets_at,
# time_pct = how far through the window we are (0..100, clamped);
# pace = used% - time%. pace>=15 forces bright red; 0<pace<15 forces at
# least yellow (never downgrades an already-red absolute tier); pace<=0
# keeps the absolute tier. The pace suffix "·t<N>%" (gray) is appended
# after the usage percent, before the "→reset" suffix. (A 6-cell micro
# progress bar was tried here and reverted after visual review - two
# meanings in one glyph row, and the time cursor landing inside the
# filled zone when time lags usage read as a rendering glitch rather than
# a pace signal - back to the textual form.) five_compact/week_compact
# are the narrow-terminal variants (percent only, pace-aware color, no
# label/pace-suffix/reset-time) - only five_compact is actually used (the
# compact line only shows the 5h window).
rl_seg=""
rl_plain=""
five_compact_seg=""
# DOUBLE GUARD (hard-rule 2): numeric-or-absent - the old [ -n ] let a
# garbage used_percentage reach printf and render a fake healthy green
# "5h 0%" instead of the segment disappearing; a negative or over-100
# reading clamps into the 0..100 domain (ctx-fallback precedent), and
# the 3-digit cap keeps every later -ge comparison inside bash
# arithmetic range (a 21-digit number would otherwise blow it up).
if [[ "$five" =~ ^-?[0-9]{1,3}(\.[0-9]+)?$ ]]; then
  if [ "${five:0:1}" = "-" ]; then five="0"; fi
  five_int="${five%%.*}"
  [ "$five_int" -gt 100 ] && { five_int=100; five="100"; }
  five_color="$GREEN"
  if [ "$five_int" -ge 80 ]; then
    five_color="$RED_BRIGHT"
  elif [ "$five_int" -ge 50 ]; then
    five_color="$YELLOW"
  fi
  printf -v five_pct '%.0f' "$five"
  # resets_at NORMALIZATION (round-3 fix, the 4th same-shape site after
  # cost/five/week got their guards): digits-only was not enough - a
  # millisecond-unit value (upstream unit mixing is an acknowledged risk
  # here: startTime already gets the >1e12 treatment) clamped the time
  # cursor to t0% and FORCE-RED a healthy percent, 0 rendered a 1970
  # clock, and a 20-digit value overflowed printf into the blackbox
  # while still showing a fabricated time. 13-digit cap keeps arithmetic
  # in range; >1e12 converts ms->s; then a sanity window (yesterday ..
  # window-end + a day) - out of range means the reset half-segments
  # silently disappear instead of lying.
  if [[ "$five_reset" =~ ^[0-9]{1,13}$ ]]; then
    [ "$five_reset" -gt 1000000000000 ] && five_reset=$(( five_reset / 1000 ))
    if [ "$five_reset" -lt $(( now_epoch - 86400 )) ] || [ "$five_reset" -gt $(( now_epoch + 18000 + 86400 )) ]; then
      five_reset=""
    fi
  else
    five_reset=""
  fi
  # REVERTED (N1 micro-bar rejected on visual review: two meanings in one
  # glyph row, and the cursor landing inside the filled zone when time
  # lags usage read as a rendering glitch, not a pace indicator). Back to
  # the textual pace cursor "·tNN%" (gray) appended after the usage
  # percent: "5h 47%·t94%->09:10". Pace tier-override logic (used for the
  # percent's own color) is unchanged.
  five_pace_seg=""
  five_pace_plain=""
  if [[ "$five_reset" =~ ^[0-9]+$ ]]; then
    five_time_pct=$(( (18000 - (five_reset - now_epoch)) * 100 / 18000 ))
    [ "$five_time_pct" -lt 0 ] && five_time_pct=0
    [ "$five_time_pct" -gt 100 ] && five_time_pct=100
    five_pace_seg="${GRAY}·t${five_time_pct}%${RESET}"
    five_pace_plain="·t${five_time_pct}%"
    if [[ "$five_int" =~ ^[0-9]+$ ]]; then
      five_pace=$(( five_int - five_time_pct ))
      if [ "$five_pace" -ge 15 ]; then
        five_color="$RED_BRIGHT"
      elif [ "$five_pace" -gt 0 ] && [ "$five_color" != "$RED_BRIGHT" ]; then
        five_color="$YELLOW"
      fi
    fi
  fi
  five_part="${CYAN}5h${RESET} ${five_color}${five_pct}%${RESET}${five_pace_seg}"
  five_part_plain="5h ${five_pct}%${five_pace_plain}"
  five_compact_seg="${five_color}${five_pct}%${RESET}"
  if [[ "$five_reset" =~ ^[0-9]+$ ]]; then
    printf -v five_clock '%(%H:%M)T' "$five_reset"
    five_part="${five_part}${WHITE}→${five_clock}${RESET}"
    five_part_plain="${five_part_plain}→${five_clock}"
  fi
  rl_seg="$five_part"
  rl_plain="$five_part_plain"
fi
# DOUBLE GUARD (hard-rule 2) - see the 5h window's comment above.
if [[ "$week" =~ ^-?[0-9]{1,3}(\.[0-9]+)?$ ]]; then
  if [ "${week:0:1}" = "-" ]; then week="0"; fi
  week_int="${week%%.*}"
  [ "$week_int" -gt 100 ] && { week_int=100; week="100"; }
  week_color="$GREEN"
  if [ "$week_int" -ge 80 ]; then
    week_color="$RED_BRIGHT"
  elif [ "$week_int" -ge 50 ]; then
    week_color="$YELLOW"
  fi
  printf -v week_pct '%.0f' "$week"
  # resets_at normalization - see the 5h window's comment above (window
  # here is 7 days)
  if [[ "$week_reset" =~ ^[0-9]{1,13}$ ]]; then
    [ "$week_reset" -gt 1000000000000 ] && week_reset=$(( week_reset / 1000 ))
    if [ "$week_reset" -lt $(( now_epoch - 86400 )) ] || [ "$week_reset" -gt $(( now_epoch + 604800 + 86400 )) ]; then
      week_reset=""
    fi
  else
    week_reset=""
  fi
  # REVERTED (N1 micro-bar rejected - see the 5h window's comment above).
  # Back to the textual pace cursor "·tNN%".
  week_pace_seg=""
  week_pace_plain=""
  if [[ "$week_reset" =~ ^[0-9]+$ ]]; then
    week_time_pct=$(( (604800 - (week_reset - now_epoch)) * 100 / 604800 ))
    [ "$week_time_pct" -lt 0 ] && week_time_pct=0
    [ "$week_time_pct" -gt 100 ] && week_time_pct=100
    week_pace_seg="${GRAY}·t${week_time_pct}%${RESET}"
    week_pace_plain="·t${week_time_pct}%"
    if [[ "$week_int" =~ ^[0-9]+$ ]]; then
      week_pace=$(( week_int - week_time_pct ))
      if [ "$week_pace" -ge 15 ]; then
        week_color="$RED_BRIGHT"
      elif [ "$week_pace" -gt 0 ] && [ "$week_color" != "$RED_BRIGHT" ]; then
        week_color="$YELLOW"
      fi
    fi
  fi
  week_part="${CYAN}7d${RESET} ${week_color}${week_pct}%${RESET}${week_pace_seg}"
  week_part_plain="7d ${week_pct}%${week_pace_plain}"
  if [[ "$week_reset" =~ ^[0-9]+$ ]]; then
    printf -v week_clock '%(%m-%d)T' "$week_reset"
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

# Maps a cached usage-API model key to a 3-char label ("Son"/"Opu"/"Fab"/
# "Hai" for the known model families, matched as a case-insensitive
# substring so "claude-sonnet-4-5" etc. all resolve the same way; an
# unrecognized name takes its OWN first 3 characters, first letter
# capitalized and the rest lowercased). NO-FORK RETURN via REPLY.
wk_label_for() {
  local key_lc="${1,,}"
  case "$key_lc" in
    *sonnet*) REPLY="Son" ;;
    *opus*) REPLY="Opu" ;;
    *fable*) REPLY="Fab" ;;
    *haiku*) REPLY="Hai" ;;
    *)
      local raw="$1" first3 f rest
      first3="${raw:0:3}"
      f="${first3:0:1}"
      rest="${first3:1}"
      REPLY="${f^}${rest,,}"
      ;;
  esac
}

# N2: OAuth weekly/extra usage (UNOFFICIAL API - included only by explicit
# user consent; the exact response shape below is a best-effort guess,
# not documented, and everything is guarded to degrade to "segment
# absent" rather than show garbage if that guess is wrong). Cache-and-
# background-refresh, modeled on the PR CI cache above: a single-row
# ~/.claude/statusline-usage-cache (epoch, extra_en, extra_used,
# extra_limit, then a VARIABLE-length tail of alternating model-name/
# percent pairs - one pair per model the API reported - real tabs from
# jq's @tsv on the write side, converted to the Unit Separator on this
# read side for the same empty-field-safety reason documented at the
# subagent script's task-row extraction; read into an ARRAY here, not
# fixed named fields, since the model count varies), refreshed by a
# fully detached/disowned background job so the render never waits on
# network. "Fresh" (<180s old) skips firing another refresh this render;
# the cached numbers stay SHOWN for up to 30 minutes even while stale-
# and-refreshing, so one slow/failed network call can't blank the
# segment outright. Missing/older-than-30min cache -> segment absent
# entirely. NOTE: this cache format is a breaking change from an earlier
# fixed sonnet/opus/fable layout - an old-format cache file left over
# from before this change parses as harmless nonsense (fails the numeric
# guards below) rather than garbage output, and self-heals on the next
# background refresh (<=180s).
# env overrides (round-3 fix): these were the LAST state files hardcoded
# to the real $HOME/.claude - `bash test.sh --assert` was writing real CI
# cache rows, spawning real `gh pr checks` for the fixture's PR, and even
# taking the user's OAuth token from .credentials.json to hit the usage
# endpoint. Same isolation contract as STATUSLINE_HISTORY_FILE etc.
usage_cache_file="${STATUSLINE_USAGE_CACHE_FILE:-$HOME/.claude/statusline-usage-cache}"
usage_backoff_file="${STATUSLINE_USAGE_BACKOFF_FILE:-$HOME/.claude/statusline-usage-backoff}"
wk_seg=""
wk_plain=""
usage_needs_refresh=1
if [ -f "$usage_cache_file" ]; then
  usage_line=""
  read -r usage_line < "$usage_cache_file"
  usage_line=${usage_line//$'\r'/}
  usage_line=${usage_line//$'\t'/$'\x1f'}
  IFS=$'\x1f' read -r -a usage_fields <<< "$usage_line"
  usage_epoch="${usage_fields[0]}"
  if [[ "$usage_epoch" =~ ^[0-9]+$ ]]; then
    usage_age=$(( now_epoch - usage_epoch ))
    # negative-age guard (clock rollback, same pattern as the CI cache):
    # a future-stamped cache would otherwise both suppress refreshes AND
    # keep serving frozen numbers for the whole rollback span
    [ "$usage_age" -lt 0 ] && usage_age=999999
    [ "$usage_age" -lt 180 ] && usage_needs_refresh=0
    if [ "$usage_age" -le 1800 ]; then
      usage_extra_en="${usage_fields[1]}"
      usage_extra_used="${usage_fields[2]}"
      usage_extra_limit="${usage_fields[3]}"
      usage_field_count=${#usage_fields[@]}

      # Find the current session's model among the cached per-model
      # entries (fields[4]/[5] = name1/pct1, fields[6]/[7] = name2/pct2,
      # ...): case-insensitive SUBSTRING match, either direction, since
      # the session's display name ("Fable 5") and the usage API's own
      # model key ("fable") are unlikely to match exactly.
      current_model_idx=-1
      current_model_pct=""
      if [ -n "$model" ]; then
        model_lc="${model,,}"
        for ((fi=4; fi<usage_field_count; fi+=2)); do
          m_name="${usage_fields[$fi]}"
          [ -z "$m_name" ] && continue
          m_name_lc="${m_name,,}"
          if [[ "$model_lc" == *"$m_name_lc"* ]] || [[ "$m_name_lc" == *"$model_lc"* ]]; then
            current_model_idx=$fi
            current_model_pct="${usage_fields[$((fi+1))]}"
            break
          fi
        done
      fi

      # OTHER models (not the current one) qualify only at >=50% usage
      # (an approaching-limit warning); collected then selection-sorted
      # descending by percent - the candidate count is always tiny (a
      # handful of models at most), so an O(n^2) pass is negligible and
      # avoids array-splice bookkeeping for an insertion sort.
      cand_names=()
      cand_pcts=()
      for ((fi=4; fi<usage_field_count; fi+=2)); do
        [ "$fi" -eq "$current_model_idx" ] && continue
        m_name="${usage_fields[$fi]}"
        m_pct="${usage_fields[$((fi+1))]}"
        [ -z "$m_name" ] && continue
        # {1,3} cap + clamp (round-6): this comes from the UNOFFICIAL
        # usage endpoint, and an out-of-int64 percent made BOTH -ge
        # tier tests fail with status 2, silently falling through to
        # the green default while printf happily rendered a 20-digit
        # "wk Fab100000000000000000000%" - the exact opposite of this
        # block's own "degrade to segment absent rather than show
        # garbage" promise.
        [[ "$m_pct" =~ ^[0-9]{1,3}(\.[0-9]+)?$ ]] || continue
        m_pct_int="${m_pct%%.*}"
        [ "$m_pct_int" -lt 50 ] && continue
        cand_names+=("$m_name")
        cand_pcts+=("$m_pct")
      done
      cand_count=${#cand_names[@]}
      cand_used=()
      for ((ui=0; ui<cand_count; ui++)); do cand_used[ui]=0; done

      wk_names=()
      wk_pcts=()
      # {1,3} cap: round-6 capped only the candidate loop below, but
      # THIS is the always-shown current-model row - an out-of-int64
      # percent made both tier tests fail with status 2 and fall
      # through to the green default with a 24-digit number rendered
      # verbatim (and the whole grid column widened to match)
      if [ "$current_model_idx" -ge 0 ] && [[ "$current_model_pct" =~ ^[0-9]{1,3}(\.[0-9]+)?$ ]]; then
        wk_names+=("${usage_fields[$current_model_idx]}")
        wk_pcts+=("$current_model_pct")
      fi
      for ((round=0; round<cand_count; round++)); do
        best_i=-1
        best_int=-1
        for ((ci=0; ci<cand_count; ci++)); do
          [ "${cand_used[$ci]}" -eq 1 ] && continue
          p_int="${cand_pcts[$ci]%%.*}"
          if [ "$p_int" -gt "$best_int" ]; then
            best_int=$p_int
            best_i=$ci
          fi
        done
        [ "$best_i" -lt 0 ] && break
        cand_used[$best_i]=1
        wk_names+=("${cand_names[$best_i]}")
        wk_pcts+=("${cand_pcts[$best_i]}")
      done

      # per-model weekly percentages: cyan 3-char label (same label
      # language as 5h/7d) + tiered percent (>=80 red / 50-79 yellow /
      # <50 green, matching the other windows' tiering), space-joined -
      # current model always first (when the cache has an entry for it),
      # any others (>=50% only) follow, descending by usage. Whole
      # segment stays absent (not a bare "wk") when neither exists.
      wk_model_parts=""
      wk_model_parts_plain=""
      wk_count=${#wk_names[@]}
      for ((wi=0; wi<wk_count; wi++)); do
        m_name="${wk_names[$wi]}"
        m_pct="${wk_pcts[$wi]}"
        wk_label_for "$m_name"; wk_label="$REPLY"
        m_pct_int="${m_pct%%.*}"
        if [ "$m_pct_int" -ge 80 ]; then
          wk_color="$RED_BRIGHT"
        elif [ "$m_pct_int" -ge 50 ]; then
          wk_color="$YELLOW"
        else
          wk_color="$GREEN"
        fi
        printf -v wk_val_disp '%.0f' "$m_pct"
        wk_one="${CYAN}${wk_label}${RESET}${wk_color}${wk_val_disp}%${RESET}"
        wk_one_plain="${wk_label}${wk_val_disp}%"
        if [ -z "$wk_model_parts" ]; then
          wk_model_parts="$wk_one"
          wk_model_parts_plain="$wk_one_plain"
        else
          wk_model_parts="${wk_model_parts} ${wk_one}"
          wk_model_parts_plain="${wk_model_parts_plain} ${wk_one_plain}"
        fi
      done
      if [ -n "$wk_model_parts" ]; then
        wk_seg="${GRAY}wk${RESET} ${wk_model_parts}"
        wk_plain="wk ${wk_model_parts_plain}"
      fi
      # extra usage (cents/100, 2dp): gray "extra " + white "$used/$limit"
      if [ "$usage_extra_en" = "1" ] && [[ "$usage_extra_used" =~ ^[0-9]{1,12}$ ]] && [[ "$usage_extra_limit" =~ ^[0-9]{1,12}$ ]]; then
        printf -v extra_used_fmt '%d.%02d' "$(( usage_extra_used / 100 ))" "$(( usage_extra_used % 100 ))"
        printf -v extra_limit_fmt '%d.%02d' "$(( usage_extra_limit / 100 ))" "$(( usage_extra_limit % 100 ))"
        extra_seg="${GRAY}extra${RESET} ${WHITE}\$${extra_used_fmt}/\$${extra_limit_fmt}${RESET}"
        extra_plain="extra \$${extra_used_fmt}/\$${extra_limit_fmt}"
        if [ -n "$wk_seg" ]; then
          wk_seg="${wk_seg} ${extra_seg}"
          wk_plain="${wk_plain} ${extra_plain}"
        else
          wk_seg="$extra_seg"
          wk_plain="$extra_plain"
        fi
      fi
    fi
  fi
fi
# Detached background refresh - fires when the cache is missing/stale
# (see above) and we're not in a post-429 backoff window (marker file:
# a single epoch, "retry no earlier than"). Never blocks the render.
if [ "$usage_needs_refresh" -eq 1 ] && command -v curl >/dev/null 2>&1; then
  usage_backoff_until=0
  if [ -f "$usage_backoff_file" ]; then
    usage_bo_line=""
    read -r usage_bo_line < "$usage_backoff_file"
    usage_bo_line=${usage_bo_line//$'\r'/}
    [[ "$usage_bo_line" =~ ^[0-9]+$ ]] && usage_backoff_until="$usage_bo_line"
  fi
  # IN-FLIGHT DEDUP (round-3 fix, same pattern as the CI badge): the 5s
  # curl timeout overlaps the 10s frame cadence, and NOTHING was written
  # on non-200/non-429 outcomes - once the (unofficial, "may vanish any
  # day" per README) endpoint failed, every frame respawned a fresh
  # subshell+jq+curl chain forever. The marker suppresses respawns for
  # 120s; every terminal outcome below now also writes a backoff row so
  # the next frames don't even fork the subshell.
  usage_inflight="${usage_backoff_file}.tmp.inflight"
  usage_spawn=1
  if [ -f "$usage_inflight" ]; then
    usage_if_epoch=""
    read -r usage_if_epoch < "$usage_inflight" 2>/dev/null
    if [[ "$usage_if_epoch" =~ ^[0-9]+$ ]]; then
      usage_if_age=$(( now_epoch - usage_if_epoch ))
      [ "$usage_if_age" -ge 0 ] && [ "$usage_if_age" -lt 120 ] && usage_spawn=0
    fi
  fi
  if [ "$now_epoch" -ge "$usage_backoff_until" ] && [ "$usage_spawn" -eq 1 ]; then
    printf '%s\n' "$now_epoch" > "$usage_inflight" 2>/dev/null
    (
      # negative-cache helper: ANY terminal outcome that is not a 200
      # write parks the next retry, converging the respawn loop
      u_backoff() {
        printf -v u_bo_now '%(%s)T' -1
        printf '%s\n' "$(( u_bo_now + $1 ))" > "${usage_backoff_file}.tmp.$$" 2>/dev/null && mv -f "${usage_backoff_file}.tmp.$$" "$usage_backoff_file" 2>/dev/null
      }
      cred_file="${STATUSLINE_CRED_FILE:-$HOME/.claude/.credentials.json}"
      if [ -f "$cred_file" ] && command -v jq >/dev/null 2>&1; then
        oauth_token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred_file" 2>/dev/null)
        if [ -n "$oauth_token" ]; then
          # tmp names MUST match the orphan-sweep glob statusline-*.tmp.*
          # (the old dot-prefixed .statusline-usage-*.$$.tmp form escaped
          # every sweep - a killed background job stranded them forever)
          usage_hdr_tmp="$HOME/.claude/statusline-usage-hdr.tmp.$$"
          usage_body_tmp="$HOME/.claude/statusline-usage-body.tmp.$$"
          usage_http_code=$(curl -sS -m 5 -D "$usage_hdr_tmp" -o "$usage_body_tmp" -w '%{http_code}' \
            -H "Authorization: Bearer $oauth_token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
          if [ "$usage_http_code" = "429" ]; then
            usage_retry_secs=300
            if [ -f "$usage_hdr_tmp" ]; then
              usage_ra_line=$(grep -i '^Retry-After:' "$usage_hdr_tmp" 2>/dev/null | tail -n1)
              usage_ra_val="${usage_ra_line#*:}"
              usage_ra_val="${usage_ra_val//[$'\r\n\t ']/}"
              [[ "$usage_ra_val" =~ ^[0-9]+$ ]] && usage_retry_secs="$usage_ra_val"
            fi
            printf -v usage_bo_now '%(%s)T' -1
            usage_bo_epoch=$(( usage_bo_now + usage_retry_secs ))
            printf '%s\n' "$usage_bo_epoch" > "${usage_backoff_file}.tmp.$$" 2>/dev/null && mv -f "${usage_backoff_file}.tmp.$$" "$usage_backoff_file" 2>/dev/null
          elif [ "$usage_http_code" = "200" ] && [ -f "$usage_body_tmp" ]; then
            # Best-effort shape: EVERY .limits[]? entry with kind==
            # "weekly_scoped" is kept (dynamic model list, not just
            # sonnet/opus/fable - the render side maps whatever name
            # shows up here to a 3-char label, with the current session's
            # model always shown and others only past the 50% warning
            # threshold), keyed by scope.model.display_name (falling back
            # to scope.model.id); a placeholder entry (percent==0 AND
            # resets_at==null) is discarded, not treated as a real 0%. If
            # the API reports no weekly_scoped entries at all, falls back
            # to the legacy .seven_day_sonnet/.seven_day_opus fields.
            # Output: extra_en, extra_used, extra_limit, then alternating
            # model-name/percent pairs (@tsv - real tabs; the render side
            # converts to the Unit Separator, same as everywhere else).
            usage_parsed=$(jq -r '
              def mname: (.scope.model.display_name // .scope.model.id // "unknown");
              ([.limits[]? | select(.kind=="weekly_scoped")
                 | select(((.percent // 0) == 0 and (.resets_at // null) == null) | not)
                 | [mname, ((.percent // 0) | tostring)]]) as $wk
              | (if ($wk | length) > 0 then $wk else
                  ([ if .seven_day_sonnet then ["sonnet", ((.seven_day_sonnet.percent // .seven_day_sonnet) | tostring)] else empty end,
                     if .seven_day_opus then ["opus", ((.seven_day_opus.percent // .seven_day_opus) | tostring)] else empty end ])
                end) as $models
              | ([
                  (if (.extra_usage.is_enabled // false) == true then "1" else "0" end),
                  ((.extra_usage.used_credits // 0) | floor | tostring),
                  ((.extra_usage.monthly_limit // 0) | floor | tostring)
                ] + ($models | flatten)) | @tsv
            ' "$usage_body_tmp" 2>/dev/null)
            if [ -n "$usage_parsed" ]; then
              printf -v usage_write_epoch '%(%s)T' -1
              printf '%s\t%s\n' "$usage_write_epoch" "$usage_parsed" > "${usage_cache_file}.tmp.$$" 2>/dev/null && mv -f "${usage_cache_file}.tmp.$$" "$usage_cache_file" 2>/dev/null
            else
              # 200 but unparseable body: park retries briefly
              u_backoff 120
            fi
          else
            # non-200/non-429 terminal outcome (timeout, DNS/offline,
            # 401/403/404, endpoint gone): short negative cache
            u_backoff 120
          fi
          rm -f "$usage_hdr_tmp" "$usage_body_tmp" 2>/dev/null
        else
          # credentials present but no usable token - won't heal fast
          u_backoff 600
        fi
      else
        # no credentials file / no jq: nothing to refresh with - park
        # long so the render path stops even forking this subshell
        u_backoff 600
      fi
      rm -f "$usage_inflight" 2>/dev/null
    ) >/dev/null 2>&1 &
    disown
  fi
fi

# 14. session name - gray, prefixed with a "» " marker (both inside the
# same gray span) so the AI-generated name doesn't read like a bare stray
# system message at the end of the line.
# (session_name already extracted by the consolidated jq call above)
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
# Widths are measured by disp_width() in TRUE terminal cells (East-Asian
# wide chars count 2), so columns containing CJK text align exactly, not
# approximately - the old character-count caveat predates disp_width and
# no longer applies. session_name additionally sits as the last cell of
# its line, so it is never padded regardless.
SEP="${RESET}${GRAY}${NBSP}|${NBSP}${RESET}"

# NARROW-TERMINAL ADAPTIVE: $COLUMNS is set by Claude Code (v2.1.153+) to
# the actual rendered width; falls back to 120 (matching this script's
# other columns-default) if unset/non-numeric. Under 100 columns, skip the
# 3-line aligned grid entirely and emit ONE compact line built from the
# *_compact_seg variants computed alongside their full segments above
# (same colors, same omission rules, no alignment/padding pass at all).
# ($COLUMNS was already normalized at the transcript block's early gate
# above - same value, one validation.)

if [ "$COLUMNS" -lt 100 ]; then
  dir_last_plain=""
  if [ "${#dir_final_comps[@]}" -gt 0 ]; then
    dir_last_plain="${dir_final_comps[$((${#dir_final_comps[@]}-1))]}"
  fi
  compact_parts=()
  [ -n "$clock" ]          && compact_parts+=("$clock")
  [ -n "$model" ]          && compact_parts+=("${CYAN_BRIGHT}${model}${RESET}")
  [ -n "$dir_last_plain" ] && compact_parts+=("${BLUE_BRIGHT}${dir_last_plain}${RESET}")
  [ -n "$branch" ]         && compact_parts+=("$branch")
  [ -n "$ctx_compact_seg" ] && compact_parts+=("$ctx_compact_seg")
  [ -n "$cost_compact_seg" ] && compact_parts+=("$cost_compact_seg")
  [ -n "$five_compact_seg" ] && compact_parts+=("$five_compact_seg")

  compact_line=""
  for part in "${compact_parts[@]}"; do
    if [ -z "$compact_line" ]; then
      compact_line="$part"
    else
      compact_line="${compact_line}${SEP}${part}"
    fi
  done
  printf '%s\n' "${RESET}${compact_line}${RESET}"
else
  # Line 1: identity/location
  parts1=()
  parts1_plain=()
  [ -n "$clock" ]        && { parts1+=("$clock"); parts1_plain+=("$clock_plain"); }
  [ -n "$model_seg" ]    && { parts1+=("$model_seg"); parts1_plain+=("$model_plain"); }
  [ -n "$dir_display" ]  && { parts1+=("$dir_display"); parts1_plain+=("$dir_plain"); }
  [ -n "$wt_seg" ]       && { parts1+=("$wt_seg"); parts1_plain+=("$wt_plain"); }
  [ -n "$repo" ]         && { parts1+=("$repo"); parts1_plain+=("$repo_plain"); }
  [ -n "$branch" ]       && { parts1+=("$branch"); parts1_plain+=("$branch_plain"); }
  [ -n "$stash_seg" ]    && { parts1+=("$stash_seg"); parts1_plain+=("$stash_plain"); }
  [ -n "$pr_seg" ]       && { parts1+=("$pr_seg"); parts1_plain+=("$pr_plain"); }

  # Line 2: context engine
  parts2=()
  parts2_plain=()
  [ -n "$ctx_seg" ]     && { parts2+=("$ctx_seg"); parts2_plain+=("$ctx_plain"); }
  [ -n "$tokrate_seg" ] && { parts2+=("$tokrate_seg"); parts2_plain+=("$tokrate_plain"); }
  [ -n "$cache_seg" ]   && { parts2+=("$cache_seg"); parts2_plain+=("$cache_plain"); }
  [ -n "$compact_seg" ] && { parts2+=("$compact_seg"); parts2_plain+=("$compact_plain"); }

  # Line 3: spend
  parts3=()
  parts3_plain=()
  [ -n "$cost_seg" ]  && { parts3+=("$cost_seg"); parts3_plain+=("$cost_plain"); }
  [ -n "$today_seg" ] && { parts3+=("$today_seg"); parts3_plain+=("$today_plain"); }
  [ -n "$week_seg" ]  && { parts3+=("$week_seg"); parts3_plain+=("$week_plain"); }
  [ -n "$lines_seg" ] && { parts3+=("$lines_seg"); parts3_plain+=("$lines_plain"); }

  # Line 4: quota & session
  parts4=()
  parts4_plain=()
  [ -n "$rl_seg" ]       && { parts4+=("$rl_seg"); parts4_plain+=("$rl_plain"); }
  [ -n "$wk_seg" ]       && { parts4+=("$wk_seg"); parts4_plain+=("$wk_plain"); }
  [ -n "$session_name" ] && { parts4+=("$session_name"); parts4_plain+=("$session_name_plain"); }

  max_cols=${#parts1[@]}
  [ "${#parts2[@]}" -gt "$max_cols" ] && max_cols=${#parts2[@]}
  [ "${#parts3[@]}" -gt "$max_cols" ] && max_cols=${#parts3[@]}
  [ "${#parts4[@]}" -gt "$max_cols" ] && max_cols=${#parts4[@]}

  # WIDTH MEMO (round-6): every cell's width is measured ONCE here and
  # kept in parallel parts{N}_w arrays; render_line looks them up
  # instead of re-measuring. disp_width walks a string character by
  # character, and ${s:i:1} on UTF-8 is an O(i) byte scan, so a cell
  # holding the battery/sparkline/arrow glyphs costs real time - the
  # second measurement pass was a measured ~13ms of pure duplicate work
  # per frame.
  col_widths=()
  parts1_w=(); parts2_w=(); parts3_w=(); parts4_w=()
  for ((ci=0; ci<max_cols; ci++)); do
    w=0
    if [ "$ci" -lt "${#parts1_plain[@]}" ]; then
      disp_width "${parts1_plain[$ci]}"; l="$REPLY"; parts1_w+=("$l")
      [ "$l" -gt "$w" ] && w=$l
    fi
    if [ "$ci" -lt "${#parts2_plain[@]}" ]; then
      disp_width "${parts2_plain[$ci]}"; l="$REPLY"; parts2_w+=("$l")
      [ "$l" -gt "$w" ] && w=$l
    fi
    if [ "$ci" -lt "${#parts3_plain[@]}" ]; then
      disp_width "${parts3_plain[$ci]}"; l="$REPLY"; parts3_w+=("$l")
      [ "$l" -gt "$w" ] && w=$l
    fi
    if [ "$ci" -lt "${#parts4_plain[@]}" ]; then
      disp_width "${parts4_plain[$ci]}"; l="$REPLY"; parts4_w+=("$l")
      [ "$l" -gt "$w" ] && w=$l
    fi
    col_widths+=("$w")
  done

  # Renders one line: $1/$2 are the NAMES of its colored/plain arrays
  # (nameref, bash 4.3+). Every cell but the last is right-padded with
  # spaces to col_widths[i] before the separator; the last cell is bare.
  # NO-FORK RETURN via global REPLY, same as every other helper in this
  # script - called 4x/render (not per-loop), but its OWN inner loop is
  # per-cell, and disp_width()/the padding printf inside that loop were
  # both still forking per call before this fix.
  render_line() {
    local -n cparts="$1"
    local -n pparts="$2"
    local -n wparts="$3"
    local n=${#cparts[@]}
    local out="" ci cell plen w pad padding
    for ((ci=0; ci<n; ci++)); do
      cell="${cparts[$ci]}"
      if [ "$ci" -lt "$((n-1))" ]; then
        plen="${wparts[$ci]}"
        w="${col_widths[$ci]}"
        pad=$(( w - plen ))
        padding=""
        if [ "$pad" -gt 0 ]; then
          printf -v padding '%*s' "$pad" ''
          padding=${padding// /$NBSP}
        fi
        out="${out}${cell}${padding}${SEP}"
      else
        out="${out}${cell}"
      fi
    done
    REPLY="$out"
  }

  render_line parts1 parts1_plain parts1_w; line1="$REPLY"
  render_line parts2 parts2_plain parts2_w; line2="$REPLY"
  render_line parts3 parts3_plain parts3_w; line3="$REPLY"
  render_line parts4 parts4_plain parts4_w; line4="$REPLY"

  printf '%s\n' "${RESET}${line1}${RESET}"
  [ -n "$line2" ] && printf '%s\n' "${RESET}${line2}${RESET}"
  [ -n "$line3" ] && printf '%s\n' "${RESET}${line3}${RESET}"
  [ -n "$line4" ] && printf '%s\n' "${RESET}${line4}${RESET}"
fi

# EXPLICIT SUCCESS (round-7): the last statement above is a
# `[ -n ... ] && printf` short-circuit, so a payload whose 4th line is
# empty (no rate_limits - API-key/Bedrock/Vertex accounts have none -
# plus no session_name and no wk cache) made the SCRIPT exit 1 even
# after printing three perfectly good lines, tripping this project's
# own "a non-zero exit blanks the whole bar" red line. Nothing caught
# it because every assertion only ever inspected stdout.
exit 0
