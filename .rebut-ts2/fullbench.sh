#!/bin/bash
# End-to-end comparison: full statusline-command.sh render, WITHOUT vs WITH a
# 490-line residual err.log (the "single past incident that never rotates"
# scenario from the finding), using the real fixtures/full.json payload.
set -u
cd "$(dirname "$0")/.."
home="$(pwd)/.rebut-ts2/fullhome"

time_render() {
  local label="$1"
  local n=5
  local total=0
  for ((i=0;i<n;i++)); do
    t0=$EPOCHREALTIME
    bash ./statusline-command.sh < fixtures/full.json > /dev/null 2>/dev/null
    t1=$EPOCHREALTIME
    d=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)*1000}')
    echo "  run$i: ${d}ms"
    total=$(awk -v t="$total" -v d="$d" 'BEGIN{printf "%.1f", t+d}')
  done
  avg=$(awk -v t="$total" -v n="$n" 'BEGIN{printf "%.1f", t/n}')
  echo "$label avg over $n runs: ${avg}ms"
}

echo "###### baseline: no err.log at all ######"
rm -rf "$home"
mkdir -p "$home/.claude"
export HOME="$home"
rm -f "$home/.claude/statusline-err.log"
time_render "NO-ERRLOG"

echo
echo "###### 490-line residual err.log present (never crosses 500, never rotates) ######"
for ((i=0;i<490;i++)); do
  printf 'fork: retry: Resource temporarily unavailable padpadpadpad\n'
done > "$home/.claude/statusline-err.log"
wc -c "$home/.claude/statusline-err.log"
time_render "WITH-490-LINE-ERRLOG"
echo "(err.log line count after the 5 runs above, to confirm it never rotated:)"
wc -l "$home/.claude/statusline-err.log"
