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
# BOUNDED EXTRACTION (round-11): `${input#*"id":"}` is bash's shortest-
# prefix GLOB search - it rescans from every position, so the cost is
# QUADRATIC in the bytes it must skip. The payload shape that triggers
# it is explicitly allowed (a first task with no id, or a non-string
# id - test.sh covers exactly that), because the scan then has to cross
# that whole task's tokenSamples: measured 13.8s on an 80KB payload,
# i.e. the hook - whose entire reason for existing is to return within
# milliseconds - blocks for ~14s and the panel sits on the host's
# default rows, one extra 14s bash per ~5s tick. The prefix strip now
# runs over a bounded 4KiB slice; the rare payload whose first string
# id sits beyond that falls back to ONE awk pass (linear, ~ms) rather
# than the quadratic expansion.
key=""
key_head=${input:0:4096}
case "$key_head" in
  *'"id":"'*)  key=${key_head#*\"id\":\"} ;;
  *'"id": "'*) key=${key_head#*\"id\": \"} ;;
esac
# the CLOSING quote must also be inside the slice (round-12): an id that
# straddles the 4KiB boundary left %%\"* with nothing to strip, so the
# key became "id-prefix + slice tail garbage" - non-empty, so the awk
# fallback never fired, and since the payload's byte length shifts every
# tick the key CHANGED EVERY FRAME: permanent cache misses, one orphan
# cache file per tick. No closing quote -> treat as not found.
case "$key" in
  *'"'*) key=${key%%\"*} ;;
  *)     key="" ;;
esac
if [ -z "$key" ] && command -v awk >/dev/null 2>&1; then
  case "$input" in
    *'"id"'*)
      key=$(printf '%s' "$input" | awk 'match($0, /"id"[ ]*:[ ]*"[^"]*"/) { s = substr($0, RSTART, RLENGTH); sub(/^"id"[ ]*:[ ]*"/, "", s); sub(/"$/, "", s); print s; exit }' 2>/dev/null)
      ;;
  esac
fi
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
printf -v hook_now '%(%s)T' -1
if [ -r "$panel_dir/cache.$key" ]; then
  mapfile -t panel_cached < "$panel_dir/cache.$key" 2>/dev/null
  # FRESHNESS GATE (round-6): line 1 of the cache is the daemon's render
  # epoch. Serving is refused past 60s so a cache nobody can refresh -
  # daemon spawn failing under fork exhaustion, renderer script deleted -
  # degrades to the host's default rows instead of replaying a frozen
  # frame forever (elapsed times and token counts stuck but looking
  # live; the bad_streak guard only covers frames the daemon actually
  # renders, so it cannot help when the DAEMON is the missing part).
  # An unstamped (pre-round-6) cache reads as stale and self-heals on
  # the daemon's next successful render.
  if [ "${#panel_cached[@]}" -gt 1 ] && [[ "${panel_cached[0]}" =~ ^[0-9]+$ ]]; then
    cache_age=$(( hook_now - panel_cached[0] ))
    if [ "$cache_age" -ge -60 ] && [ "$cache_age" -le 60 ]; then
      printf '%s\n' "${panel_cached[@]:1}"
    fi
  fi
fi

# ensure the daemon is alive - kill -0 AND a fresh heartbeat (round-3
# fix): the pid file's 2nd line is an epoch the daemon rewrites on a
# WALL-CLOCK 5s cadence (checked every loop and every render-wait tick,
# so busy/hung renders cannot starve it). Bare kill -0 alone deadlocked when a stale pid got RECYCLED onto
# some unrelated live process (cygwin pids recycle fast on this box):
# the hook then believed the daemon alive forever, spools piled up, the
# panel froze with no recovery path. A stale/missing heartbeat (>60s,
# or old one-line format) now counts as dead; the spawned daemon's own
# takeover logic applies the same freshness verdict, so it correctly
# evicts the recycled-pid claim instead of deferring to it. The 60s
# threshold leaves headroom for slow busy-render iterations. All
# builtins; fully detached spawn so this hook never waits on it.
# ZERO-FORK IDENTITY READ (round-13, live incident: 38 orphaned daemons
# burning 3.03 CPU-hours were found on the dev machine WITH the round-9
# reap already in place). The reap confirmed identity with
# `$(tr \0 ' ' < /proc/<pid>/cmdline)` - a COMMAND SUBSTITUTION, i.e. a
# fork, on the one code path whose entire reason for existing is fork
# exhaustion. When the fork fails the capture is empty, the pattern never
# matches, nothing is killed - and the hook spawns a replacement anyway.
# That is precisely the "only spawn, never reap" amplifier from the 78-
# orphan incident, restored by its own fix: one wedged daemon per ~65s,
# forever, each one spinning on the idle tick. /proc/<pid>/cmdline is
# NUL-separated, so bash reads it with `read -d ''` and no process at all.
# argv-POSITION discipline (same as the watchdog): the verdict is the LAST
# argv element, and any process with a bare `-c` element is excluded
# outright - a shell that merely TALKS about the script (a diagnostic, a
# test, an agent's own bash) carries the whole command as one -c argument
# and must never enter a kill set.
argv_identity() { # $1=pid -> REPLY_CMD ("" = unknown/not confirmable)
  REPLY_CMD=""
  [ -r "/proc/$1/cmdline" ] || return 0
  _ai_arg=""
  _ai_isc=0
  while IFS= read -r -d '' _ai_arg; do
    [ "$_ai_arg" = "-c" ] && _ai_isc=1
    REPLY_CMD=$_ai_arg
    _ai_arg=""
  done < "/proc/$1/cmdline" 2>/dev/null
  # a cmdline whose tail lacks the trailing NUL leaves the last element
  # in the loop variable instead of REPLY_CMD
  [ -n "$_ai_arg" ] && REPLY_CMD=$_ai_arg
  [ "$_ai_isc" -eq 1 ] && REPLY_CMD=""
  return 0
}
daemon_pid=""
daemon_hb=""
daemon_wpid=""
daemon_rpid=""
[ -r "$panel_dir/daemon.pid" ] && { read -r daemon_pid; read -r daemon_hb; read -r daemon_wpid; read -r daemon_rpid; } < "$panel_dir/daemon.pid" 2>/dev/null
daemon_alive=0
if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null && [[ "$daemon_hb" =~ ^[0-9]+$ ]]; then
  hb_age=$(( hook_now - daemon_hb ))
  [ "$hb_age" -ge -60 ] && [ "$hb_age" -le 60 ] && daemon_alive=1
fi
if [ "$daemon_alive" -eq 0 ]; then
  # REAP BEFORE RESPAWN (round-9, after a real incident: 78 orphaned
  # daemons burning 22 CPU-hours were found on the dev machine). A
  # registered pid that is ALIVE but whose heartbeat froze means the
  # daemon wedged somewhere it can no longer beat from. The old code
  # just spawned a replacement and walked away - nothing anywhere ever
  # reaped the wedged one (the daemon's own takeover only rm's the pid
  # file, install only kills a FRESH-heartbeat instance, and the
  # watchdog deliberately skips daemons), so one wedge minted a new
  # permanent process every ~65s forever. Killing is safe against pid
  # recycling because the pid came from OUR pid file AND we verify the
  # process is really a panel daemon before signalling.
  if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    # confirm the pid really IS our daemon before signalling: the
    # cmdline is NUL-separated so the SCRIPT PATH is its tail -
    # matching the tail (not "mentions anywhere") keeps a shell that
    # merely TALKS about the file (a diagnostic, a test, an agent's
    # own bash) out of the kill set.
    argv_identity "$daemon_pid"
    case "$REPLY_CMD" in
      *statusline-panel-daemon.sh)
        # NO GROUP KILL ON THE DAEMON (round-13): round-12 added
        # `kill -- "-$daemon_pid"` to take the stuck render child down
        # with it, but the daemon is spawned as `( bash ... & )` from a
        # script with NO job control - it inherits THIS hook's process
        # group and is not a group leader, so that signal went to a
        # group that does not exist (ESRCH, measured: the daemon
        # survived both group kills and died only to the bare pid kill).
        # It was not merely useless: cygwin recycles pids fast, and a
        # recycled pid matching some unrelated live PGID would have
        # taken that whole group down - the shape of the 2026-08-13/14
        # mis-kill incidents. The child is reaped by pid instead, below.
        kill "$daemon_pid" 2>/dev/null
        kill -9 "$daemon_pid" 2>/dev/null ;;
    esac
  fi
  # THE IN-FLIGHT RENDER CHILD (round-13): a wedged daemon is usually
  # wedged BECAUSE its child is stuck, and that child is NOT derivable
  # from here - hence line 4 of the pid file, which the daemon rewrites
  # on its 5s beat (empty while idle). This one IS group-killable: the
  # daemon starts it under `set -m`, so it leads its own group and the
  # renderer's own jq goes down with it. Same cmdline-tail identity
  # check as the daemon, so a recycled pid is never signalled.
  if [[ "$daemon_rpid" =~ ^[0-9]+$ ]] && kill -0 "$daemon_rpid" 2>/dev/null; then
    argv_identity "$daemon_rpid"
    case "$REPLY_CMD" in
      *subagent-statusline.sh)
        kill -- "-$daemon_rpid" 2>/dev/null
        kill "$daemon_rpid" 2>/dev/null
        kill -9 -- "-$daemon_rpid" 2>/dev/null ;;
    esac
  fi
  ( bash "$panel_daemon" </dev/null >/dev/null 2>&1 & )
fi
exit 0
