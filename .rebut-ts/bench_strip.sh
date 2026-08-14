# builds a synthetic line: N bytes of filler, then "timestamp":"...", then ~380B tail
mk() { # $1 = target prefix bytes
  local n=$1 pad
  printf -v pad '%*s' "$n" ''
  pad=${pad// /x}
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}],"usage":{"cache_read_input_tokens":12345,"cache_creation_input_tokens":0}},"timestamp":"2026-08-14T08:00:00.000Z","uuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","sessionId":"11111111-2222-3333-4444-555555555555","version":"2.0.0","gitBranch":"main","isSidechain":false}\n' "$pad"
}
for kb in 14 29 58 116; do
  line=$(mk $((kb*1024)))
  # warm
  t0=$(date +%s%N)
  ts_rest="${line#*\"timestamp\":\"}"
  t1=$(date +%s%N)
  ts_val="${ts_rest%%\"*}"
  echo "size=${#line}B  strip_ms=$(( (t1-t0)/1000000 ))  ts=$ts_val"
done
