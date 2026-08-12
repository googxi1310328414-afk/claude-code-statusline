#!/bin/bash
# Renders every fixture through statusline-command.sh, plus a live git-repo
# demo (clean vs dirty branch). Run inside Git Bash from the repo root:
#   bash test.sh          # see the real colors in your terminal
#   bash test.sh --codes  # show ANSI escapes as \e[..m for inspection
cd "$(dirname "$0")" || exit 1

filter() {
  if [ "$1" = "--codes" ]; then sed 's/\x1b/\\e/g'; else cat; fi
}

for f in fixtures/*.json; do
  echo "=== $f ==="
  bash ./statusline-command.sh < "$f" | filter "$1"
done

# Branch demo: point current_dir at a real throwaway repo.
tmp=$(mktemp -d)
git -C "$tmp" init -q -b main 2>/dev/null || git -C "$tmp" init -q
tmp_json=$(jq --arg d "$tmp" '.workspace.current_dir=$d' fixtures/full.json)

echo "=== branch demo: clean ==="
printf '%s' "$tmp_json" | bash ./statusline-command.sh | filter "$1"

echo "=== branch demo: dirty (untracked file) ==="
echo wip > "$tmp/wip.txt"
printf '%s' "$tmp_json" | bash ./statusline-command.sh | filter "$1"

rm -rf "$tmp"
