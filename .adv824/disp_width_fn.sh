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
    if   [ "$cp" -ge 4352 ]   && [ "$cp" -le 4447 ]; then w=2    # 1100-115F
    elif [ "$cp" -ge 11904 ]  && [ "$cp" -le 12350 ]; then w=2   # 2E80-303E
    elif [ "$cp" -ge 12353 ]  && [ "$cp" -le 13311 ]; then w=2   # 3041-33FF
    elif [ "$cp" -ge 13312 ]  && [ "$cp" -le 19903 ]; then w=2   # 3400-4DBF
    elif [ "$cp" -ge 19968 ]  && [ "$cp" -le 40959 ]; then w=2   # 4E00-9FFF
    elif [ "$cp" -ge 40960 ]  && [ "$cp" -le 42191 ]; then w=2   # A000-A4CF
    elif [ "$cp" -ge 44032 ]  && [ "$cp" -le 55203 ]; then w=2   # AC00-D7A3
    elif [ "$cp" -ge 63744 ]  && [ "$cp" -le 64255 ]; then w=2   # F900-FAFF
    elif [ "$cp" -ge 65072 ]  && [ "$cp" -le 65103 ]; then w=2   # FE30-FE4F
    elif [ "$cp" -ge 65280 ]  && [ "$cp" -le 65376 ]; then w=2   # FF00-FF60
    elif [ "$cp" -ge 65504 ]  && [ "$cp" -le 65510 ]; then w=2   # FFE0-FFE6
    elif [ "$cp" -ge 127744 ] && [ "$cp" -le 129791 ]; then w=2  # 1F300-1FAFF
    elif [ "$cp" -ge 131072 ]; then w=2                          # >= 20000
    fi
    total=$(( total + w ))
  done
  REPLY="$total"
}
