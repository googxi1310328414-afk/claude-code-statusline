#!/bin/bash
set -u
cd "$(dirname "$0")"

export HOME="$(pwd)/repro_home_ctrl"
rm -rf "$HOME"
mkdir -p "$HOME/.claude"

export STATUSLINE_DAILY_FILE="$HOME/.claude/statusline-daily.tsv"
export STATUSLINE_HISTORY_FILE="$HOME/.claude/statusline-history.tsv"

sid="reprosid1"
now=$(printf '%(%s)T' -1)
today=$(printf '%(%Y%m%d)T' -1)
e1=$(( now - 600 ))
e2=$(( now - 400 ))
e3=$(( now - 200 ))

payload=$(printf '{"session_id":"%s","cost":{"total_cost_usd":3.00}}' "$sid")

# same 3 fine rows in both control cases
write_hist() {
  {
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$e1" "$sid" "100" "1.00"
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$e2" "$sid" "100" "2.00"
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$e3" "$sid" "100" "3.00"
  } > "$STATUSLINE_HISTORY_FILE"
}

echo "###### CONTROL A: no daily file at all (fresh seed from fine rows) ######"
rm -f "$STATUSLINE_DAILY_FILE"
write_hist
echo "$payload" | bash ./statusline-command.sh 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\x07]*\x07//g; s/\x1b\\//g'
echo "-- daily file after --"
cat "$STATUSLINE_DAILY_FILE" 2>/dev/null

echo
echo "###### CONTROL B: daily file with PAST (already-caught-up) watermark epoch=e3, same closed/peak/prev as repro ######"
printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$today" "$sid" "0" "300" "300" "$e3" > "$STATUSLINE_DAILY_FILE"
write_hist
echo "$payload" | bash ./statusline-command.sh 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\x07]*\x07//g; s/\x1b\\//g'
echo "-- daily file after --"
cat "$STATUSLINE_DAILY_FILE" 2>/dev/null

echo
echo "###### CONTROL C: daily file with FUTURE epoch (bug trigger) but only 1 fine row equal to prev (no lower row) ######"
future=$(( now + 7200 ))
printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$today" "$sid" "0" "300" "300" "$future" > "$STATUSLINE_DAILY_FILE"
{ printf '%s\x1f%s\x1f%s\x1f%s\n' "$e3" "$sid" "100" "3.00"; } > "$STATUSLINE_HISTORY_FILE"
echo "$payload" | bash ./statusline-command.sh 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\x07]*\x07//g; s/\x1b\\//g'
echo "-- daily file after --"
cat "$STATUSLINE_DAILY_FILE" 2>/dev/null
