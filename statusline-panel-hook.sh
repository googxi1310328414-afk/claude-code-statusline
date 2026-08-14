#!/bin/bash
# statusline-panel-hook.sh - the subagentStatusLine command. Returns in
# ~bash-startup time: it spools the payload for the resident daemon (see
# statusline-panel-daemon.sh's header for the whole architecture) and
# serves the previously cached frame instantly, so the host's "default
# rows until the hook returns" repaint window shrinks from the full
# render cost (~300ms) to a few milliseconds of builtins. Steady state
# spawns NOTHING - the only spawn this script ever takes is the detached
# daemon (re)launch when the daemon pid is dead.
export LC_ALL=C.UTF-8
panel_dir="${STATUSLINE_PANEL_DIR:-$HOME/.claude/statusline-panel.d}"
panel_daemon="${STATUSLINE_PANEL_DAEMON:-$HOME/.claude/statusline-panel-daemon.sh}"

# chunked zero-fork stdin slurp (see the render scripts' identical block)
input=""
while IFS= read -r -N 65536 slurp_chunk; do input+="$slurp_chunk"; done
input+="$slurp_chunk"

# cache key = FIRST task id in the payload: concurrent sessions have
# disjoint task sets, so each session maps to its own spool/cache pair
# and can never be served another session's rows; a session's own agent
# churn just changes the key and cold-misses one frame (default rows for
# one tick - same as a fresh spawn always was). Sanitized hard for
# filename use; no id at all (shouldn't happen - the host doesn't invoke
# this hook without tasks) -> serve nothing, spool nothing.
# STRICT STRING-VALUE FORMS ONLY (round-2 fix): the old "skip to the
# next quote after the id key" grabbed whatever quote came next, so a
# NON-string id ("id":123 / "id":null) made the key the following JSON
# KEY NAME (e.g. "name") - the same for every session, silently merging
# all sessions onto one spool/cache pair. Now the colon+quote must be
# adjacent (compact or one-space pretty form, the only shapes the host
# emits); anything else yields no key = serve nothing, which fails SAFE
# (default rows) instead of cross-serving another session's cache.
key=""
case "$input" in
  *'"id":"'*)  key=${input#*\"id\":\"};  key=${key%%\"*} ;;
  *'"id": "'*) key=${input#*\"id\": \"}; key=${key%%\"*} ;;
esac
if [ -n "$key" ]; then
  key=${key//[!A-Za-z0-9_-]/}
  key=${key:0:24}
fi
[ -n "$key" ] || exit 0
[ -d "$panel_dir" ] || exit 0

# newest-wins spool handoff, ONE builtin direct write (round-3 fix): the
# old tmp+mv pair spent a real fork+exec on mv (~50ms measured) inside
# the very latency window this whole architecture exists to shrink, and
# contradicted the "steady state spawns NOTHING" contract. Atomicity is
# deliberately traded away: the spool is newest-wins and lossy by design
# - a torn read (daemon mv'ing mid-write) just fails jq, the -s gate
# keeps the previous good frame, and the next ~5s tick delivers a fresh
# payload; three CONSECUTIVE tears would be needed to blank the cache
# (bad_streak), which a transient race cannot produce.
printf '%s' "$input" > "$panel_dir/spool.$key.new" 2>/dev/null

# serve the latest rendered frame for this key - one tick behind live,
# which for cumulative token counts/elapsed times is imperceptible
if [ -r "$panel_dir/cache.$key" ]; then
  mapfile -t panel_cached < "$panel_dir/cache.$key" 2>/dev/null
  [ "${#panel_cached[@]}" -gt 0 ] && printf '%s\n' "${panel_cached[@]}"
fi

# ensure the daemon is alive - kill -0 AND a fresh heartbeat (round-3
# fix): the pid file's 2nd line is an epoch the daemon rewrites every
# ~5s (and at most once per busy loop iteration). Bare kill -0 alone deadlocked when a stale pid got RECYCLED onto
# some unrelated live process (cygwin pids recycle fast on this box):
# the hook then believed the daemon alive forever, spools piled up, the
# panel froze with no recovery path. A stale/missing heartbeat (>60s,
# or old one-line format) now counts as dead; the spawned daemon's own
# takeover logic applies the same freshness verdict, so it correctly
# evicts the recycled-pid claim instead of deferring to it. The 60s
# threshold leaves headroom for slow busy-render iterations. All
# builtins; fully detached spawn so this hook never waits on it.
daemon_pid=""
daemon_hb=""
[ -r "$panel_dir/daemon.pid" ] && { read -r daemon_pid; read -r daemon_hb; } < "$panel_dir/daemon.pid" 2>/dev/null
daemon_alive=0
if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null && [[ "$daemon_hb" =~ ^[0-9]+$ ]]; then
  printf -v hook_now '%(%s)T' -1
  hb_age=$(( hook_now - daemon_hb ))
  [ "$hb_age" -ge -60 ] && [ "$hb_age" -le 60 ] && daemon_alive=1
fi
if [ "$daemon_alive" -eq 0 ]; then
  ( bash "$panel_daemon" </dev/null >/dev/null 2>&1 & )
fi
exit 0
