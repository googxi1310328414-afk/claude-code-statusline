#!/usr/bin/env bash
set -u
BASE="/tmp/claude/C--Users-Administrator/ab8f6c17-a514-4972-928d-d5470eaeab98/scratchpad/claude-code-statusline"
cd "$BASE" || exit 1

export HOME="$BASE/.adv1325/home_dual"
rm -rf "$HOME"
mkdir -p "$HOME/.claude"
export PATH="$BASE/.adv1325/fakebin:$PATH"
hash -r
export GH_CALL_LOG="$BASE/.adv1325/gh_calls_dual.log"
: > "$GH_CALL_LOG"

payload_a='{"session_id":"sessA","workspace":{"current_dir":"'"$BASE"'","repo":{"owner":"acme","name":"widgets","host":"github.com"}},"pr":{"number":"42"}}'
payload_b='{"session_id":"sessB","workspace":{"current_dir":"'"$BASE"'","repo":{"owner":"acme","name":"widgets","host":"github.com"}},"pr":{"number":"42"}}'

echo "=== dual-session: TWO independent Claude Code sessions, SAME repo+PR (SAME cache file), each on its own real 10s timer, gh hangs 25s ==="
t0=$(date +%s)
for i in 1 2 3; do
  now=$(date +%s)
  printf 'launching sessA-frame%d and sessB-frame%d at t=%ds\n' "$i" "$i" "$((now - t0))"
  ( printf '%s' "$payload_a" | bash "$BASE/statusline-command.sh" > "$BASE/.adv1325/dual_A_frame${i}.out" 2> "$BASE/.adv1325/dual_A_frame${i}.err" ) &
  ( printf '%s' "$payload_b" | bash "$BASE/statusline-command.sh" > "$BASE/.adv1325/dual_B_frame${i}.out" 2> "$BASE/.adv1325/dual_B_frame${i}.err" ) &
  if [ "$i" -lt 3 ]; then sleep 10; fi
done
wait
now=$(date +%s)
printf 'all frame subshells returned at t=%ds\n' "$((now - t0))"

echo "--- gh_calls_dual.log (2 sessions x 3 frames each, same 0/10/21s launch times as the single-session run) ---"
cat "$GH_CALL_LOG"
echo "--- total gh invocations, dual-session ---"
wc -l < "$GH_CALL_LOG"

echo "sleeping out the remaining hang time..."
sleep 30
echo "--- final cache file ---"
cat "$HOME/.claude/statusline-ci-cache."* 2>/dev/null
echo "--- final gh_calls_dual.log (should be unchanged from mid-run: cache resolved after ~25s, later frames were frame4/5-equivalent-free since this test only ran 3 rounds) ---"
cat "$GH_CALL_LOG"
wc -l < "$GH_CALL_LOG"
