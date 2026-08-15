#!/bin/bash
# Standalone width measurer that mirrors disp_width() from subagent-statusline.sh exactly,
# to independently verify the true rendered cell-width of a stripped (ANSI-free) row string
# read from stdin (one row per line).
export LC_ALL=C.UTF-8

disp_width() {
  local s="$1"
  if [[ "$s" != *[![:ascii:]]* ]]; then
    REPLY="${#s}"
    return
  fi
  local len=${#s} i c cp w total=0
  for ((i=0; i<len; i++)); do
    c="${s:i:1}"
    if [[ "$c" == [[:ascii:]] ]]; then
      total=$(( total + 1 ))
      continue
    fi
    printf -v cp '%d' "'$c"
    w=1
    if   [ "$cp" -ge 4352 ]   && [ "$cp" -le 4447 ]; then w=2
    elif [ "$cp" -ge 11904 ]  && [ "$cp" -le 12350 ]; then w=2
    elif [ "$cp" -ge 12353 ]  && [ "$cp" -le 13311 ]; then w=2
    elif [ "$cp" -ge 13312 ]  && [ "$cp" -le 19903 ]; then w=2
    elif [ "$cp" -ge 19968 ]  && [ "$cp" -le 40959 ]; then w=2
    elif [ "$cp" -ge 40960 ]  && [ "$cp" -le 42191 ]; then w=2
    elif [ "$cp" -ge 44032 ]  && [ "$cp" -le 55203 ]; then w=2
    elif [ "$cp" -ge 63744 ]  && [ "$cp" -le 64255 ]; then w=2
    elif [ "$cp" -ge 65072 ]  && [ "$cp" -le 65103 ]; then w=2
    elif [ "$cp" -ge 65280 ]  && [ "$cp" -le 65376 ]; then w=2
    elif [ "$cp" -ge 65504 ]  && [ "$cp" -le 65510 ]; then w=2
    elif [ "$cp" -ge 127744 ] && [ "$cp" -le 129791 ]; then w=2
    elif [ "$cp" -ge 131072 ]; then w=2
    fi
    total=$(( total + w ))
  done
  REPLY="$total"
}

while IFS= read -r line; do
  # strip ANSI CSI sequences (ESC [ ... m)
  stripped="$line"
  stripped=$(printf '%s' "$stripped" | sed 's/\x1b\[[0-9;]*m//g')
  disp_width "$stripped"
  printf 'width=%s :: %s\n' "$REPLY" "$stripped"
done
