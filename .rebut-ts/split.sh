export LC_ALL=C.UTF-8
f=$1
t0=$(date +%s%N)
tail_scan=$(tail -c 524288 -- "$f" 2>/dev/null | awk '
  /"subtype":"compact_boundary"/ && !/"isSidechain":true/ { print "C" $0; next }
  /"type":"assistant"/ && !/"isSidechain":true/ && /"timestamp":"/ && (/"cache_read_input_tokens": ?[1-9]/ || /"cache_creation_input_tokens": ?[1-9]/) { last = $0 }
  END { if (last != "") print "A" last }')
t1=$(date +%s%N)
mapfile -t L <<< "$tail_scan"
t2=$(date +%s%N)
c=""
for x in "${L[@]}"; do case "$x" in A*) c="${x#A}";; esac; done
t3=$(date +%s%N)
r="${c#*\"timestamp\":\"}"
t4=$(date +%s%N)
v="${r%%\"*}"
t5=$(date +%s%N)
printf 'awk+tail=%dms mapfile=%dms caseloop=%dms STRIP_1809=%dms suffix=%dms  cand_bytes=%d ts=%s\n' \
  $(( (t1-t0)/1000000 )) $(( (t2-t1)/1000000 )) $(( (t3-t2)/1000000 )) $(( (t4-t3)/1000000 )) $(( (t5-t4)/1000000 )) "${#c}" "$v"
