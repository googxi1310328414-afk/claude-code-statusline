#!/bin/bash
set -u
cd "$(dirname "$0")"

export HOME="$(pwd)/repro_home"
rm -rf "$HOME"
mkdir -p "$HOME/.claude"

export STATUSLINE_DAILY_FILE="$HOME/.claude/statusline-daily.tsv"
export STATUSLINE_HISTORY_FILE="$HOME/.claude/statusline-history.tsv"

sid="reprosid1"
now=$(printf '%(%s)T' -1)
today=$(printf '%(%Y%m%d)T' -1)
future=$(( now + 7200 ))
e1=$(( now - 600 ))
e2=$(( now - 400 ))
e3=$(( now - 200 ))

echo "== now=$now today=$today future=$future e1=$e1 e2=$e2 e3=$e3 =="

# Daily rollup file: today row for sid, closed=0 peak=300 prev=300, epoch stamped in the FUTURE
printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$today" "$sid" "0" "300" "300" "$future" > "$STATUSLINE_DAILY_FILE"

echo "---- daily file (before render) ----"
cat -A "$STATUSLINE_DAILY_FILE" | sed 's/\^_/|/g'

# Fine history file: 3 rows for the SAME sid, real past timestamps, cost climbing 1.00 -> 2.00 -> 3.00
{
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$e1" "$sid" "100" "1.00"
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$e2" "$sid" "100" "2.00"
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$e3" "$sid" "100" "3.00"
} > "$STATUSLINE_HISTORY_FILE"

echo "---- history file (before render) ----"
cat -A "$STATUSLINE_HISTORY_FILE" | sed 's/\^_/|/g'

payload=$(printf '{"session_id":"%s","cost":{"total_cost_usd":3.00}}' "$sid")

echo "---- payload ----"
echo "$payload"

echo "---- running statusline-command.sh ----"
echo "$payload" | bash ./statusline-command.sh > repro_stdout.txt 2> repro_stderr.txt
echo "exit code: $?"

echo "---- raw stdout (od head) ----"
head -c 2000 repro_stdout.txt | od -c | head -40

echo "---- stdout, ANSI stripped ----"
sed -E 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\x07]*\x07//g; s/\x1b\\//g' repro_stdout.txt

echo "---- stderr (err log tail) ----"
tail -n 40 repro_stderr.txt

echo "---- statusline-err.log (permanent black box) ----"
[ -f "$HOME/.claude/statusline-err.log" ] && cat "$HOME/.claude/statusline-err.log" || echo "(none)"

echo "---- daily file AFTER render ----"
cat -A "$STATUSLINE_DAILY_FILE" 2>/dev/null | sed 's/\^_/|/g'
