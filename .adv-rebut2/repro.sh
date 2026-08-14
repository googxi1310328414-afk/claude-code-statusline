#!/usr/bin/env bash
# Minimal extraction of the exact logic at statusline-command.sh:2126-2131
printf -v now_epoch '%(%s)T' -1

test_case() {
  local label="$1" usage_epoch="$2"
  local usage_needs_refresh=1
  local usage_age=$(( now_epoch - usage_epoch ))
  [ "$usage_age" -lt 180 ] && usage_needs_refresh=0
  local shows_stale=0
  [ "$usage_age" -le 1800 ] && shows_stale=1
  printf '%-28s now=%s cache_epoch=%s age=%s needs_refresh=%s shows_stale_data=%s\n' \
    "$label" "$now_epoch" "$usage_epoch" "$usage_age" "$usage_needs_refresh" "$shows_stale"
}

# Normal case: cache written 60s ago -> fresh, no refresh, shows data (expected/correct)
test_case "normal-fresh(-60s)"        $(( now_epoch - 60 ))
# Normal case: cache written 500s ago -> stale, refresh fires, still shows data (expected/correct)
test_case "normal-stale(-500s)"       $(( now_epoch - 500 ))
# Normal case: cache written 3600s ago -> too old, should NOT show (expected: shows_stale=0)
test_case "normal-expired(-3600s)"    $(( now_epoch - 3600 ))
# Clock-rollback case: cache stamped 2h in the FUTURE (NTP jump then correction / snapshot restore)
test_case "future(+7200s) small"      $(( now_epoch + 7200 ))
# Clock-rollback case: cache stamped 30 DAYS in the future (large snapshot/RTC fault)
test_case "future(+30d) large"        $(( now_epoch + 2592000 ))
