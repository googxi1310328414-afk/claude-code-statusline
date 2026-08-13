#!/bin/bash
# Demo + assertion suite for both statusline scripts.
#   bash test.sh            # render all fixtures (see real colors in your terminal)
#   bash test.sh --codes    # show ANSI escapes as \e[..m for inspection
#   bash test.sh --assert   # silent checks, non-zero exit on failure (CI mode)
export LC_ALL=C.UTF-8
cd "$(dirname "$0")" || exit 1

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
  mkdir -p ~/.claude
  hist=~/.claude/statusline-history.tsv
  [ -f "$hist" ] && cp "$hist" "$hist.assertbak"
  tmpd=$(mktemp -d)
  now=$(date +%s)
  make_history "$now" "$hist"
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

  sub=$(subagent_payload "$now" | bash ./subagent-statusline.sh)
  [ "$(printf '%s\n' "$sub" | wc -l)" -eq 3 ] && ok "subagent 3 rows" || bad "subagent row count"
  all_json=1
  while IFS= read -r l; do printf '%s' "$l" | jq -e . >/dev/null 2>&1 || all_json=0; done <<< "$sub"
  [ "$all_json" -eq 1 ] && ok "subagent rows valid JSON" || bad "subagent invalid JSON"
  printf '%s' "$sub" | jq -r .content 2>/dev/null | strip | grep -q '5k tok' && ok "subagent field order (TSV fix)" || bad "subagent fields scrambled"
  solo=$(jq -n --argjson now "$now" '{columns:120,tasks:[{id:"t1",label:"solo",status:"running",tokenCount:5000,startTime:(($now-120)*1000),description:"x"}]}' | bash ./subagent-statusline.sh | jq -r .content | strip)
  printf '%s' "$solo" | grep -q '| |' && bad "solo row empty cell" || ok "solo row clean"
  printf '%s' "$solo" | grep -q 'Σ' && bad "solo row shows share" || ok "solo hides share"

  [ -f "$hist.assertbak" ] && mv -f "$hist.assertbak" "$hist" || rm -f "$hist"
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
