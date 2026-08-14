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
  [ "$(grep -c . "$STATUSLINE_HISTORY_FILE")" -ge 2 ] && ok "future-epoch row does not freeze sampling" || bad "clock rollback froze sampling"
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
  printf '%s
%s
' "$now" '{"id":"tmo2","content":"GOOD_FRAME"}' > "$STATUSLINE_PANEL_DIR/cache.tmo2"
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
  printf '%s
%s
' "$now" '{"id":"st1","content":"STALE_FRAME"}' > "$STATUSLINE_PANEL_DIR/cache.st1"
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
  printf '%s
%s
' "$((now-300))" '{"id":"old1","content":"FROZEN"}' > "$STATUSLINE_PANEL_DIR/cache.old1"
  staleserve=$(printf '{"columns":120,"tasks":[{"id":"old1","label":"x","status":"running","tokenCount":5}]}' | bash ./statusline-panel-hook.sh)
  printf '%s' "$staleserve" | grep -q FROZEN && bad "stale cache still served" || ok "stale cache refused (age gate)"
  rm -f "$STATUSLINE_PANEL_DIR"/cache.old1 "$STATUSLINE_PANEL_DIR"/spool.old1.new 2>/dev/null
  # R28: the panel caps tokenCount too (no fabricated spend)
  wrappanel=$(jq -n '{columns:150,tasks:[{id:"wp",label:"L",status:"running",tokenCount:9999999999999999999,description:"d"}]}' | bash ./subagent-statusline.sh | jq -r .content | strip)
  printf '%s' "$wrappanel" | grep -q 'tok' && bad "panel rendered wrapped spend" || ok "over-cap panel tokenCount drops spend cell"
  : > "$STATUSLINE_DAILY_FILE"

  # panel daemon architecture: the hook must spool the payload, stay
  # silent on a cold cache, serve the cached frame instantly, and the
  # daemon (--once) must render a spool into that cache
  hookout=$(subagent_payload "$now" | bash ./statusline-panel-hook.sh)
  [ -f "$STATUSLINE_PANEL_DIR/spool.ms.new" ] && ok "panel hook spools payload" || bad "hook spool missing"
  [ -n "$hookout" ] && bad "hook emitted on cold cache" || ok "hook silent on cold cache"
  # cache format (round-6): line 1 = render epoch, rows follow
  printf '%s
%s
' "$now" '{"id":"ms","content":"CACHED_MARKER"}' > "$STATUSLINE_PANEL_DIR/cache.ms"
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
