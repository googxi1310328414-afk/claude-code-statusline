#!/usr/bin/env bash
set -u
BASE="/tmp/claude/C--Users-Administrator/ab8f6c17-a514-4972-928d-d5470eaeab98/scratchpad/claude-code-statusline"
cd "$BASE" || exit 1

export HOME="$BASE/.adv1325/home_single"
rm -rf "$HOME"
mkdir -p "$HOME/.claude"
export PATH="$BASE/.adv1325/fakebin:$PATH"
hash -r
export GH_CALL_LOG="$BASE/.adv1325/gh_calls_single.log"
: > "$GH_CALL_LOG"

echo "sanity: command -v gh -> $(command -v gh)"

payload='{"session_id":"sessA","workspace":{"current_dir":"'"$BASE"'","repo":{"owner":"acme","name":"widgets","host":"github.com"}},"pr":{"number":"42"}}'

echo "=== single-session: 5 frames at real 10s cadence, gh hangs 25s each ==="
t0=$(date +%s)
for i in 1 2 3 4 5; do
  now=$(date +%s)
  printf 'launching frame%d at t=%ds\n' "$i" "$((now - t0))"
  ( printf '%s' "$payload" | bash "$BASE/statusline-command.sh" > "$BASE/.adv1325/single_frame${i}.out" 2> "$BASE/.adv1325/single_frame${i}.err" ) &
  if [ "$i" -lt 5 ]; then sleep 10; fi
done

sleep 3
now=$(date +%s)
printf 'ps snapshot at t=%ds:\n' "$((now - t0))"
ps -ef 2>/dev/null | grep -i 'fakebin/gh' | grep -v grep

echo "--- gh_calls_single.log (mid-run) ---"
cat "$GH_CALL_LOG"
echo "--- total gh invocations so far ---"
wc -l < "$GH_CALL_LOG"

echo "waiting for the 5 explicitly-backgrounded frame subshells to return (should be fast; they never block on gh)..."
wait
now=$(date +%s)
printf 'all 5 frame subshells returned at t=%ds\n' "$((now - t0))"

echo "--- ps snapshot right after frames returned (detached gh children should still be alive if truly detached) ---"
ps -ef 2>/dev/null | grep -i 'fakebin/gh' | grep -v grep

echo "sleeping until the last gh (launched ~t=40s, 25s hang -> completes ~t=65s) has had time to finish..."
sleep 25
now=$(date +%s)
printf 't=%ds\n' "$((now - t0))"
echo "--- ps snapshot, should be empty/near-empty now ---"
ps -ef 2>/dev/null | grep -i 'fakebin/gh' | grep -v grep
echo "--- final gh_calls_single.log ---"
cat "$GH_CALL_LOG"
echo "--- total gh invocations, final ---"
wc -l < "$GH_CALL_LOG"
echo "--- cache file after everything settles ---"
cat "$HOME/.claude/statusline-ci-cache."* 2>/dev/null
