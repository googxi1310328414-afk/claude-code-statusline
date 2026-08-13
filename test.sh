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
export STATUSLINE_DAILY_FILE="$(dirname "$STATUSLINE_HISTORY_FILE")/test-daily.tsv"
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
  printf '%s' "$plain" | grep -q '| |' && bad "stray empty cell '| |'" || ok "no stray empty cells"
  # first-column separator aligns across all 4 lines
  col=$(printf '%s\n' "$plain" | head -1 | grep -bo ' | ' | head -1 | cut -d: -f1)
  aligned=1
  while IFS= read -r ln; do
    c=$(printf '%s' "$ln" | grep -bo ' | ' | head -1 | cut -d: -f1)
    [ -n "$c" ] && [ "$c" != "$col" ] && aligned=0
  done <<< "$plain"
  [ "$aligned" -eq 1 ] && ok "first separator aligned (byte-wise)" || bad "first separator misaligned"
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
  # >=20s old so the render actually appends and hits the write path)
  {
    printf "%s\x1fabc\x1f100\x1f0.01\n" "$((now-14400))"
    printf "%s\x1fabc\x1f%s\x1f%s\n" "$((now-240))" 50000 0.10 "$((now-120))" 58000 0.22 "$((now-25))" 66000 0.38
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
  printf '%s' "$solo" | grep -q '| |' && bad "solo row empty cell" || ok "solo row clean"
  printf '%s' "$solo" | grep -q 'Σ' && bad "solo row shows share" || ok "solo hides share"

  # own 10s trend state: the two renders above created one row per
  # tokened task (3 from the panel payload + 1 from solo)
  [ "$(grep -c . "$STATUSLINE_SUBAGENT_TREND_FILE" 2>/dev/null)" -eq 4 ] && ok "subagent trend rows captured" || bad "subagent trend file wrong"
  # pre-seeded trend csv (plus this render's fresh sample) drives the
  # sparkline as primary source
  printf "ms\x1f%s\x1f1000,3000,4000\n" "$((now-10))" > "$STATUSLINE_SUBAGENT_TREND_FILE"
  spark=$(subagent_payload "$now" | bash ./subagent-statusline.sh | jq -r 'select(.id=="ms") | .content' | strip)
  printf '%s' "$spark" | grep -qE '[▁▂▃▄▅▆]' && ok "subagent sparkline from own samples" || bad "own-sample sparkline missing"

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
