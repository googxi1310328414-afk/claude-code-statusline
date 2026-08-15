#!/bin/bash
# Demo + assertion suite for both statusline scripts.
#   bash test.sh            # render all fixtures (see real colors in your terminal)
#   bash test.sh --codes    # show ANSI escapes as \e[..m for inspection
#   bash test.sh --assert   # silent checks, non-zero exit on failure (CI mode)
export LC_ALL=C.UTF-8
cd "$(dirname "$0")" || exit 1

# 全程使用隔离历史文件——绝不触碰真实 ~/.claude/statusline-history.tsv
export STATUSLINE_HISTORY_FILE="$(mktemp -u)/test-hist.tsv" 2>/dev/null || export STATUSLINE_HISTORY_FILE="/tmp/statusline-test-hist.$$"
mkdir -p "$(dirname "$STATUSLINE_HISTORY_FILE")"
export STATUSLINE_SUBAGENT_TREND_FILE="$(dirname "$STATUSLINE_HISTORY_FILE")/test-subtrend.tsv"
export STATUSLINE_PANEL_DIR="$(dirname "$STATUSLINE_HISTORY_FILE")/panel.d"
export STATUSLINE_PANEL_DAEMON=/dev/null
export STATUSLINE_PANEL_RENDERER="$PWD/subagent-statusline.sh"
mkdir -p "$STATUSLINE_PANEL_DIR"
export STATUSLINE_DAILY_FILE="$(dirname "$STATUSLINE_HISTORY_FILE")/test-daily.tsv"
# round-3 isolation: CI/usage caches and the OAuth credential path were
# the LAST state files hardcoded to the real ~/.claude - running this
# suite used to write real CI cache rows, spawn real `gh pr checks`, and
# hit the usage endpoint with the user's real token. The nonexistent
# cred path makes every usage refresh park itself in the isolated
# backoff file with zero network and zero credential reads.
export STATUSLINE_CI_CACHE_PREFIX="$(dirname "$STATUSLINE_HISTORY_FILE")/test-ci-cache"
export STATUSLINE_USAGE_CACHE_FILE="$(dirname "$STATUSLINE_HISTORY_FILE")/test-usage-cache"
export STATUSLINE_USAGE_BACKOFF_FILE="$(dirname "$STATUSLINE_HISTORY_FILE")/test-usage-backoff"
export STATUSLINE_CRED_FILE="$(dirname "$STATUSLINE_HISTORY_FILE")/no-such-credentials.json"
trap 'rm -rf "$(dirname "$STATUSLINE_HISTORY_FILE")"' EXIT

strip() { perl -pe 's/\e\[[0-9;]*m//g; s/\e\]8;;[^\e]*\e\\//g'; }
filter() { if [ "$1" = "--codes" ]; then sed 's/\x1b/\\e/g'; else cat; fi; }

make_history() {  # canonical 0x1f rows: 3 for session abc
  local now=$1 f=$2
  printf "%s\x1fabc\x1f%s\x1f%s\n" \
    "$((now-240))" 50000 0.10 \
    "$((now-120))" 58000 0.22 \
    "$((now-8))"   66000 0.38 > "$f"
}

make_transcript() {  # fake transcript: 2 compact boundaries + cache-active assistant
  local f=$1 ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  printf '%s\n' \
    '{"type":"user","message":{"role":"user"},"timestamp":"2026-08-13T00:00:00.000Z"}' \
    '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":180000,"postTokens":60000},"timestamp":"2026-08-13T01:00:00.000Z"}' \
    '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":150000,"postTokens":40000},"timestamp":"2026-08-13T02:00:00.000Z"}' \
    "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":2000,\"cache_read_input_tokens\":50000,\"cache_creation_input_tokens\":300,\"output_tokens\":500}},\"timestamp\":\"$ts\"}" > "$f"
}

subagent_payload() {  # 3 tasks: ms/s/none timestamps
  jq -n --argjson now "$1" '{columns:150,tasks:[
    {id:"ms",label:"毫秒探针",status:"running",tokenCount:5000,startTime:(($now-300)*1000),description:"d"},
    {id:"s",label:"秒探针",status:"completed",tokenCount:8000,startTime:($now-300),description:"d"},
    {id:"none",label:"无时间探针",status:"failed",tokenCount:3000,description:"d"}]}'
}

if [ "$1" = "--assert" ]; then
  fails=0
  ok()  { echo "PASS  $1"; }
  bad() { echo "FAIL  $1"; fails=$((fails+1)); }
  tmpd=$(mktemp -d)
  now=$(date +%s)
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  make_transcript "$tmpd/tr.jsonl"

  t0=$EPOCHREALTIME
  out=$(jq --argjson n "$now" --arg tp "$tmpd/tr.jsonl" \
        '.rate_limits.five_hour.resets_at=($n+7200) | .rate_limits.seven_day.resets_at=($n+259200) | .transcript_path=$tp' \
        fixtures/full.json | bash ./statusline-command.sh)
  t1=$EPOCHREALTIME
  plain=$(printf '%s\n' "$out" | strip)

  [ "$(printf '%s\n' "$plain" | wc -l)" -eq 4 ] && ok "main renders 4 lines" || bad "main line count != 4"
  printf '%s' "$plain" | grep -q 'ctx ' && ok "ctx label" || bad "ctx label missing"
  printf '%s' "$plain" | grep -qE '[▁▂▃▄▅▆]' && ok "sparkline present (capped glyphs)" || bad "sparkline missing"
  printf '%s' "$plain" | grep -q '█' && ok "battery bar" || bad "battery bar missing"
  printf '%s' "$plain" | grep -q 'cache 92.3%' && ok "cache one-decimal" || bad "cache decimal wrong"
  printf '%s' "$plain" | grep -q '↻2' && ok "compaction count" || bad "compaction missing"
  printf '%s' "$plain" | grep -q 'week \$' && ok "week rollup" || bad "week missing"
  printf '%s' "$plain" | grep -q '·t' && ok "pace cursor" || bad "pace cursor missing"
  printf '%s' "$plain" | grep -q '» my-session' && ok "session name marker" || bad "session marker missing"
  printf '%s' "$plain" | grep -q 'fable-5·max·think' && ok "main model panel-synced short id" || bad "main model name not synced"
  # SEPARATORS ARE NBSP|NBSP (U+00A0 padding, not ASCII spaces): the old
  # ASCII ' | ' / '| |' patterns matched NOTHING in real output, so the
  # alignment and empty-cell asserts had passed unconditionally since
  # they were written (dead assertions - adversarial review 2026-08-14,
  # proven by breaking the padding and still getting ALL PASS). NBSP is
  # bound ONCE here and a liveness assert proves the pattern still
  # occurs at all, so any future separator restyle fails LOUDLY instead
  # of going silently dead again.
  NBSP=$(printf '\302\240')
  SEPPAT="${NBSP}|${NBSP}"
  sep_count=$(printf '%s' "$plain" | grep -o "$SEPPAT" | wc -l)
  [ "$sep_count" -ge 4 ] && ok "NBSP separator liveness (pattern matches real output)" || bad "NBSP separator pattern matches nothing - asserts dead again"
  printf '%s' "$plain" | grep -qE "\|(${NBSP})+\|" && bad "stray empty cell (sep-pad-sep)" || ok "no stray empty cells"
  # first-column separator aligns across all 4 lines - compared in
  # CHARACTERS (bash ${#} under the UTF-8 locale), NOT bytes: the cells
  # contain multibyte glyphs (█ ░ │ ⚑ ...), so byte offsets legitimately
  # differ across perfectly aligned lines
  col=""
  aligned=1
  while IFS= read -r ln; do
    case "$ln" in
      *"$SEPPAT"*)
        pre=${ln%%"$SEPPAT"*}
        if [ -z "$col" ]; then col=${#pre}
        elif [ "${#pre}" != "$col" ]; then aligned=0; fi
        ;;
    esac
  done <<< "$plain"
  [ -n "$col" ] || aligned=0
  [ "$aligned" -eq 1 ] && ok "first separator aligned (char-wise)" || bad "first separator misaligned"
  awk -v a="$t0" -v b="$t1" 'BEGIN{exit (b-a < 3.0) ? 0 : 1}' && ok "render < 3s" || bad "render too slow"
  printf '%s' "$plain" | grep -q '·t60%' && ok "pace cursor value (t60%)" || bad "pace value wrong"

  narrow=$(COLUMNS=80 bash ./statusline-command.sh < fixtures/full.json | strip)
  [ "$(printf '%s\n' "$narrow" | wc -l)" -eq 1 ] && ok "narrow mode single line" || bad "narrow mode line count"
  printf '%s' "$narrow" | grep -q 'today' && bad "narrow leaks wide segments" || ok "narrow drops wide segments"

  hotout=$(make_transcript "$tmpd/tr2.jsonl"; jq --arg tp "$tmpd/tr2.jsonl" '.transcript_path=$tp' fixtures/full.json | bash ./statusline-command.sh | strip)
  printf '%s' "$hotout" | grep -q ' hot' && ok "cache hot state" || bad "hot state missing"
  oldts=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%S.000Z)
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"usage\":{\"cache_read_input_tokens\":50000}},\"timestamp\":\"$oldts\"}" > "$tmpd/tr3.jsonl"
  coldout=$(jq --arg tp "$tmpd/tr3.jsonl" '.transcript_path=$tp' fixtures/full.json | bash ./statusline-command.sh | strip)
  printf '%s' "$coldout" | grep -q 'cold' && ok "cache cold state" || bad "cold state missing"

  # REGRESSION (sentinel fix): fixtures/full.json has NO transcript_path, so
  # jq's raw output ends in a run of newlines that $() strips entirely -
  # pre-sentinel builds miscounted the fields and false-tripped the
  # "degraded (fork)" line on this perfectly healthy payload. (The narrow
  # assertions above masked it: degraded output is also exactly 1 line.)
  bare=$(bash ./statusline-command.sh < fixtures/full.json | strip)
  printf '%s' "$bare" | grep -q 'degraded' && bad "empty-tail payload false degraded" || ok "empty-tail payload not degraded"
  [ "$(printf '%s\n' "$bare" | wc -l)" -eq 4 ] && ok "empty-tail payload full 4-line render" || bad "empty-tail payload line count != 4"

  # two-tier spend store: the renders above must have seeded the daily
  # rollup (watermark path) from the same-day fixture history rows
  grep -q "^$(date +%Y%m%d)" "$STATUSLINE_DAILY_FILE" 2>/dev/null && ok "daily rollup seeded" || bad "daily rollup missing"
  # week must survive on the rollup alone (no fine rows): yesterday-only
  # rollup row, closed 500 + peak 250 cents = $7.50
  yday=$(date -d yesterday +%Y%m%d 2>/dev/null || date -v-1d +%Y%m%d)
  printf "%s\x1fzzz\x1f500\x1f250\x1f250\x1f%s\n" "$yday" "$((now-86400))" > "$STATUSLINE_DAILY_FILE"
  : > "$STATUSLINE_HISTORY_FILE"
  wkonly=$(bash ./statusline-command.sh < fixtures/minimal.json | strip)
  printf '%s' "$wkonly" | grep -q 'week \$7.50' && ok "week from rollup alone" || bad "rollup-only week wrong"
  # append-first write: an over-slack (4h) row must trigger the full
  # rewrite and get purged, while fresh rows survive (last fresh row is
  # comfortably >=30s old - the sampling throttle - even on a fast CI
  # runner that reaches this assert seconds after `now` was captured,
  # so the render actually appends and hits the write path)
  {
    printf "%s\x1fabc\x1f100\x1f0.01\n" "$((now-14400))"
    printf "%s\x1fabc\x1f%s\x1f%s\n" "$((now-240))" 50000 0.10 "$((now-120))" 58000 0.22 "$((now-45))" 66000 0.38
  } > "$STATUSLINE_HISTORY_FILE"
  bash ./statusline-command.sh < fixtures/full.json >/dev/null
  if grep -q "^$((now-14400))" "$STATUSLINE_HISTORY_FILE"; then bad "over-slack row survived rewrite"; else ok "aged row purged by rewrite trigger"; fi
  make_history "$now" "$STATUSLINE_HISTORY_FILE"

  # stash segment: count rides the same single git call (--porcelain=v2
  # --branch --show-stash); also guards the v1->v2 branch-parse rewrite
  stash_tmp=$(mktemp -d)
  git -C "$stash_tmp" init -q -b main 2>/dev/null || git -C "$stash_tmp" init -q
  git -C "$stash_tmp" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
  echo one > "$stash_tmp/s.txt"
  git -C "$stash_tmp" add s.txt
  git -C "$stash_tmp" -c user.email=t@t -c user.name=t stash -q
  stashed=$(jq --arg d "$stash_tmp" '.workspace.current_dir=$d' fixtures/full.json | bash ./statusline-command.sh | strip)
  printf '%s' "$stashed" | grep -q '⚑1' && ok "stash count segment" || bad "stash segment missing"
  printf '%s' "$stashed" | grep -q 'main' && ok "branch parsed (v2)" || bad "branch missing after v2 switch"
  git -C "$stash_tmp" stash clear
  echo x > "$stash_tmp/untracked.txt"
  nostash=$(jq --arg d "$stash_tmp" '.workspace.current_dir=$d' fixtures/full.json | bash ./statusline-command.sh | strip)
  printf '%s' "$nostash" | grep -q '⚑' && bad "stash glyph at zero stashes" || ok "stash hidden at zero"
  printf '%s' "$nostash" | grep -q 'main\*' && ok "dirty star (v2 entries)" || bad "dirty star missing"
  rm -rf "$stash_tmp"

  sub=$(subagent_payload "$now" | bash ./subagent-statusline.sh)
  [ "$(printf '%s\n' "$sub" | wc -l)" -eq 3 ] && ok "subagent 3 rows" || bad "subagent row count"
  all_json=1
  while IFS= read -r l; do printf '%s' "$l" | jq -e . >/dev/null 2>&1 || all_json=0; done <<< "$sub"
  [ "$all_json" -eq 1 ] && ok "subagent rows valid JSON" || bad "subagent invalid JSON"
  printf '%s' "$sub" | jq -r .content 2>/dev/null | strip | grep -q '5k tok' && ok "subagent field order (TSV fix)" || bad "subagent fields scrambled"
  solo=$(jq -n --argjson now "$now" '{columns:120,tasks:[{id:"t1",label:"solo",status:"running",tokenCount:5000,startTime:(($now-120)*1000),description:"x"}]}' | bash ./subagent-statusline.sh | jq -r .content | strip)
  printf '%s' "$solo" | grep -qE "\|(${NBSP})+\|" && bad "solo row empty cell" || ok "solo row clean"
  printf '%s' "$solo" | grep -q 'Σ' && bad "solo row shows share" || ok "solo hides share"
  # model is a STANDALONE cell (not glued to the identity), always shown
  # when present, with the "[1m]" capacity tag KEPT verbatim
  modrow=$(jq -n --argjson now "$now" '{columns:120,tasks:[{id:"m1",label:"a",status:"running",tokenCount:5,model:"claude-fable-5[1m]",startTime:(($now-30)*1000),description:"d"}]}' | bash ./subagent-statusline.sh | jq -r .content | strip)
  # NOTE: separators are NBSP-padded ("|" between NBSPs), so match the
  # bare name; '·fable-5' absent proves it is NOT glued to the identity
  printf '%s' "$modrow" | grep -q 'fable-5\[1m\]' && ! printf '%s' "$modrow" | grep -q '·fable-5' && ok "model standalone cell keeps tag" || bad "model cell wrong"

  # own 10s trend state: the renders above created one row per tokened
  # task (3 from the panel payload + solo t1 + the model-marker probe m1)
  [ "$(grep -c . "$STATUSLINE_SUBAGENT_TREND_FILE" 2>/dev/null)" -eq 5 ] && ok "subagent trend rows captured" || bad "subagent trend file wrong"
  # pre-seeded trend csv (plus this render's fresh sample) drives the
  # sparkline as primary source
  printf "ms\x1f%s\x1f1000,3000,4000\n" "$((now-10))" > "$STATUSLINE_SUBAGENT_TREND_FILE"
  spark=$(subagent_payload "$now" | bash ./subagent-statusline.sh | jq -r 'select(.id=="ms") | .content' | strip)
  printf '%s' "$spark" | grep -qE '[▁▂▃▄▅▆]' && ok "subagent sparkline from own samples" || bad "own-sample sparkline missing"

  # ---- adversarial-review round-1 regression asserts (2026-08-14) ----
  BSL=$(printf '\134')
  # R1: @tsv backslash decode - a Windows path in a description renders
  # with SINGLE backslashes (was doubled), and the row stays valid JSON
  bsrow=$(jq -n --arg d "edit C:${BSL}Users${BSL}me${BSL}app.js" '{columns:200,tasks:[{id:"bs1",label:"L",status:"running",tokenCount:5000,description:$d}]}' | bash ./subagent-statusline.sh)
  printf '%s' "$bsrow" | jq -e . >/dev/null 2>&1 && ok "backslash row valid JSON" || bad "backslash row invalid JSON"
  bs_content=$(printf '%s' "$bsrow" | jq -r .content | strip)
  case "$bs_content" in
    *"C:${BSL}${BSL}Users"*) bad "backslash still doubled" ;;
    *"C:${BSL}Users${BSL}me"*) ok "@tsv backslash decoded once" ;;
    *) bad "backslash path missing entirely" ;;
  esac
  # R2: a raw C0 (0x1F) inside a field neither shifts columns nor breaks
  # the emitted JSON (jq-side clean strips it before @tsv)
  c0row=$(jq -n '{columns:150,tasks:[{id:"c0",label:("A"+"\u001f"+"B"),status:"running",startTime:1755100000000,tokenCount:5000,description:"real"}]}' | bash ./subagent-statusline.sh)
  printf '%s' "$c0row" | jq -e . >/dev/null 2>&1 && ok "C0 row valid JSON" || bad "C0 row invalid JSON"
  printf '%s' "$c0row" | grep -q '1755100000k tok' && bad "C0 shifted startTime into token slot" || ok "C0 does not shift fields"
  # R3: an embedded newline in session_name must NOT degrade the whole
  # bar (jq-side clean folds it; the F[] sentinel stays at F[30])
  nlout=$(jq -n '{session_id:"nl1",model:{display_name:"M"},workspace:{current_dir:"/x"},session_name:("a"+"\n"+"b")}' | bash ./statusline-command.sh | strip)
  printf '%s' "$nlout" | grep -q 'degraded' && bad "newline session_name degraded bar" || ok "newline session_name survives"
  printf '%s' "$nlout" | grep -q '» a b' && ok "newline folded to space" || bad "newline fold missing"
  # R4: ctx fallback guards - negative remaining clamps to the red !0%
  # alarm; a garbage string drops the segment (no printf noise, no green)
  negout=$(jq -n '{session_id:"neg1",model:{display_name:"M"},workspace:{current_dir:"/x"},context_window:{remaining_percentage:-7.4}}' | bash ./statusline-command.sh | strip)
  printf '%s' "$negout" | grep -q 'ctx !' && printf '%s' "$negout" | grep -q ' 0%' && ok "negative remaining clamps to !0%" || bad "negative remaining unguarded"
  garbout=$(jq -n '{session_id:"garb1",model:{display_name:"M"},workspace:{current_dir:"/x"},context_window:{remaining_percentage:"12abc"}}' | bash ./statusline-command.sh | strip)
  printf '%s' "$garbout" | grep -q 'ctx' && bad "garbage remaining rendered ctx" || ok "garbage remaining drops segment"
  # R5: home-prefix boundary - a SIBLING profile directory must not be
  # abbreviated as "~..."
  sibout=$(jq -n --arg d "C:${BSL}Users${BSL}Administrator.DOMAIN${BSL}proj" '{session_id:"sib1",model:{display_name:"M"},workspace:{current_dir:$d}}' | USERPROFILE="C:${BSL}Users${BSL}Administrator" bash ./statusline-command.sh | strip)
  printf '%s' "$sibout" | grep -q '~.DOMAIN' && bad "sibling profile abbreviated as home" || ok "home boundary respected"
  # R6: daemon hung-child deadline - a wedged renderer is killed at the
  # timeout, the frame is skipped, --once returns promptly (this was the
  # permanent all-session panel freeze)
  printf '#!/bin/bash\nsleep 300\n' > "$tmpd/hangrender.sh"
  printf '{"columns":120,"tasks":[{"id":"tmo1","label":"x","status":"running","tokenCount":5}]}' > "$STATUSLINE_PANEL_DIR/spool.tmo1.new"
  tmo_t0=$SECONDS
  STATUSLINE_PANEL_RENDERER="$tmpd/hangrender.sh" STATUSLINE_PANEL_RENDER_TIMEOUT=1 bash ./statusline-panel-daemon.sh --once
  tmo_el=$(( SECONDS - tmo_t0 ))
  [ "$tmo_el" -lt 6 ] && ok "daemon kills hung render at deadline" || bad "daemon blocked on hung render (${tmo_el}s)"
  [ -f "$STATUSLINE_PANEL_DIR/cache.tmo1" ] && bad "hung render left a cache" || ok "hung render frame skipped"
  # R7: clock rollback - a future-epoch history row must not freeze the
  # 30s sampling throttle (this render still appends a fresh row)
  printf "%s\x1fabc\x1f70000\x1f0.50\n" "$((now+7200))" > "$STATUSLINE_HISTORY_FILE"
  bash ./statusline-command.sh < fixtures/full.json >/dev/null
  # round-8: a future-stamped row is now PURGED by the forced rewrite
  # (the head probe can find no usable epoch), so the check is "a fresh
  # sample exists", not "the old row is still there"
  fresh_ok=0
  while IFS= read -r _hl; do
    _he=${_hl%%$''*}
    [[ "$_he" =~ ^[0-9]+$ ]] || continue
    [ "$_he" -le "$((now+60))" ] && [ "$_he" -ge "$((now-60))" ] && fresh_ok=1
  done < "$STATUSLINE_HISTORY_FILE"
  [ "$fresh_ok" -eq 1 ] && ok "future-epoch row does not freeze sampling" || bad "clock rollback froze sampling"
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  # R8: transcript tail cost is O(matches) via the awk pre-filter, not
  # O(bytes) via mapfile: a ~500KiB filler transcript renders fast and
  # still finds the newest cache-active line
  filler=$(printf 'x%.0s' {1..400})
  {
    for ((fi=0; fi<1200; fi++)); do printf '{"type":"user","message":{"content":"%s"},"uuid":"u%s"}\n' "$filler" "$fi"; done
    printf '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":50000}},"timestamp":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  } > "$tmpd/big.jsonl"
  t8a=$EPOCHREALTIME
  bigout=$(jq --arg tp "$tmpd/big.jsonl" '.transcript_path=$tp' fixtures/full.json | bash ./statusline-command.sh | strip)
  t8b=$EPOCHREALTIME
  printf '%s' "$bigout" | grep -q ' hot' && ok "big-transcript cache line found via awk" || bad "big-transcript cache line missed"
  awk -v a="$t8a" -v b="$t8b" 'BEGIN{exit (b-a < 2.5) ? 0 : 1}' && ok "big-transcript render < 2.5s (O(bytes) split gone)" || bad "big-transcript render too slow"
  # R9: the watchdog VBS must stay pure ASCII - wscript parses .vbs as
  # the system ANSI codepage (GBK on zh-CN), where a line-final UTF-8
  # multibyte char whose last byte is a DBCS lead SWALLOWS the following
  # newline and comments out real code (fired in production: the Set
  # line got eaten, every 2-min task run popped an error dialog)
  LC_ALL=C grep -qP '[\x80-\xff]' statusline-watchdog.vbs && bad "watchdog vbs contains non-ASCII bytes" || ok "watchdog vbs pure ASCII"

  # ---- adversarial-review round-2 regression asserts (2026-08-14) ----
  # R10: garbage rate-limit percentage drops the segment (no green "0%")
  rl_garb=$(jq -n '{session_id:"rg",model:{display_name:"M"},workspace:{current_dir:"/x"},rate_limits:{five_hour:{used_percentage:"garbage",resets_at:"soon"}}}' | bash ./statusline-command.sh | strip)
  printf '%s' "$rl_garb" | grep -q '5h' && bad "garbage 5h rendered fake data" || ok "garbage 5h segment dropped"
  # R11: raw ESC/BEL in session_name must NOT reach stdout (OSC-injection)
  escout=$(jq -n '{session_id:"esc",model:{display_name:"M"},workspace:{current_dir:"/x"},session_name:("evil"+"\u001b"+"]0;PWNED"+"\u0007"+"tail")}' | bash ./statusline-command.sh)
  if printf '%s' "$escout" | LC_ALL=C grep -qP '\\x1b\\]0;PWNED'; then
    bad "session_name OSC injection reaches terminal"
  elif printf '%s' "$escout" | grep -q 'PWNED'; then
    ok "session_name C0 stripped (OSC text inert)"
  else
    bad "session_name vanished entirely"
  fi
  # R12: a future-day rollup row must not inflate the week sum
  futday=$(date -d '+5 days' +%Y%m%d 2>/dev/null || date -v+5d +%Y%m%d)
  printf "%s\x1fghost\x1f500\x1f250\x1f250\x1f0\n" "$futday" > "$STATUSLINE_DAILY_FILE"
  ghostout=$(bash ./statusline-command.sh < fixtures/minimal.json | strip)
  printf '%s' "$ghostout" | grep -q 'week \$7.50' && bad "ghost future-day row counted into week" || ok "future-day rollup row dropped"
  : > "$STATUSLINE_DAILY_FILE"
  # R13: empty current_dir must NOT run git in the script's CWD (we ARE
  # in a git repo right now - a leaked branch segment would show main)
  nodir=$(jq -n '{session_id:"nd",model:{display_name:"M"}}' | bash ./statusline-command.sh | strip | head -1)
  printf '%s' "$nodir" | grep -qE '\bmain\b' && bad "empty dir leaked CWD repo branch" || ok "empty dir renders no git segments"
  # R14: non-string task id must not fabricate a cache key from the next
  # JSON key name (hook would cross-serve sessions) - no spool, no output
  rm -f "$STATUSLINE_PANEL_DIR"/spool.* 2>/dev/null
  numout=$(printf '{"columns":120,"tasks":[{"id":123,"name":"x","status":"running"}]}' | bash ./statusline-panel-hook.sh)
  if [ -z "$numout" ] && ! ls "$STATUSLINE_PANEL_DIR"/spool.* >/dev/null 2>&1; then ok "numeric id yields no cache key"; else bad "numeric id fabricated a key"; fi
  # R15: a renderer that exits 0 with EMPTY output must not clobber the
  # last good cache frame (fork-exhaustion blank-frame guard)
  printf '#!/bin/bash\nexit 0\n' > "$tmpd/emptyrender.sh"
  printf '%s\n%s\n' "$(date +%s)" '{"id":"tmo2","content":"GOOD_FRAME"}' > "$STATUSLINE_PANEL_DIR/cache.tmo2"
  printf '{"columns":120,"tasks":[{"id":"tmo2","label":"x","status":"running","tokenCount":5}]}' > "$STATUSLINE_PANEL_DIR/spool.tmo2.new"
  STATUSLINE_PANEL_RENDERER="$tmpd/emptyrender.sh" bash ./statusline-panel-daemon.sh --once
  grep -q GOOD_FRAME "$STATUSLINE_PANEL_DIR/cache.tmo2" 2>/dev/null && ok "empty render keeps last good frame" || bad "empty render clobbered cache"

  # ---- adversarial-review round-3 regression asserts (2026-08-14) ----
  # R16: usage refresh must converge on failure - with an unreadable
  # credential path (exported at the top), one render writes a negative-
  # cache row into the ISOLATED backoff file, and the real ~/.claude
  # backoff is never created/touched
  real_bo="$HOME/.claude/statusline-usage-backoff"
  real_bo_sig="absent"
  [ -f "$real_bo" ] && real_bo_sig=$(date -r "$real_bo" +%s 2>/dev/null || echo present)
  rm -f "$STATUSLINE_USAGE_BACKOFF_FILE"
  jq -n --argjson n "$now" '{session_id:"ub1",model:{display_name:"M"},workspace:{current_dir:"/x"},rate_limits:{five_hour:{used_percentage:10,resets_at:($n+7200)}}}' | bash ./statusline-command.sh >/dev/null
  ub_ok=0
  for _w in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$STATUSLINE_USAGE_BACKOFF_FILE" ] && { ub_ok=1; break; }
    sleep 0.3
  done
  [ "$ub_ok" -eq 1 ] && ok "usage failure writes isolated negative cache" || bad "usage backoff not written"
  real_bo_sig2="absent"
  [ -f "$real_bo" ] && real_bo_sig2=$(date -r "$real_bo" +%s 2>/dev/null || echo present)
  [ "$real_bo_sig" = "$real_bo_sig2" ] && ok "real ~/.claude usage state untouched by tests" || bad "test leaked into real ~/.claude usage state"
  # R17: three consecutive bad frames make the daemon EMPTY the cache
  # (honest degradation instead of serving stale numbers forever) -
  # needs the RESIDENT daemon since the streak lives in its memory
  printf '%s\n%s\n' "$(date +%s)" '{"id":"st1","content":"STALE_FRAME"}' > "$STATUSLINE_PANEL_DIR/cache.st1"
  STATUSLINE_PANEL_RENDERER="$tmpd/emptyrender.sh" STATUSLINE_PANEL_DIR="$STATUSLINE_PANEL_DIR" bash ./statusline-panel-daemon.sh &
  st_dpid=$!
  for _i in 1 2 3; do
    printf '{"columns":120,"tasks":[{"id":"st1","label":"x","status":"running","tokenCount":5}]}' > "$STATUSLINE_PANEL_DIR/spool.st1.new"
    sleep 0.8
  done
  st_ok=0
  for _w in 1 2 3 4 5; do
    if [ -f "$STATUSLINE_PANEL_DIR/cache.st1" ] && [ ! -s "$STATUSLINE_PANEL_DIR/cache.st1" ]; then st_ok=1; break; fi
    sleep 0.4
  done
  kill "$st_dpid" 2>/dev/null; wait "$st_dpid" 2>/dev/null
  [ "$st_ok" -eq 1 ] && ok "bad-frame streak empties stale cache" || bad "stale cache survived persistent failure"
  # R18: a live-but-recycled pid (fresh process, STALE heartbeat) must
  # be evicted by a starting daemon's takeover, not deferred to
  printf '%s\n%s\n' "$$" "$((now-999))" > "$STATUSLINE_PANEL_DIR/daemon.pid"
  bash ./statusline-panel-daemon.sh &
  hb_dpid=$!
  sleep 1
  hb_owner=""
  read -r hb_owner < "$STATUSLINE_PANEL_DIR/daemon.pid" 2>/dev/null
  kill "$hb_dpid" 2>/dev/null; wait "$hb_dpid" 2>/dev/null
  rm -f "$STATUSLINE_PANEL_DIR/daemon.pid"
  [ -n "$hb_owner" ] && [ "$hb_owner" != "$$" ] && ok "stale-heartbeat claim evicted by takeover" || bad "recycled pid claim survived takeover"
  # R19: millisecond-unit resets_at must not fabricate a red pace alarm
  # or a bogus clock - the reset half-segments silently disappear
  msout=$(jq -n '{session_id:"ms1",model:{display_name:"M"},workspace:{current_dir:"/x"},rate_limits:{five_hour:{used_percentage:37.4,resets_at:1770000000000}}}' | bash ./statusline-command.sh | strip)
  printf '%s' "$msout" | grep -q '5h 37%' && ok "ms resets_at keeps percent" || bad "ms resets_at broke percent"
  printf '%s' "$msout" | grep -qE '·t|→' && bad "ms resets_at fabricated pace/clock" || ok "ms resets_at drops reset half-segments"

  # ---- adversarial-review round-4 regression asserts (2026-08-14) ----
  # R20: the daemon heartbeat must be WALL-CLOCK, not loop-iteration -
  # with a hung renderer (one iteration = the full render timeout) the
  # pid file's 2nd line still refreshes within a few seconds
  printf '{"columns":120,"tasks":[{"id":"hb1","label":"x","status":"running","tokenCount":5}]}' > "$STATUSLINE_PANEL_DIR/spool.hb1.new"
  STATUSLINE_PANEL_RENDERER="$tmpd/hangrender.sh" STATUSLINE_PANEL_RENDER_TIMEOUT=8 bash ./statusline-panel-daemon.sh &
  hb2_dpid=$!
  sleep 7
  hb_now2=$(date +%s)
  hb_line2=""
  { read -r _hbpid; read -r hb_line2; } < "$STATUSLINE_PANEL_DIR/daemon.pid" 2>/dev/null
  kill "$hb2_dpid" 2>/dev/null; wait "$hb2_dpid" 2>/dev/null
  rm -f "$STATUSLINE_PANEL_DIR/daemon.pid" "$STATUSLINE_PANEL_DIR"/spool.hb1.new "$STATUSLINE_PANEL_DIR"/render.hb1 2>/dev/null
  if [[ "$hb_line2" =~ ^[0-9]+$ ]] && [ $(( hb_now2 - hb_line2 )) -le 6 ]; then ok "heartbeat stays fresh during hung render (wall-clock)"; else bad "heartbeat starved by hung render (age=$(( hb_now2 - ${hb_line2:-0} ))s)"; fi
  # R21: giant remaining_percentage must not paint a full green battery
  # with a 24-digit percent - digit cap drops the whole segment
  bigctx=$(jq -n '{session_id:"bc1",model:{display_name:"M"},workspace:{current_dir:"/x"},context_window:{remaining_percentage:99999999999999999999999}}' | bash ./statusline-command.sh | strip)
  printf '%s' "$bigctx" | grep -q 'ctx' && bad "giant remaining rendered fake battery" || ok "giant remaining drops ctx segment"

  # ---- adversarial-review round-5 regression asserts (2026-08-14) ----
  # R22: a legacy TAB-separated history file must still be trimmed and
  # self-migrate to 0x1F (the epoch probes must accept both separators)
  for ((ti=0; ti<20; ti++)); do printf '%s\tlegacy\t%s\t0.10\n' "$((now-14400+ti*60))" "$((1000+ti))"; done > "$STATUSLINE_HISTORY_FILE"
  jq -n '{session_id:"legacy",model:{display_name:"M"},workspace:{current_dir:"/x"}}' | bash ./statusline-command.sh >/dev/null
  tabrows=$(grep -cP "	" "$STATUSLINE_HISTORY_FILE" 2>/dev/null); tabrows=${tabrows:-99}
  rowcnt=$(grep -c . "$STATUSLINE_HISTORY_FILE" 2>/dev/null); rowcnt=${rowcnt:-99}
  if [ "$tabrows" -eq 0 ] && [ "$rowcnt" -le 2 ]; then ok "legacy TAB file trimmed + migrated"; else bad "TAB file stuck (rows=$rowcnt tabs=$tabrows)"; fi
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  # R23: a giant cost must be rejected at the ONE parsing gate - it may
  # not reach the week sum (previously it skipped the display cap but
  # got folded into the rollup permanently)
  : > "$STATUSLINE_DAILY_FILE"
  bigcost=$(jq -n '{session_id:"bigc",model:{display_name:"M"},workspace:{current_dir:"/x"},cost:{total_cost_usd:123456789012}}' | bash ./statusline-command.sh | strip)
  printf '%s' "$bigcost" | grep -q 'week \$1234' && bad "giant cost folded into week" || ok "giant cost rejected at cost_to_cents"
  : > "$STATUSLINE_DAILY_FILE"
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  # R24: a stale rollup row from a long-gone session must not corrupt
  # week math (and, per round-5, must not pin the tail-scan early stop -
  # asserted here by semantics; the perf side is covered by design)
  printf '20260809\x1fsess-OLD\x1f0\x1f500\x1f500\x1f%s\n' "$((now-432000))" >> "$STATUSLINE_DAILY_FILE"
  staleout=$(bash ./statusline-command.sh < fixtures/full.json | strip)
  printf '%s' "$staleout" | grep -q 'week \$' && ok "week renders alongside stale rollup row" || bad "stale rollup row broke week"
  # ---- adversarial-review round-6 regression asserts (2026-08-14) ----
  # R25: numeric fields arriving as STRINGS with newlines must not
  # collapse the whole bar (every jq field now goes through clean)
  prnl=$(jq -n '{session_id:"pn",model:{display_name:"M"},workspace:{current_dir:"/x"},pr:{number:"4
2"}}' | bash ./statusline-command.sh | strip)
  printf '%s' "$prnl" | grep -q 'degraded' && bad "string pr.number degraded whole bar" || ok "string pr.number survives clean"
  costnl=$(jq -n '{session_id:"cn",model:{display_name:"M"},workspace:{current_dir:"/x"},cost:{total_cost_usd:"1
2"}}' | bash ./statusline-command.sh | strip)
  printf '%s' "$costnl" | grep -q 'degraded' && bad "string cost degraded whole bar" || ok "string cost survives clean"
  # R26: 17-digit token counts must not wrap int64 into a fake full
  # green battery - the segment disappears instead
  wrapctx=$(jq -n '{session_id:"wc",model:{display_name:"M"},workspace:{current_dir:"/x"},context_window:{total_input_tokens:130000000000000000,context_window_size:200000,total_output_tokens:0}}' | bash ./statusline-command.sh | strip)
  printf '%s' "$wrapctx" | grep -q 'ctx' && bad "wrapping token count rendered fake battery" || ok "over-cap token count drops ctx"
  # R27: an unrefreshable cache must stop being served past 60s
  printf '%s\n%s\n' "$((now-300))" '{"id":"old1","content":"FROZEN"}' > "$STATUSLINE_PANEL_DIR/cache.old1"
  staleserve=$(printf '{"columns":120,"tasks":[{"id":"old1","label":"x","status":"running","tokenCount":5}]}' | bash ./statusline-panel-hook.sh)
  printf '%s' "$staleserve" | grep -q FROZEN && bad "stale cache still served" || ok "stale cache refused (age gate)"
  rm -f "$STATUSLINE_PANEL_DIR"/cache.old1 "$STATUSLINE_PANEL_DIR"/spool.old1.new 2>/dev/null
  # R28: the panel caps tokenCount too (no fabricated spend)
  wrappanel=$(jq -n '{columns:150,tasks:[{id:"wp",label:"L",status:"running",tokenCount:9999999999999999999,description:"d"}]}' | bash ./subagent-statusline.sh | jq -r .content | strip)
  printf '%s' "$wrappanel" | grep -q 'tok' && bad "panel rendered wrapped spend" || ok "over-cap panel tokenCount drops spend cell"

  # ---- adversarial-review round-7 regression asserts (2026-08-14) ----
  # R29: EXIT CODE. A non-zero exit blanks the whole bar per this
  # project's own red line, and an empty 4th line used to leave the
  # last `[ -n ] && printf` short-circuit as the script's exit status.
  for _fx in fixtures/full.json fixtures/minimal.json fixtures/low-context.json; do
    bash ./statusline-command.sh < "$_fx" >/dev/null 2>&1
    [ $? -eq 0 ] || { bad "non-zero exit on $_fx"; break; }
  done
  bash ./statusline-command.sh < fixtures/minimal.json >/dev/null 2>&1 && ok "exit 0 on every fixture" || bad "non-zero exit (minimal)"
  jq -c 'del(.rate_limits)|del(.session_name)' fixtures/full.json | bash ./statusline-command.sh >/dev/null 2>&1 && ok "exit 0 with empty 4th line" || bad "non-zero exit on empty line 4"
  # R30: a container field arriving as a SCALAR/ARRAY must not abort
  # the whole jq filter into a misleading whole-bar degrade
  drift_ok=1
  for _mut in '.effort="max"' '.model="F5"' '.workspace.repo="a/b"' '.context_window.current_usage=5' '.cost=0.42' '.rate_limits=[]'; do
    jq -c "$_mut" fixtures/full.json | bash ./statusline-command.sh 2>/dev/null | strip | grep -q 'degraded' && drift_ok=0
  done
  [ "$drift_ok" -eq 1 ] && ok "scalar/array container drift never degrades the bar" || bad "container type drift degrades whole bar"
  # R31: a cost-less row must still advance its session watermark, or
  # the tail-scan early stop can never arm again
  : > "$STATUSLINE_DAILY_FILE"
  { printf "%snc1100
" "$((now-400))"
    printf "%snc1200
" "$((now-300))"; } > "$STATUSLINE_HISTORY_FILE"
  jq -n --arg s nc1 '{session_id:$s,model:{display_name:"M"},workspace:{current_dir:"/x"}}' | bash ./statusline-command.sh >/dev/null 2>&1
  # round-8: a cost-less row must now PERSIST a zero-cents watermark
  # row (memory-only advancement died with the frame, so the tail-scan
  # early stop could never arm again), while adding nothing to spend
  if grep -q 'nc1' "$STATUSLINE_DAILY_FILE" 2>/dev/null; then
    nc_line=$(grep 'nc1' "$STATUSLINE_DAILY_FILE" | head -1)
    nc_closed=$(printf '%s' "$nc_line" | cut -d$'' -f3)
    nc_peak=$(printf '%s' "$nc_line" | cut -d$'' -f4)
    nc_ep=$(printf '%s' "$nc_line" | cut -d$'' -f6)
    if [ "$nc_closed" = "0" ] && [ "$nc_peak" = "0" ] && [ "$nc_ep" != "0" ]; then
      ok "cost-less row persists a zero-cents watermark"
    else
      bad "cost-less watermark row malformed ($nc_line)"
    fi
  else
    bad "cost-less row left no watermark row (early stop stays disarmed)"
  fi
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  : > "$STATUSLINE_DAILY_FILE"
  # R32: settled days (older than yesterday) merge to one _agg row per
  # day, and the week total is preserved
  for _d in 3 4 5; do
    for _sid in a b c; do
      printf '%s%s-%s500250250%s
' "$(date -d "-$_d days" +%Y%m%d 2>/dev/null || date -v-${_d}d +%Y%m%d)" "$_sid" "$_d" "$((now-_d*86400))"
    done
  done > "$STATUSLINE_DAILY_FILE"
  printf '%smg11000.50
' "$((now-100))" > "$STATUSLINE_HISTORY_FILE"
  mgout=$(bash ./statusline-command.sh < fixtures/full.json | strip)
  # 9 settled rows x $7.50 = $67.50. The two sids that appear only in the
  # fine file (mg, and the fixture's own abc) contribute NOTHING: round-14
  # stopped seeding an unknown session at base 0 (see fold_daily_row), so
  # a session with no baseline on record owns only what it is OBSERVED to
  # spend from here on - the never-inflate direction.
  printf '%s' "$mgout" | grep -q 'week \$67\.5' && ok "settled-day merge preserves week total" || bad "settled-day merge changed week total ($(printf '%s' "$mgout" | grep -o 'week \$[0-9.]*'))"
  [ "$(grep -c '_agg' "$STATUSLINE_DAILY_FILE")" -eq 3 ] && ok "settled days merged to one row each" || bad "settled-day merge row count wrong"
  # ---- adversarial-review round-8 regression asserts (2026-08-14) ----
  # R33: .thinking as a scalar/array must not collapse the bar (the
  # `if` field must still emit exactly one line)
  think_ok=1
  for _t in '.thinking=true' '.thinking="on"' '.thinking=1' '.thinking=[]'; do
    jq -c "$_t" fixtures/full.json | bash ./statusline-command.sh 2>/dev/null | strip | grep -q 'degraded' && think_ok=0
  done
  [ "$think_ok" -eq 1 ] && ok "scalar .thinking never degrades the bar" || bad "scalar .thinking degrades whole bar"
  # R34: an all-future-stamped head must still trigger the trim rewrite
  # (probe failure used to pin "oldest = now" and disable trimming)
  : > "$STATUSLINE_DAILY_FILE"
  {
    for _i in $(seq 1 25); do printf '%sfut1000.10
' "$((now+7200+_i))"; done
    for _i in $(seq 1 30); do printf '%sabc1000.10
' "$((now-18000+_i))"; done
  } > "$STATUSLINE_HISTORY_FILE"
  bash ./statusline-command.sh < fixtures/full.json >/dev/null 2>&1
  fut_left=$(grep -c . "$STATUSLINE_HISTORY_FILE")
  [ "$fut_left" -lt 30 ] && ok "future-stamped head still triggers trim" || bad "trim disabled by future head ($fut_left rows)"
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  : > "$STATUSLINE_DAILY_FILE"
  # R35: a render child that IGNORES SIGTERM must not wedge the daemon
  printf '#!/bin/bash
trap "" TERM
sleep 60
' > "$tmpd/hangterm.sh"
  printf '{"columns":120,"tasks":[{"id":"ht1","label":"x","status":"running","tokenCount":5}]}' > "$STATUSLINE_PANEL_DIR/spool.ht1.new"
  ht_t0=$SECONDS
  STATUSLINE_PANEL_RENDERER="$tmpd/hangterm.sh" STATUSLINE_PANEL_RENDER_TIMEOUT=2 bash ./statusline-panel-daemon.sh --once
  ht_el=$(( SECONDS - ht_t0 ))
  [ "$ht_el" -lt 12 ] && ok "TERM-immune render child does not wedge daemon (${ht_el}s)" || bad "daemon wedged by TERM-immune child (${ht_el}s)"
  rm -f "$STATUSLINE_PANEL_DIR"/render.ht1 "$STATUSLINE_PANEL_DIR"/cache.ht1* 2>/dev/null
  # ---- adversarial-review round-9 regression asserts (2026-08-14) ----
  # R36: the hook must REAP a wedged daemon (alive pid, frozen
  # heartbeat) before spawning a replacement - not doing so minted a
  # new permanent process every ~65s (78 orphans / 22 CPU-hours found
  # on the real machine)
  sleep 300 &
  fake_wedged=$!
  printf '%s\n%s\n' "$fake_wedged" "$((now-600))" > "$STATUSLINE_PANEL_DIR/daemon.pid"
  printf '{"columns":120,"tasks":[{"id":"rp1","label":"x","status":"running","tokenCount":5}]}' | STATUSLINE_PANEL_DAEMON=/dev/null bash ./statusline-panel-hook.sh >/dev/null 2>&1
  sleep 0.5
  if kill -0 "$fake_wedged" 2>/dev/null; then
    ok "hook spares a non-daemon pid (recycled-pid safety)"
    kill "$fake_wedged" 2>/dev/null
  else
    bad "hook killed an unrelated process"
  fi
  rm -f "$STATUSLINE_PANEL_DIR/daemon.pid" "$STATUSLINE_PANEL_DIR"/spool.rp1.new 2>/dev/null
  # R37: hb_beat must not freeze on a backwards clock step (negative
  # delta is also "< 5", which froze the beat for the whole rollback)
  grep -q 'hb_delta' ./statusline-panel-daemon.sh && ok "hb_beat has a negative-delta guard" || bad "hb_beat missing clock-rollback guard"
  # R38: the daemon must carry an absolute lifetime cap so a wedge
  # anywhere outside the beat checkpoints still terminates
  grep -q 'daemon_max_life' ./statusline-panel-daemon.sh && ok "daemon has an absolute lifetime cap" || bad "daemon lifetime cap missing"
  # R39: the installer must reclaim EVERY daemon instance, not just a
  # freshly-registered one
  grep -q 'old_wp' ./install.sh && ok "installer reclaims via registered pid (no fuzzy match)" || bad "installer reclaim missing winpid path"
  # ---- adversarial-review round-10 regression asserts (2026-08-14) ----
  # R40: the hook must actually KILL a wedged daemon (round-9's assert
  # only ever exercised the DON'T-kill side, so deleting the whole fix
  # still passed)
  cp ./statusline-panel-daemon.sh "$tmpd/statusline-panel-daemon.sh"
  printf '#!/bin/bash
sleep 120
' > "$tmpd/statusline-panel-daemon.sh"
  bash "$tmpd/statusline-panel-daemon.sh" &
  wedged=$!
  printf '%s
%s
%s
' "$wedged" "$((now-600))" "0" > "$STATUSLINE_PANEL_DIR/daemon.pid"
  printf '{"columns":120,"tasks":[{"id":"kl1","label":"x","status":"running","tokenCount":5}]}' | STATUSLINE_PANEL_DAEMON=/dev/null bash ./statusline-panel-hook.sh >/dev/null 2>&1
  sleep 1
  if kill -0 "$wedged" 2>/dev/null; then
    bad "hook did NOT reap the wedged daemon"
    kill -9 "$wedged" 2>/dev/null
  else
    ok "hook reaps a wedged daemon (kill side covered)"
  fi
  rm -f "$STATUSLINE_PANEL_DIR/daemon.pid" "$STATUSLINE_PANEL_DIR"/spool.kl1.new 2>/dev/null
  # R41: the daily row cap must never lose money - overflow merges
  # settled per-session rows into _agg instead of slicing in hash order
  : > "$STATUSLINE_DAILY_FILE"
  {
    for _i in $(seq 1 450); do printf '%ss%03d1005050%s
' "$(date +%Y%m%d)" "$_i" "$((now-20000))"; done
  } > "$STATUSLINE_DAILY_FILE"
  printf '%scapx1000.50
' "$((now-100))" > "$STATUSLINE_HISTORY_FILE"
  cap1=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'today \$[0-9.]*' | head -1)
  cap2=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'today \$[0-9.]*' | head -1)
  # allow a small forward drift (the fixture's own live cost accrues
  # between the two frames); a REGRESSION here loses hundreds of dollars
  cap_d=$(awk -v a="${cap1#today $}" -v b="${cap2#today $}" 'BEGIN{d=b-a; if(d<0)d=-d; printf "%d", d}' 2>/dev/null)
  [ -n "$cap1" ] && [ "${cap_d:-999}" -le 5 ] && ok "daily cap keeps today stable ($cap1)" || bad "daily cap lost money ($cap1 -> $cap2)"
  : > "$STATUSLINE_DAILY_FILE"
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  # R42: the watchdog must not match shells that merely MENTION the
  # daemon filename (the 2026-08-13 mis-kill class)
  grep -q 'CommandLine -match' ./statusline-watchdog.ps1 && ok "watchdog uses an argv-position match" || bad "watchdog still uses a mention match"
  grep -q 'ProcessId=' ./statusline-watchdog.ps1 && ok "watchdog targets the registered Windows pid" || bad "watchdog does not use the registered winpid"
  # ---- adversarial-review round-11 regression asserts (2026-08-15) ----
  # R43: the hook must stay fast when the first task has no string id -
  # the old shortest-prefix strip was QUADRATIC (13.8s measured on an
  # 80KB payload, i.e. the panel froze on default rows)
  python - <<'PY' > "$tmpd/bigpayload.json" 2>/dev/null || jq -n '{columns:120,tasks:[{id:123,tokenCount:5},{id:"t2",tokenCount:6}]}' > "$tmpd/bigpayload.json"
import json
samples=[{"tokens":i*10} for i in range(2500)]
print(json.dumps({"columns":120,"tasks":[{"id":123,"label":"a","status":"running","tokenCount":5,"tokenSamples":samples},{"id":"t2","label":"b","status":"running","tokenCount":6}]}))
PY
  hk_t0=$EPOCHREALTIME
  STATUSLINE_PANEL_DAEMON=/dev/null bash ./statusline-panel-hook.sh < "$tmpd/bigpayload.json" >/dev/null 2>&1
  hk_t1=$EPOCHREALTIME
  awk -v a="$hk_t0" -v b="$hk_t1" 'BEGIN{exit (b-a < 3.0) ? 0 : 1}' && ok "hook key extraction stays bounded on a late id" || bad "hook key extraction is quadratic again"
  rm -f "$STATUSLINE_PANEL_DIR"/spool.t2.new 2>/dev/null
  # R44: the daily overflow merge must be idempotent - an existing _agg
  # row for the same day must be folded IN, never duplicated (a second
  # row with the same key silently overwrote the first on reload)
  : > "$STATUSLINE_DAILY_FILE"
  ag_today=$(date +%Y%m%d)
  {
    printf '%s_agg50000000
' "$ag_today"
    for _i in $(seq 1 401); do printf '%ss%03d0100100%s
' "$ag_today" "$_i" "$((now-11000))"; done
  } > "$STATUSLINE_DAILY_FILE"
  printf '%sagx1000.05
' "$((now-10))" > "$STATUSLINE_HISTORY_FILE"
  ag1=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'week \$[0-9.]*' | head -1)
  ag2=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'week \$[0-9.]*' | head -1)
  ag_d=$(awk -v a="${ag1#week $}" -v b="${ag2#week $}" 'BEGIN{d=b-a; if(d<0)d=-d; printf "%d", d}' 2>/dev/null)
  [ -n "$ag1" ] && [ "${ag_d:-999}" -le 5 ] && ok "overflow merge is idempotent ($ag1)" || bad "overflow merge lost money ($ag1 -> $ag2)"
  [ "$(grep -c '_agg' "$STATUSLINE_DAILY_FILE")" -eq 1 ] && ok "one _agg row per day after overflow" || bad "duplicate _agg rows written"
  : > "$STATUSLINE_DAILY_FILE"
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  # R45: install must confirm process identity before signalling (a
  # recycled pid in a stale pid file otherwise gets TERM+KILL)
  grep -q 'old_cmd' ./install.sh && ok "installer confirms daemon identity before kill" || bad "installer still kills by bare pid"
  # ---- panel state-coloring (user request, 2026-08-15) ----
  # R46: the identity is no longer a flat magenta - each state gets its
  # own hue so one glance down the left edge reads the whole fleet
  colorrows=$(jq -n --argjson n "$(date +%s)" '{columns:170,tasks:[
    {id:"cr1",name:"runner",status:"running",tokenCount:5000,startTime:(($n-2400)*1000),description:"d"},
    {id:"cr2",name:"doner",status:"completed",tokenCount:5000,startTime:(($n-700)*1000),description:"d"},
    {id:"cr3",name:"failer",status:"failed",tokenCount:5000,startTime:(($n-90)*1000),description:"d"},
    {id:"cr4",name:"waiter",status:"pending",tokenCount:5000,startTime:(($n-30)*1000),description:"d"},
    {id:"cr5",name:"weirdo",status:"zzz",tokenCount:5000,startTime:(($n-1200)*1000),description:"d"}]}' | bash ./subagent-statusline.sh | jq -r .content)
  # compare on an ESC-transliterated copy: $'[' inside a quoted
  # grep pattern is brittle, and the raw ESC byte cannot be typed here
  colorcodes=$(printf '%s' "$colorrows" | sed 's/\[/CODE/g')
  col_ok=1
  for _pair in '32m:doner' '91m:failer' '33m:waiter'; do
    _c=${_pair%%:*}; _n=${_pair#*:}
    printf '%s' "$colorcodes" | grep -q "CODE${_c}${_n}" || col_ok=0
  done
  [ "$col_ok" -eq 1 ] && ok "terminal/waiting states keep semantic colors" || bad "state coloring wrong"
  # running agents must NOT all share one hue: five ids must produce at
  # least three distinct color codes (the panel used to be one solid
  # block of magenta because running is the overwhelmingly common state)
  cat > "$tmpd/runhues.json" <<RHJSON
{"columns":180,"tasks":[
  {"id":"a1x","name":"ra","status":"running","tokenCount":5000,"description":"d"},
  {"id":"b2y","name":"rb","status":"running","tokenCount":5000,"description":"d"},
  {"id":"c3z","name":"rc","status":"running","tokenCount":5000,"description":"d"},
  {"id":"d4w","name":"rd","status":"running","tokenCount":5000,"description":"d"},
  {"id":"e5v","name":"re","status":"running","tokenCount":5000,"description":"d"}]}
RHJSON
  runrows=$(bash ./subagent-statusline.sh < "$tmpd/runhues.json" | jq -r .content)
  hues=$(printf '%s' "$runrows" | sed 's/\[/CODE/g' | grep -o 'CODE[0-9]*mr[a-e]' | sed 's/mr[a-e]$//' | sort -u | wc -l)
  [ "${hues:-0}" -ge 3 ] && ok "running agents get distinct per-agent hues ($hues)" || bad "running agents share one hue ($hues)"
  # R47: elapsed is duration-tiered (the 40min row bright red, the 30s
  # row gray) instead of flat white
  # elapsed tier: rebuild with a live clock (the suite takes minutes,
  # so a fixture stamped at suite start drifts across tier boundaries)
  cat > "$tmpd/eltier.json" <<ELJSON
{"columns":180,"tasks":[
  {"id":"el1","name":"elong","status":"running","tokenCount":5000,"startTime":$(( ($(date +%s) - 2400) * 1000 )),"description":"d"},
  {"id":"el2","name":"eshort","status":"running","tokenCount":5000,"startTime":$(( ($(date +%s) - 30) * 1000 )),"description":"d"}]}
ELJSON
  elrows=$(bash ./subagent-statusline.sh < "$tmpd/eltier.json" | jq -r .content | sed 's/\[/CODE/g')
  el_ok=1
  printf '%s' "$elrows" | grep -q 'CODE91m40m' || el_ok=0
  # RANGE, not an exact second (round-13): the fixture is stamped with a
  # live clock and the render (bash+jq) takes 0.15-0.45s, so ~40% of runs
  # crossed into 31s and failed an assertion about COLOR, not arithmetic
  printf '%s' "$elrows" | grep -qE 'CODE90m3[0-9]s' || el_ok=0
  [ "$el_ok" -eq 1 ] && ok "elapsed color follows duration tier" || bad "elapsed tiering wrong"
  # ---- adversarial-review round-13 regression asserts (2026-08-15) ----
  S13=''
  # R48: a settled day folds into _agg NET of its midnight baseline. The
  # base column only lived in per-session rows, so the day that carried
  # it resurrected round-12's cross-midnight double count the moment it
  # settled - two days late, and permanently (the fine rows are gone).
  : > "$STATUSLINE_DAILY_FILE"
  d3=$(date -d "-3 days" +%Y%m%d 2>/dev/null || date -v-3d +%Y%m%d)
  printf '%s%sbs1%s0%s1000%s1000%s%s%s600
' "$d3" "$S13" "$S13" "$S13" "$S13" "$S13" "$((now-259200))" "$S13" > "$STATUSLINE_DAILY_FILE"
  printf '%s%sbsx%s1000%s0.50
' "$((now-100))" "$S13" "$S13" "$S13" > "$STATUSLINE_HISTORY_FILE"
  b1=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'week \$[0-9.]*' | head -1)
  b_agg=$(grep '_agg' "$STATUSLINE_DAILY_FILE" | head -1 | cut -d"$S13" -f3)
  b2=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'week \$[0-9.]*' | head -1)
  b_d=$(awk -v a="${b1#week $}" -v b="${b2#week $}" 'BEGIN{d=b-a; if(d<0)d=-d; printf "%d", d}' 2>/dev/null)
  [ "${b_agg:-0}" = "400" ] && ok "settled _agg row is net of the midnight baseline" || bad "settled _agg row kept the baseline (${b_agg:-none} != 400)"
  [ -n "$b1" ] && [ "${b_d:-999}" -le 5 ] && ok "week survives the settle fold ($b1)" || bad "week jumped when the day settled ($b1 -> $b2)"
  # R48b: _agg rows are written with all 7 columns (a 6-column _agg row
  # made the overflow merge below read a cents value as an epoch)
  [ "$(grep '_agg' "$STATUSLINE_DAILY_FILE" | head -1 | tr -cd "$S13" | wc -c)" -eq 6 ] && ok "_agg row carries all 7 columns" || bad "_agg row column count wrong"
  # R49: the overflow merge must read last_epoch POSITIONALLY. Taking the
  # LAST field got the base column instead, so "older than 3h" was true
  # for every row and the live session's state row was merged away - its
  # watermark zeroed, its fine rows re-folded from scratch, today/week
  # inflating permanently.
  : > "$STATUSLINE_DAILY_FILE"
  {
    for _i in $(seq 1 401); do printf '%s%sv%03d%s0%s100%s100%s%s%s50
' "$(date +%Y%m%d)" "$S13" "$_i" "$S13" "$S13" "$S13" "$S13" "$((now-600))" "$S13"; done
  } > "$STATUSLINE_DAILY_FILE"
  printf '%s%sovx%s1000%s0.50
' "$((now-100))" "$S13" "$S13" "$S13" > "$STATUSLINE_HISTORY_FILE"
  o1=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'today \$[0-9.]*' | head -1)
  o_rows=$(grep -c . "$STATUSLINE_DAILY_FILE")
  o_agg=$(grep -c '_agg' "$STATUSLINE_DAILY_FILE")
  o2=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'today \$[0-9.]*' | head -1)
  o_d=$(awk -v a="${o1#today $}" -v b="${o2#today $}" 'BEGIN{d=b-a; if(d<0)d=-d; printf "%d", d}' 2>/dev/null)
  [ "$o_agg" -eq 0 ] && [ "$o_rows" -ge 400 ] && ok "overflow merge spares rows inside the 3h window ($o_rows rows)" || bad "overflow merge collapsed live rows ($o_rows rows, $o_agg agg)"
  [ -n "$o1" ] && [ "${o_d:-999}" -le 5 ] && ok "overflow merge keeps today stable ($o1)" || bad "overflow merge inflated today ($o1 -> $o2)"
  # R50: the today segment is hidden only when it would RESTATE the cost
  # segment. That test compared today (net of the baseline since round-12)
  # against the session's raw cumulative, so any session with spend before
  # midnight lost the segment for the whole rest of the day.
  : > "$STATUSLINE_DAILY_FILE"
  ymd1=$(date -d "-1 days" +%Y%m%d 2>/dev/null || date -v-1d +%Y%m%d)
  {
    printf '%s%sabc%s0%s3000%s3000%s%s%s0
' "$ymd1" "$S13" "$S13" "$S13" "$S13" "$S13" "$((now-86400))" "$S13"
    printf '%s%sS2%s0%s100%s100%s%s%s0
' "$(date +%Y%m%d)" "$S13" "$S13" "$S13" "$S13" "$S13" "$((now-400))" "$S13"
  } > "$STATUSLINE_DAILY_FILE"
  printf '%s%sabc%s5000%s32.00
' "$((now-40))" "$S13" "$S13" "$S13" > "$STATUSLINE_HISTORY_FILE"
  mn_out=$(jq '.cost.total_cost_usd=32.00' fixtures/full.json | bash ./statusline-command.sh | strip)
  printf '%s' "$mn_out" | grep -q 'today \$3\.' && ok "cross-midnight session still shows today" || bad "today segment vanished for a cross-midnight session"
  # ---- adversarial-review round-15 regression asserts (2026-08-15) ----
  S15=''
  # R60: an over-long rollup row must be DROPPED WHOLE. The "no separator
  # left in the last field" guard was still aimed at last_epoch, which a
  # %% strip can never leave one in - dead code since the base column was
  # appended. An 8-column row therefore survived with its base silently
  # read as 0, i.e. that day lost its midnight baseline and counted
  # closed+peak in full (the forbidden direction), while the fine file
  # drops an over-long row exactly as it should.
  : > "$STATUSLINE_DAILY_FILE"
  printf '%s%sh1%s500%s200%s200%s%s%s300
' "$(date +%Y%m%d)" "$S15" "$S15" "$S15" "$S15" "$S15" "$((now-4000))" "$S15" > "$STATUSLINE_DAILY_FILE"
  printf '%s%szz9%s100%s1.00
' "$((now-100))" "$S15" "$S15" "$S15" > "$STATUSLINE_HISTORY_FILE"
  ov_ok=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'week \$[0-9]*' | head -1)
  : > "$STATUSLINE_DAILY_FILE"
  printf '%s%sh1%s500%s200%s200%s%s%s300%sJUNK
' "$(date +%Y%m%d)" "$S15" "$S15" "$S15" "$S15" "$S15" "$((now-4000))" "$S15" "$S15" > "$STATUSLINE_DAILY_FILE"
  printf '%s%szz9%s100%s1.00
' "$((now-100))" "$S15" "$S15" "$S15" > "$STATUSLINE_HISTORY_FILE"
  ov_bad=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'week \$[0-9]*' | head -1)
  [ "$ov_ok" = 'week $4' ] && ok "7-column rollup row keeps its baseline ($ov_ok)" || bad "7-column row mis-parsed ($ov_ok, want week \$4)"
  [ "$ov_bad" != 'week $7' ] && ok "over-long rollup row is dropped whole ($ov_bad)" || bad "over-long row survived with base swallowed ($ov_bad)"
  # R61: dead per-session rows must collapse on every persist, not only
  # past a 400-row cap - every frame re-splits and re-validates the whole
  # file, so a machine that mints a session id per start paid a per-frame
  # tax that grew with lifetime session count (+169ms measured at 200)
  : > "$STATUSLINE_DAILY_FILE"
  {
    for _i in $(seq 1 60); do printf '%s%sdead%02d%s0%s100%s100%s%s%s0
' "$(date +%Y%m%d)" "$S15" "$_i" "$S15" "$S15" "$S15" "$S15" "$((now-20000))" "$S15"; done
  } > "$STATUSLINE_DAILY_FILE"
  printf '%s%szz9%s100%s1.00
' "$((now-100))" "$S15" "$S15" "$S15" > "$STATUSLINE_HISTORY_FILE"
  dw1=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'week \$[0-9.]*' | head -1)
  dead_rows=$(grep -c . "$STATUSLINE_DAILY_FILE")
  dw2=$(bash ./statusline-command.sh < fixtures/full.json | strip | grep -o 'week \$[0-9.]*' | head -1)
  dd=$(awk -v a="${dw1#week $}" -v b="${dw2#week $}" 'BEGIN{d=b-a; if(d<0)d=-d; printf "%d", d}' 2>/dev/null)
  [ "$dead_rows" -lt 10 ] && ok "terminal rows collapse without a 400-row cap ($dead_rows rows)" || bad "terminal rows still waiting for the cap ($dead_rows rows)"
  [ -n "$dw1" ] && [ "${dd:-999}" -le 5 ] && ok "collapsing terminal rows loses no money ($dw1)" || bad "collapse changed the total ($dw1 -> $dw2)"
  # R62: "today and yesterday stay per-session" - 48h resolved to the day
  # BEFORE yesterday, keeping a third day of rows nothing can ever fold
  grep -q '172800 ))"' ./statusline-command.sh && bad "settled-day threshold still keeps three days" || ok "settled-day threshold matches the documented two days"
  : > "$STATUSLINE_DAILY_FILE"
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  # R63: bash 4.0-4.2 has no `local -n`; the renderer's four lines come
  # back EMPTY there and the old "output is non-empty" smoke test still
  # reported success, because pure escape codes are non-empty
  grep -q 'BASH_VERSINFO\[1\]' ./install.sh && ok "installer gates on bash 4.3, not 4" || bad "installer still accepts bash 4.0-4.2"
  grep -q '剥色后为空' ./install.sh && ok "smoke test requires visible content, not just bytes" || bad "smoke test still passes on escape-only output"
  # R58: the installer's Windows-side reclaim must use the SAME strict
  # judgement as the watchdog. A bare "the command line mentions the
  # filename" match, aimed at a winpid that Windows has since recycled,
  # is precisely the 2026-08-13/14 mis-kill shape - and this branch is
  # the one that actually calls Stop-Process -Force.
  if grep -q 'CommandLine -notmatch' ./install.sh && grep -qF 'statusline-panel-daemon\.sh' ./install.sh; then
    ok "installer's Windows-side reclaim uses the strict argv judgement"
  else
    bad "installer still reclaims by a bare filename mention"
  fi
  grep -q 'ps_killed' ./install.sh && ok "installer reports a reclaim only when one happened" || bad "installer reports a reclaim unconditionally"
  # R59: startTime needs a sanity WINDOW, not just a digit cap - 0 used to
  # render "496318h25m16s@08:00:00", a 1970 wall clock in the bright-red
  # long-runner tier (the main bar has had this guard since round-6)
  zt14=$(jq -nc '{columns:120,tasks:[{id:"zt1",label:"zero",status:"running",tokenCount:0,startTime:0,description:"y"}]}' | bash ./subagent-statusline.sh | jq -r .content)
  printf '%s' "$zt14" | grep -qE '[0-9]+h[0-9]+m[0-9]+s' && bad "panel renders a 1970 clock for startTime=0" || ok "out-of-window startTime drops the elapsed cell"
  zt14b=$(jq -nc --argjson n "$(date +%s)" '{columns:120,tasks:[{id:"zt2",label:"okk",status:"running",tokenCount:0,startTime:(($n-45)*1000),description:"y"}]}' | bash ./subagent-statusline.sh | jq -r .content | strip)
  printf '%s' "$zt14b" | grep -qE '4[0-9]s@' && ok "in-window startTime still renders elapsed" || bad "sane startTime lost its elapsed cell"
  : > "$STATUSLINE_DAILY_FILE"
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  # R51: a wedged daemon's IN-FLIGHT RENDER CHILD must be reaped. Round-12
  # aimed a process-group kill at the daemon, but the daemon is spawned as
  # `( bash ... & )` with no job control - it is not a group leader, the
  # signal hit nothing (ESRCH), and the child was orphaned exactly as
  # before. It is reachable only because the daemon now publishes it on
  # line 4 of the pid file.
  rc_dir="$tmpd/reap13"
  mkdir -p "$rc_dir/bin"
  printf '#!/bin/bash
sleep 300
' > "$rc_dir/bin/subagent-statusline.sh"
  ( STATUSLINE_PANEL_DIR="$rc_dir" STATUSLINE_PANEL_RENDERER="$rc_dir/bin/subagent-statusline.sh" STATUSLINE_PANEL_RENDER_TIMEOUT=600 bash ./statusline-panel-daemon.sh </dev/null >/dev/null 2>&1 & )
  sleep 1
  printf '{"columns":120,"tasks":[{"id":"rk1","status":"running","tokenCount":5}]}' > "$rc_dir/spool.rk1.new"
  rc_child=""
  for _i in $(seq 1 30); do
    sleep 0.5
    rc_child=$(sed -n '4p' "$rc_dir/daemon.pid" 2>/dev/null)
    [ -n "$rc_child" ] && break
  done
  rc_daemon=$(sed -n '1p' "$rc_dir/daemon.pid" 2>/dev/null)
  if [ -n "$rc_child" ] && kill -0 "$rc_child" 2>/dev/null; then
    ok "daemon publishes its in-flight render child (pid $rc_child)"
  else
    bad "daemon did not publish its render child on line 4"
  fi
  kill -STOP "$rc_daemon" 2>/dev/null
  printf '%s
%s
%s
%s
' "$rc_daemon" "$((now-600))" "0" "$rc_child" > "$rc_dir/daemon.pid"
  printf '{"columns":120,"tasks":[{"id":"rk1","status":"running","tokenCount":5}]}' | STATUSLINE_PANEL_DIR="$rc_dir" STATUSLINE_PANEL_DAEMON=/dev/null bash ./statusline-panel-hook.sh >/dev/null 2>&1
  sleep 1
  kill -CONT "$rc_daemon" 2>/dev/null
  sleep 0.3
  if [ -n "$rc_child" ] && kill -0 "$rc_child" 2>/dev/null; then
    bad "hook orphaned the wedged daemon's render child"
  else
    ok "hook reaps the wedged daemon's render child"
  fi
  kill -9 "$rc_child" 2>/dev/null
  kill -9 "$rc_daemon" 2>/dev/null
  rm -rf "$rc_dir" 2>/dev/null
  # R52: the daemon kill itself must stay a PID kill - a group kill on a
  # recycled pid would take an unrelated live group down (the 2026-08-13/14
  # mis-kill shape), and it never reached the child anyway
  grep -vE '^[[:space:]]*#' ./statusline-panel-hook.sh | grep -qF 'kill -- "-$daemon_pid"' && bad "hook still group-kills a non-leader daemon" || ok "hook kills the daemon by pid, the child by group"
  grep -q 'old_rp' ./install.sh && ok "installer reaps the in-flight render child too" || bad "installer leaves the render child orphaned"
  # ---- round-13 LIVE-INCIDENT asserts (2026-08-15, dev machine) ----
  # R53: identity confirmation must never FORK. The reap path exists for
  # exactly one scenario - fork exhaustion - and it confirmed identity
  # with `$(tr ... < /proc/<pid>/cmdline)`, a command substitution: under
  # fork pressure the capture came back empty, the pattern never matched,
  # nothing was killed, and the hook spawned a replacement anyway. That
  # is the 78-orphan amplifier restored by its own fix; 38 orphan daemons
  # burning 3.03 CPU-hours were measured before it was found.
  if grep -n 'cmdline' ./statusline-panel-hook.sh ./install.sh | grep -vE '^[^:]+:[0-9]+: *#' | grep -q '\$('; then
    bad "identity confirmation still forks (command substitution on cmdline)"
  else
    ok "identity confirmation reads cmdline with zero forks"
  fi
  # and it must exclude a -c shell by the ARGUMENT, not by where the
  # filename lands: the old space-joined capture made
  # `bash -c '... # statusline-panel-daemon.sh'` match the tail pattern
  grep -q '"$_ai_arg" = "-c"' ./statusline-panel-hook.sh && ok "identity read excludes -c mention shells" || bad "identity read can match a -c mention shell"
  # R54: unregistered wedged daemons have NO other reaper - the hook only
  # knows the registered pid, install only reclaims that one, and the
  # absolute lifetime cap needs the loop to still be cycling
  if grep -q 'orphanCutoff' ./statusline-watchdog.ps1 && grep -q 'ProcessId -ne $regWpid' ./statusline-watchdog.ps1; then
    ok "watchdog backstops unregistered orphan daemons"
  else
    bad "watchdog has no orphan-daemon backstop"
  fi
  # R55: PowerShell 5.1 decodes a BOM-less .ps1 with the system ANSI code
  # page - the same trap that broke the .vbs under GBK
  [ "$(head -c 3 ./statusline-watchdog.ps1 | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] && ok "watchdog ps1 carries a UTF-8 BOM" || bad "watchdog ps1 has no BOM (PS 5.1 decodes it as ANSI)"
  # ---- adversarial-review round-14 regression asserts (2026-08-15) ----
  S14=''
  # R56: a COST-LESS first row must not destroy the day's midnight
  # baseline. mark_daily_seen creates the key with prev="0", which sent
  # the first real cost row down the monotonic branch - and the baseline
  # used to be seeded only in the other one, so it stayed 0 forever and
  # the cross-midnight double count came straight back ($5.10 -> $10.10).
  : > "$STATUSLINE_DAILY_FILE"
  ymd14=$(date -d "-1 days" +%Y%m%d 2>/dev/null || date -v-1d +%Y%m%d)
  printf '%s%sS1%s0%s500%s500%s%s%s0
' "$ymd14" "$S14" "$S14" "$S14" "$S14" "$S14" "$((now-86400))" "$S14" > "$STATUSLINE_DAILY_FILE"
  {
    printf '%s%sS1%s1000%s
' "$((now-70))" "$S14" "$S14" "$S14"
    printf '%s%sS1%s1000%s5.10
' "$((now-35))" "$S14" "$S14" "$S14"
  } > "$STATUSLINE_HISTORY_FILE"
  mn14=$(jq '.session_id="S1"|.cost.total_cost_usd=5.10' fixtures/full.json | bash ./statusline-command.sh | strip)
  printf '%s' "$mn14" | grep -q 'week \$5\.1' && ok "cost-less row keeps the midnight baseline" || bad "cost-less row zeroed the baseline ($(printf '%s' "$mn14" | grep -o 'week \$[0-9.]*'))"
  b14=$(grep "$(date +%Y%m%d)" "$STATUSLINE_DAILY_FILE" | head -1 | cut -d"$S14" -f7)
  [ "${b14:-0}" = "500" ] && ok "baseline column seeded despite the cost-less row" || bad "baseline column is ${b14:-none}, want 500"
  # R57: a session whose per-session row was folded into _agg comes back
  # with NO baseline on record - seeding it at 0 booked its whole
  # inherited cumulative as today's spend while that money already sat
  # inside _agg (today and week double-counted).
  : > "$STATUSLINE_DAILY_FILE"
  d14=$(date -d "-3 days" +%Y%m%d 2>/dev/null || date -v-3d +%Y%m%d)
  {
    printf '%s%s_agg%s500%s0%s0%s0%s0
' "$d14" "$S14" "$S14" "$S14" "$S14" "$S14" "$S14"
    printf '%s%sother%s0%s10%s10%s%s%s0
' "$(date +%Y%m%d)" "$S14" "$S14" "$S14" "$S14" "$S14" "$((now-60))" "$S14"
  } > "$STATUSLINE_DAILY_FILE"
  : > "$STATUSLINE_HISTORY_FILE"
  ag14=$(jq '.session_id="S1"|.cost.total_cost_usd=6.00' fixtures/full.json | bash ./statusline-command.sh | strip)
  if printf '%s' "$ag14" | grep -q 'week \$5\.1'; then
    ok "returning session is not re-seeded at base 0"
  else
    bad "returning session re-counted its inherited cumulative ($(printf '%s' "$ag14" | grep -o 'week \$[0-9.]*'))"
  fi
  : > "$STATUSLINE_DAILY_FILE"
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  : > "$STATUSLINE_DAILY_FILE"
  make_history "$now" "$STATUSLINE_HISTORY_FILE"
  : > "$STATUSLINE_DAILY_FILE"

  # panel daemon architecture: the hook must spool the payload, stay
  # silent on a cold cache, serve the cached frame instantly, and the
  # daemon (--once) must render a spool into that cache
  hookout=$(subagent_payload "$now" | bash ./statusline-panel-hook.sh)
  [ -f "$STATUSLINE_PANEL_DIR/spool.ms.new" ] && ok "panel hook spools payload" || bad "hook spool missing"
  [ -n "$hookout" ] && bad "hook emitted on cold cache" || ok "hook silent on cold cache"
  # cache format (round-6): line 1 = render epoch, rows follow
  printf '%s\n%s\n' "$(date +%s)" '{"id":"ms","content":"CACHED_MARKER"}' > "$STATUSLINE_PANEL_DIR/cache.ms"
  subagent_payload "$now" | bash ./statusline-panel-hook.sh | grep -q CACHED_MARKER && ok "panel hook serves cache" || bad "hook cache serve failed"
  bash ./statusline-panel-daemon.sh --once
  grep -q '"id":"ms"' "$STATUSLINE_PANEL_DIR/cache.ms" && ! grep -q CACHED_MARKER "$STATUSLINE_PANEL_DIR/cache.ms" && ok "panel daemon renders spool to cache" || bad "daemon render failed"

  # one-line installer: local mode into an isolated HOME must install all
  # files, deep-merge settings WITHOUT clobbering foreign keys, and be
  # idempotent on a second run
  ihome=$(mktemp -d)
  mkdir -p "$ihome/.claude"
  printf '%s\n' '{"model":"keep-me","statusLine":{"padding":0}}' > "$ihome/.claude/settings.json"
  HOME="$ihome" bash ./install.sh >/dev/null 2>&1 && ok "installer runs clean" || bad "installer failed"
  [ -x "$ihome/.claude/statusline-panel-daemon.sh" ] && [ -f "$ihome/.claude/statusline-command.sh" ] && [ -d "$ihome/.claude/statusline-panel.d" ] && ok "installer places files" || bad "installer files missing"
  [ "$(jq -r '.model' "$ihome/.claude/settings.json")" = "keep-me" ] && [ "$(jq -r '.statusLine.padding' "$ihome/.claude/settings.json")" = "0" ] && jq -r '.subagentStatusLine.command' "$ihome/.claude/settings.json" | grep -q panel-hook && ok "installer merges settings" || bad "installer merge wrong"
  HOME="$ihome" bash ./install.sh >/dev/null 2>&1 && ok "installer idempotent rerun" || bad "installer rerun failed"
  rm -rf "$ihome"

  rm -rf "$tmpd"
  echo "----"
  [ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILURE(S)"
  exit "$fails"
fi

# ---------- demo mode ----------
for f in fixtures/full.json fixtures/low-context.json fixtures/minimal.json; do
  echo "=== $f ==="
  bash ./statusline-command.sh < "$f" | filter "$1"
done

echo "=== subagent panel rows ==="
now=$(date +%s)
subagent_payload "$now" | bash ./subagent-statusline.sh \
  | while IFS= read -r l; do printf '%s' "$l" | jq -r .content; done | filter "$1"

echo "=== branch demo: clean vs dirty ==="
tmp=$(mktemp -d)
git -C "$tmp" init -q -b main 2>/dev/null || git -C "$tmp" init -q
tmp_json=$(jq --arg d "$tmp" '.workspace.current_dir=$d' fixtures/full.json)
printf '%s' "$tmp_json" | bash ./statusline-command.sh | filter "$1" | head -1
echo wip > "$tmp/wip.txt"
printf '%s' "$tmp_json" | bash ./statusline-command.sh | filter "$1" | head -1
rm -rf "$tmp"
