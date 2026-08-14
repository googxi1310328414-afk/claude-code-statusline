#!/bin/bash
export LC_ALL=C.UTF-8
cd "C:/Users/ADMINI~1/AppData/Local/Temp/claude/C--Users-Administrator/ab8f6c17-a514-4972-928d-d5470eaeab98/scratchpad/claude-code-statusline" || exit 1

tmpd=$(mktemp -d)
export HOME="$tmpd/home"
mkdir -p "$HOME/.claude"
export STATUSLINE_SUBAGENT_TREND_FILE="$tmpd/subtrend.tsv"
export STATUSLINE_PANEL_DIR="$tmpd/panel.d"
mkdir -p "$STATUSLINE_PANEL_DIR"

strip() { perl -pe 's/\e\[[0-9;]*m//g; s/\e\]8;;[^\e]*\e\\//g'; }

echo "=== raw JL (one JSON object per line) ==="
bash ./subagent-statusline.sh < fixtures/subagent-tasks.json

echo
echo "=== stripped .content per task id ==="
bash ./subagent-statusline.sh < fixtures/subagent-tasks.json | while IFS= read -r l; do
  id=$(printf '%s' "$l" | jq -r .id)
  content=$(printf '%s' "$l" | jq -r .content | strip)
  echo "[$id] $content"
done

echo "tmpd=$tmpd"
