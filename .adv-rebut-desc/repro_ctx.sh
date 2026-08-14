#!/bin/bash
export LC_ALL=C.UTF-8
cd "C:/Users/ADMINI~1/AppData/Local/Temp/claude/C--Users-Administrator/ab8f6c17-a514-4972-928d-d5470eaeab98/scratchpad/claude-code-statusline" || exit 1

tmpd=$(mktemp -d)
export HOME="$tmpd/home"
mkdir -p "$HOME/.claude"
export STATUSLINE_HISTORY_FILE="$tmpd/hist.tsv"
export STATUSLINE_SUBAGENT_TREND_FILE="$tmpd/subtrend.tsv"
export STATUSLINE_DAILY_FILE="$tmpd/daily.tsv"
export STATUSLINE_PANEL_DIR="$tmpd/panel.d"
mkdir -p "$STATUSLINE_PANEL_DIR"
unset COLUMNS

strip() { perl -pe 's/\e\[[0-9;]*m//g; s/\e\]8;;[^\e]*\e\\//g'; }

echo "=== full.json (line2 ctx bar) ==="
bash ./statusline-command.sh < fixtures/full.json | strip | sed -n '2p'

echo "=== low-context.json (line1/2) ==="
bash ./statusline-command.sh < fixtures/low-context.json | strip

echo "tmpd=$tmpd"
