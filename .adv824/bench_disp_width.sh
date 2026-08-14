#!/bin/bash
export LC_ALL=C.UTF-8
source "$(dirname "$0")/disp_width_fn.sh"

mk_cjk() {
  local n=$1 out="" chunk
  printf -v chunk '审%.0s' $(seq 1 "$n")
  out="$chunk"
  REPLY="$out"
}

for n in 40 100 500 1000 2000 5000; do
  mk_cjk "$n"; s="$REPLY"
  actual_chars=${#s}
  t0=$(date +%s%N)
  disp_width "$s"
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  echo "n=$n actual_chars=$actual_chars disp_width_result=$REPLY elapsed_ms=$ms"
done

echo "--- ASCII fast-path control (should be ~0ms even at 5000 chars) ---"
ascii5000=$(printf 'a%.0s' $(seq 1 5000))
t0=$(date +%s%N)
disp_width "$ascii5000"
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
echo "ascii n=5000 disp_width_result=$REPLY elapsed_ms=$ms"

echo "--- single trailing non-ASCII char forces full scalar loop even though string is mostly ASCII ---"
mixed=$(printf 'a%.0s' $(seq 1 999))
mixed="${mixed}审"
t0=$(date +%s%N)
disp_width "$mixed"
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
echo "mixed n=1000(999 ascii + 1 cjk) disp_width_result=$REPLY elapsed_ms=$ms"
