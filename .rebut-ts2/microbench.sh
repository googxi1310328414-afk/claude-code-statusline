#!/bin/bash
# Isolated micro-benchmark of statusline-command.sh lines 27-33 (the err.log
# self-rotation check) in isolation, at varying pre-existing line counts, to
# get real numbers independent of the rest of the script's render cost.
export LC_ALL=C.UTF-8
set -u

home="$(pwd)/mbhome"
rm -rf "$home"
mkdir -p "$home/.claude"

run_once() {
  local lines="$1"
  local log="$home/.claude/statusline-err.log"
  rm -f "$log"
  if [ "$lines" -gt 0 ]; then
    for ((i=0;i<lines;i++)); do
      printf 'fork: retry: Resource temporarily unavailable padpadpadpad\n'
    done > "$log"
  fi
  local sizeb
  sizeb=$(wc -c < "$log" 2>/dev/null || echo 0)

  local t0 t1
  t0=$EPOCHREALTIME
  # ---- exact logic copied from statusline-command.sh lines 27-33 ----
  statusline_err_log="$log"
  if [ -f "$statusline_err_log" ]; then
    statusline_err_lines=()
    mapfile -t statusline_err_lines < "$statusline_err_log" 2>/dev/null
    [ "${#statusline_err_lines[@]}" -gt 500 ] && : > "$statusline_err_log" 2>/dev/null
  fi
  # ---------------------------------------------------------------------
  t1=$EPOCHREALTIME
  awk -v a="$t0" -v b="$t1" -v n="$lines" -v sz="$sizeb" 'BEGIN{printf "lines=%-7d bytes=%-9d elapsed_ms=%.1f\n", n, sz, (b-a)*1000}'
}

echo "== cold (file absent) =="
rm -f "$home/.claude/statusline-err.log"
t0=$EPOCHREALTIME
statusline_err_log="$home/.claude/statusline-err.log"
if [ -f "$statusline_err_log" ]; then
  statusline_err_lines=()
  mapfile -t statusline_err_lines < "$statusline_err_log" 2>/dev/null
  [ "${#statusline_err_lines[@]}" -gt 500 ] && : > "$statusline_err_log" 2>/dev/null
fi
t1=$EPOCHREALTIME
awk -v a="$t0" -v b="$t1" 'BEGIN{printf "elapsed_ms=%.2f\n", (b-a)*1000}'

echo "== 490 lines (post-incident residual, never rotates) x3 =="
run_once 490
run_once 490
run_once 490

echo "== 500 lines boundary =="
run_once 500

echo "== 5000 lines =="
run_once 5000

echo "== 20000 lines (claimed multi-second spike) =="
run_once 20000
