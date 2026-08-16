#!/bin/bash
# statusline-panel-daemon.sh - resident renderer behind the subagent
# panel hook. WHY: the host repaints the panel with its DEFAULT rows
# first and only swaps in custom rows when the hook returns, so hook
# latency IS the visible "flash back to default" window. In-hook
# rendering cost ~300ms even fully optimized (jq spawn + bash startup
# are the irreducible floor), so the render is moved off the hook path
# entirely: the hook (statusline-panel-hook.sh) spools the payload and
# serves the previous cached frame; this daemon renders arrivals
# asynchronously. Content runs one panel tick (~5s, host-fixed) behind
# live - imperceptible for cumulative token counts and elapsed times.
#
# FILES (all under $STATUSLINE_PANEL_DIR, default
# ~/.claude/statusline-panel.d):
#   spool.<key>.new  newest un-rendered payload (ONE direct builtin
#                    write from the hook - deliberately NOT atomic, the
#                    spool is newest-wins/lossy and a torn read only
#                    skips a frame; overwriting an unconsumed spool = a
#                    deliberately skipped frame, newest wins)
#   render.<key>     this daemon's in-flight claim (mv-consumed spool)
#   cache.<key>      latest rendered rows, served instantly by the hook
#   daemon.pid       single-instance claim: noclobber create; on
#                    conflict the holder's liveness is probed, a stale
#                    file is REMOVED and the noclobber create retried
#                    ONCE (never a bare `>` overwrite - that truncation
#                    window let a concurrent starter read an empty file
#                    and conclude "no holder"); removed on exit only if
#                    it still holds OUR pid (a second instance's claim
#                    is never deleted out from under it)
#   daemon-err.log   stderr blackbox, self-rotated at ~500 lines
# <key> = first task id of the payload (see the hook's comment) - each
# concurrent session gets its own spool/cache pair.
#
# LIFECYCLE: spawned detached by any hook tick that finds the pid dead;
# exits by itself after ~2min without work (sessions closed / agents
# done); a crashed instance is simply respawned on the next tick.
# Renders run the ordinary panel script as a CHILD so every rendering
# semantic stays in exactly one place. HUNG-CHILD DEADLINE (adversarial
# review fix, 2026-08-14): the child render used to be awaited
# synchronously with NO timeout - a child hung under fork exhaustion
# (a failure mode this project has hit for real) blocked this loop
# forever while `kill -0` kept telling every hook tick the daemon was
# "alive", freezing every session's panel on its last cached frame
# indefinitely, with no recovery path at all on a default install (the
# optional watchdog only reaps the RENDERER script by name, and never
# this daemon - by design, since the daemon legitimately runs long).
# The render is now launched in the background and awaited on the same
# zero-spawn fifo tick, with a hard deadline
# ($STATUSLINE_PANEL_RENDER_TIMEOUT seconds, default 15, ~50x a normal
# render): on expiry the child is killed, the frame is skipped, and the
# next spool retries - the daemon itself can no longer be wedged by its
# child. The 0.3s idle tick uses the fifo `read -t` trick - zero spawns
# per tick; if mkfifo is unavailable it falls back to one external
# sleep per tick. --once processes pending spools and exits (test
# harness mode; skips the single-instance gate).
export LC_ALL=C.UTF-8
panel_dir="${STATUSLINE_PANEL_DIR:-$HOME/.claude/statusline-panel.d}"
# WINDOWS PID (round-10): the pid file's 3rd line carries the NATIVE
# Windows pid, because cygwin pids are meaningless to the PowerShell
# watchdog - without it the watchdog could only match daemons by
# "command line mentions the script name", which also matches any shell
# that merely TALKS about the file (a diagnostic, a test, an AI agent's
# own bash) and let it -Force kill unrelated processes AND the healthy
# registered daemon. Absent /proc (non-MSYS) leaves it empty and the
# watchdog then simply does nothing - fail safe, never fail deadly.
daemon_winpid=""
[ -r /proc/self/winpid ] && read -r daemon_winpid < /proc/self/winpid 2>/dev/null
[[ "$daemon_winpid" =~ ^[0-9]+$ ]] || daemon_winpid=""
renderer="${STATUSLINE_PANEL_RENDERER:-$HOME/.claude/subagent-statusline.sh}"
[ -d "$panel_dir" ] || exit 0
once=0
[ "$1" = "--once" ] && once=1

render_timeout="${STATUSLINE_PANEL_RENDER_TIMEOUT:-15}"
[[ "$render_timeout" =~ ^[0-9]+$ ]] || render_timeout=15
# deadline in 0.3s ticks (integer ceil-ish; 15s -> 50 ticks)
render_ticks=$(( render_timeout * 10 / 3 ))
[ "$render_ticks" -lt 1 ] && render_ticks=1

err_log="$panel_dir/daemon-err.log"
if [ -f "$err_log" ]; then
  mapfile -t -n 501 _el < "$err_log" 2>/dev/null
  [ "${#_el[@]}" -gt 500 ] && : > "$err_log" 2>/dev/null
fi
exec 2>>"$err_log"

# pid file format: FOUR lines - cygwin_pid / heartbeat_epoch /
# windows_pid / in-flight render child pid (empty when idle). Lines 3
# and 4 exist for the two reapers that cannot see this process tree:
# the PowerShell watchdog needs a NATIVE pid (cygwin pids mean nothing
# to it), and the hook needs the render child's pid because it CANNOT
# derive it - this daemon is spawned as `( bash ... & )` from a script
# with no job control, so it is not a process-group leader and killing
# "its group" reaches nothing (round-13; the renderer, started under
# `set -m` below, is a group leader and IS group-killable).
# heartbeat (rewritten on a wall-clock 5s cadence by hb_beat below) is what
# lets the hook and the takeover path tell a LIVE daemon from a stale
# pid recycled onto some unrelated cygwin process - bare `kill -0` alone
# deadlocked forever in that case: hook thought the daemon was alive and
# never respawned, spools piled up, the panel froze with no recovery.
# A liveness verdict is kill -0 AND a numeric heartbeat younger than 60s
# (missing/old-format heartbeat counts as stale -> smooth migration).
if [ "$once" -eq 0 ]; then
  printf -v hb_now '%(%s)T' -1
  if ! ( set -C; printf '%s\n%s\n%s\n%s\n' "$$" "$hb_now" "$daemon_winpid" "" > "$panel_dir/daemon.pid" ) 2>/dev/null; then
    holder=""
    holder_hb=""
    [ -r "$panel_dir/daemon.pid" ] && { read -r holder; read -r holder_hb; } < "$panel_dir/daemon.pid"
    holder_fresh=0
    if [[ "$holder_hb" =~ ^[0-9]+$ ]]; then
      hb_age=$(( hb_now - holder_hb ))
      [ "$hb_age" -ge -60 ] && [ "$hb_age" -le 60 ] && holder_fresh=1
    fi
    if [ -n "$holder" ] && [ "$holder" != "$$" ] && [ "$holder_fresh" -eq 1 ] && kill -0 "$holder" 2>/dev/null; then
      exit 0
    fi
    # stale/empty/recycled claim: remove it and retry the EXCLUSIVE
    # create once - of two concurrent takeover attempts exactly one wins
    # the noclobber race, the loser exits and the next hook tick
    # re-probes the winner
    rm -f "$panel_dir/daemon.pid" 2>/dev/null
    ( set -C; printf '%s\n%s\n%s\n%s\n' "$$" "$hb_now" "$daemon_winpid" "" > "$panel_dir/daemon.pid" ) 2>/dev/null || exit 0
  fi
  # startup housekeeping: orphaned in-flight claims from a crashed
  # predecessor, caches nothing has touched for a day, and orphaned
  # per-PID tmp files a killed hook/daemon left behind (age-gated so a
  # LIVE instance's in-flight tmp, seconds old, is never swept)
  rm -f "$panel_dir"/render.* 2>/dev/null
  find "$panel_dir" \( -name 'cache.*' -mmin +1440 -o -name 'spool.*.tmp.*' -mmin +10 -o -name 'daemon.pid.tmp.*' -mmin +10 -o -name 'cache.*.raw.*' -mmin +10 -o -name '.tick.*' -mmin +10 \) -delete 2>/dev/null
fi

# PER-INSTANCE FIFO (round-17): every instance used to do timed reads on
# ONE shared fifo. With several instances alive (exactly what the orphan
# storms produce) that is N processes doing concurrent read-write opens
# and 0.3s timed reads on the same cygwin named pipe - a contention
# shape whose cost lands in SYSTEM time, which is where the wedged
# instances were measured to burn ~93% of their CPU. Own fifo per
# instance: no cross-instance contention, and a leftover one is swept
# by the next start (below) instead of being inherited.
tick_fifo="$panel_dir/.tick.$$.fifo"
[ -p "$tick_fifo" ] || mkfifo "$tick_fifo" 2>/dev/null

# ABSOLUTE LIFETIME CAP (round-9): a daemon that wedges ANYWHERE
# outside the beat checkpoints can no longer be detected by its own
# logic - and the 78-orphan incident proved nothing else reaps it
# either. SECONDS is bash-internal (no clock dependency, no fork), so
# even a fully wedged loop that still cycles will hit this ceiling and
# exit; a live session simply gets a fresh instance from the next hook
# tick (cold-missing one frame, the same cost as any respawn).
daemon_max_life="${STATUSLINE_PANEL_DAEMON_MAX_LIFE:-3600}"
[[ "$daemon_max_life" =~ ^[0-9]+$ ]] || daemon_max_life=3600
shopt -s nullglob
idle=0
render_seq=0
# pid of the render child while one is in flight, published on line 4
# of the pid file by the next beat so an external reaper can reach it
r_pid_pub=""
# bumped only when a timed-out render child outlives its reap, so the
# capture file it may still be writing into is never reused
raw_gen=0
# render children that outlived even the native kill: they stay on
# line 4 of the pid file (space separated) until they really die
r_orphans=""
last_hb=0
[ "$once" -eq 0 ] && last_hb=$hb_now
# WALL-CLOCK heartbeat (round-4 fix for a round-3 regression): the first
# heartbeat implementation counted LOOP ITERATIONS (every 15th), but an
# iteration's duration is unbounded - each spool's render wait adds up
# to render_timeout, so a hung renderer stretched the beat interval to
# ~230s and even 4 busy sessions could pass 60s. The hook then judged a
# perfectly alive daemon dead, spawned a rival that evicted the live pid
# registration and trampled in-flight claims - measured stacking up to
# 8 concurrent daemons, exactly the process amplification this project
# treats as its survival line. Beats are now pure wall clock: at most
# one write per 5s, checked every loop AND every 0.3s render-wait tick,
# so no code path can starve the beat. Atomic tmp+mv (one fork per 5s
# worst case, off the hot hook path).
# OWNERSHIP-GATED (round-5 PRODUCTION hotfix): only the currently
# REGISTERED instance may refresh the heartbeat. The first wall-clock
# version wrote itself unconditionally, which turned every live
# instance into a per-5s registration usurper: with just two instances
# momentarily alive (dual-session spawn race), each kept overwriting
# the other's claim, every hook tick then saw a claim whose owner had
# already conceded and spawned yet another daemon - 112 stacked
# instances were reaped off the real machine. Now: registered -> beat;
# someone ELSE registered and alive -> concede (exit) on the spot;
# dead/missing claim -> take over via the exclusive-create discipline.
# This also folds the old separate ownership self-check into the beat.
# never exit while a render child is still running (round-13): the
# concede / lost-the-takeover paths below can fire from INSIDE the
# render wait loop, and a bare `exit` left that child orphaned - still
# running, still holding its tmp name, with no parent to reap it. That
# is the same leak the hook's REAP exists to stop, just minted from
# the other side. The child IS a process-group leader (`set -m`), so
# the group kill here is real, unlike the one on the daemon itself.
# zero-fork argv confirmation, same discipline as the hook: the LAST
# argv element must be the renderer, and any bare `-c` disqualifies.
# Needed because r_pid_pub/r_orphans can name a pid that has since
# died and been recycled - and these are GROUP kills, so a wrong pid
# takes a whole unrelated group with it (the 2026-08-13/14 shape).
child_is_renderer() { # $1=pid
  [ -r "/proc/$1/cmdline" ] || return 1
  _ci_arg=""
  _ci_last=""
  _ci_isc=0
  while IFS= read -r -d '' _ci_arg; do
    [ "$_ci_arg" = "-c" ] && _ci_isc=1
    _ci_last=$_ci_arg
    _ci_arg=""
  done < "/proc/$1/cmdline" 2>/dev/null
  [ -n "$_ci_arg" ] && _ci_last=$_ci_arg
  [ "$_ci_isc" -eq 1 ] && return 1
  case "$_ci_last" in
    *subagent-statusline.sh) return 0 ;;
  esac
  return 1
}
quit_with_child() {
  if [ -n "$r_pid_pub" ] && kill -0 "$r_pid_pub" 2>/dev/null && child_is_renderer "$r_pid_pub"; then
    kill -- "-$r_pid_pub" 2>/dev/null
    kill "$r_pid_pub" 2>/dev/null
    # no grace period: we are conceding this instant and will not be here
    # to reap, and a TERM-immune child (they exist - see the render
    # deadline's escalation, and test R35) would otherwise walk away
    kill -9 -- "-$r_pid_pub" 2>/dev/null
    kill -9 "$r_pid_pub" 2>/dev/null
    # SAME NATIVE ESCALATION AS THE RENDER DEADLINE (round-19): a cygwin
    # kill cannot touch a child wedged inside the cygwin DLL, and this
    # path runs from inside the render wait loop - so conceding almost
    # always means there IS a child in flight. Without this, one takeover
    # race plus one wedged child = one immortal renderer, and the winning
    # instance immediately overwrites line 4, leaving nothing that can
    # reach it. /proc/<pid> is gone for a child that really died, so this
    # never fires on a corpse.
    if kill -0 "$r_pid_pub" 2>/dev/null && [ -r "/proc/$r_pid_pub/winpid" ]; then
      q_wp=""
      read -r q_wp < "/proc/$r_pid_pub/winpid" 2>/dev/null
      [[ "$q_wp" =~ ^[0-9]{1,10}$ ]] && command -v taskkill >/dev/null 2>&1 &&
        taskkill //F //PID "$q_wp" >/dev/null 2>&1
    fi
    # the aborted render's tmp pair has no other sweeper on this path
    # (cache.* is only age-swept after a day)
    [ -n "${cache_tmp:-}" ] && rm -f "$cache_tmp" "${raw_tmp:-}" 2>/dev/null
  fi
  exit 0
}
hb_beat() {
  [ "$once" -eq 1 ] && return 0
  printf -v hb_t '%(%s)T' -1
  # CLOCK-ROLLBACK GUARD (round-9): a backwards clock step makes the
  # delta NEGATIVE, which is also "< 5" - the beat then froze for the
  # entire rollback span, the hook judged this healthy daemon dead and
  # spawned a rival, and this instance could never reach the concede
  # branch below because it kept returning on this very line. Every
  # other clock comparison in this project already carries this guard.
  hb_delta=$(( hb_t - last_hb ))
  if [ "$hb_delta" -lt 0 ]; then
    last_hb=$hb_t
  elif [ "$hb_delta" -lt 5 ]; then
    return 0
  fi
  last_hb=$hb_t
  # SURVIVOR RETRY, BELOW THE THROTTLE (round-23): this block used to sit
  # ABOVE the 5s gate, and hb_beat runs on every 0.3s tick - so a single
  # survivor meant a taskkill exec ~3x a second (measured ~180-260ms
  # each), on the one code path whose entire reason for existing is fork
  # exhaustion. It also stretched the tick itself, and both the render
  # deadline and the 2-minute idle death are counted in TICKS, so a 15s
  # timeout silently became ~25-40s. Retry on the beat, as the comment
  # always claimed. Identity is re-confirmed before signalling, because a
  # cygwin pid that has since been recycled would otherwise take an
  # unrelated process group with it.
  if [ -n "$r_orphans" ]; then
    _still=""
    for _op in $r_orphans; do
      kill -0 "$_op" 2>/dev/null || continue
      if ! child_is_renderer "$_op"; then continue; fi
      kill -9 "$_op" 2>/dev/null
      if kill -0 "$_op" 2>/dev/null && [ -r "/proc/$_op/winpid" ]; then
        _owp=""
        read -r _owp < "/proc/$_op/winpid" 2>/dev/null
        [[ "$_owp" =~ ^[0-9]{1,10}$ ]] && command -v taskkill >/dev/null 2>&1 &&
          taskkill //F //PID "$_owp" >/dev/null 2>&1
      fi
      kill -0 "$_op" 2>/dev/null && _still="${_still}${_still:+ }$_op"
    done
    r_orphans="$_still"
  fi
  hb_cur=""
  [ -r "$panel_dir/daemon.pid" ] && read -r hb_cur < "$panel_dir/daemon.pid"
  if [ "$hb_cur" = "$$" ]; then
    printf '%s\n%s\n%s\n%s\n' "$$" "$hb_t" "$daemon_winpid" "${r_pid_pub}${r_orphans:+ }${r_orphans}" > "$panel_dir/daemon.pid.tmp.$$" 2>/dev/null && mv -f "$panel_dir/daemon.pid.tmp.$$" "$panel_dir/daemon.pid" 2>/dev/null
  elif [ -n "$hb_cur" ] && kill -0 "$hb_cur" 2>/dev/null; then
    quit_with_child
  else
    rm -f "$panel_dir/daemon.pid" 2>/dev/null
    ( set -C; printf '%s\n%s\n%s\n%s\n' "$$" "$hb_t" "$daemon_winpid" "${r_pid_pub}${r_orphans:+ }${r_orphans}" > "$panel_dir/daemon.pid" ) 2>/dev/null || quit_with_child
  fi
}
# per-key consecutive bad-frame counter (round-3 fix): the -s keep-frame
# gate protects the cache from TRANSIENT blank renders, but a PERSISTENT
# failure (jq gone from PATH, renderer deleted, permanent hang) then
# froze every session's panel on its last good frame indefinitely -
# stale numbers dressed up as live ones, with no signal and no recovery
# on a default install. After 3 consecutive bad frames (~15s) the cache
# is explicitly EMPTIED: the hook then serves nothing, the host falls
# back to its default rows - an honest degradation (the main bar prints
# "jq missing" in the same scenario; the panel now stops lying too). A
# later successful render simply repopulates the cache.
declare -A bad_streak
while :; do
  worked=0
  # OWNERSHIP SELF-CHECK (~9s cadence, zero spawns): the rm+exclusive-
  # recreate takeover still has a narrow TOCTOU where two racers both
  # end up running with only the later one's pid registered. The exit-
  # time ownership check (below) already stops the cascade; this check
  # CONVERGES the transient double-daemon fast - an instance that finds
  # a DIFFERENT live pid registered concedes and exits instead of
  # coasting to the 2-minute idle death.
  # ownership + heartbeat in ONE gate (hb_beat handles both: beat when
  # registered, concede when someone else holds a live claim, take over
  # a dead one)
  [ "$once" -eq 0 ] && hb_beat
  for sp in "$panel_dir"/spool.*.new; do
    key=${sp##*/spool.}
    key=${key%.new}
    mv -f "$sp" "$panel_dir/render.$key" 2>/dev/null || continue
    # per-render tmp seq: on MSYS/NTFS an unlinked-but-still-open file
    # name stays reserved (delete pending) until the last fd closes, so
    # a killed child's tmp name may be briefly unreusable - a fresh seq
    # per render sidesteps that entirely
    render_seq=$(( render_seq + 1 ))
    cache_tmp="$panel_dir/cache.$key.tmp.$$.$render_seq"
    # the raw capture is REUSED per (instance, key) and truncated with a
    # builtin instead of rm'd (round-17): `rm` is a fork, and a fork on
    # the per-render path is exactly what cannot be afforded during the
    # fork exhaustion these storms grow out of - every wedged instance
    # found on this machine had written its .raw file and then stopped,
    # i.e. it never got past the next external command. A stable name
    # also avoids the delete-pending problem the per-render seq exists
    # for, since nothing is ever unlinked while open.
    raw_tmp="$panel_dir/cache.$key.raw.$$.$raw_gen"
    # own process group (job control) so the timeout path can signal
    # the renderer AND its grandchildren as one unit
    set -m 2>/dev/null
    bash "$renderer" < "$panel_dir/render.$key" > "$raw_tmp" 2>>"$err_log" &
    r_pid=$!
    set +m 2>/dev/null
    # publish for external reapers; the next beat (<=5s, and beats run
    # on every wait tick) writes it to line 4 of the pid file, so any
    # render long enough to wedge this daemon is always reachable
    r_pid_pub=$r_pid
    r_waited=0
    while kill -0 "$r_pid" 2>/dev/null; do
      [ "$r_waited" -ge "$render_ticks" ] && break
      if [ -p "$tick_fifo" ]; then
        read -t 0.3 -r _tick <> "$tick_fifo" 2>/dev/null
      else
        sleep 0.3 2>/dev/null || break
      fi
      r_waited=$(( r_waited + 1 ))
      # keep the wall-clock heartbeat alive DURING renders too - a hung
      # child otherwise starves the beat for up to render_timeout per
      # spool and gets this live daemon judged dead (see hb_beat)
      hb_beat
    done
    frame_bad=0
    if kill -0 "$r_pid" 2>/dev/null; then
      # deadline expired: kill the hung child, skip this frame (the
      # cache keeps serving the previous good frame; the next spool
      # retries with a fresh payload)
      # ESCALATE + BOUNDED REAP (round-8): a plain SIGTERM plus an
      # unbounded `wait` was two assumptions too many. A child wedged
      # in a Windows syscall (exactly the fork-exhaustion case this
      # deadline exists for) ignores TERM, and the unbounded wait then
      # froze this loop - and the heartbeat with it - re-creating the
      # very "hung child welds the daemon shut" failure the deadline
      # was added to remove. Now: TERM, one 0.3s grace tick, KILL, then
      # a BOUNDED wait (~1s of ticks) and move on regardless - a
      # never-reaped child costs one zombie slot, an unbounded wait
      # costs every session's panel. Grandchildren (the renderer's own
      # jq) are reaped by killing the whole process GROUP when the
      # shell supports job control; otherwise they exit on their own
      # once their pipe closes.
      kill "$r_pid" 2>/dev/null
      kill -- "-$r_pid" 2>/dev/null
      sleep 0.3 2>/dev/null
      kill -9 "$r_pid" 2>/dev/null
      kill -9 -- "-$r_pid" 2>/dev/null
      r_reap=0
      while kill -0 "$r_pid" 2>/dev/null && [ "$r_reap" -lt 4 ]; do
        sleep 0.3 2>/dev/null || break
        r_reap=$(( r_reap + 1 ))
      done
      # NATIVE ESCALATION (round-18): this deadline exists for a child
      # wedged inside a Windows syscall, and round-17 measured that a
      # cygwin kill -9 cannot kill exactly that - only TerminateProcess
      # on the native pid can. Without it the daemon "gave up" on an
      # immortal renderer every render_timeout and started another: one
      # permanent process per ~15s, four times the rate of the daemon
      # storm this was patterned after, and nothing else could reach
      # them (the hook only sees line 4, which give-up used to clear).
      # /proc/<pid> is already gone for a child that really died, so
      # this can never fire on a corpse.
      if kill -0 "$r_pid" 2>/dev/null && [ -r "/proc/$r_pid/winpid" ]; then
        r_wp=""
        read -r r_wp < "/proc/$r_pid/winpid" 2>/dev/null
        [[ "$r_wp" =~ ^[0-9]{1,10}$ ]] && command -v taskkill >/dev/null 2>&1 &&
          taskkill //F //PID "$r_wp" >/dev/null 2>&1
      fi
      if kill -0 "$r_pid" 2>/dev/null && [ -r "/proc/$r_pid/winpid" ]; then
        # still alive: keep its pid published on line 4 so the hook and
        # install can still reach it, and switch capture generations -
        # that file now belongs to a process we do not control, and a
        # late flush into a REUSED name would interleave itself into the
        # next frame, which the -s gate would then publish as good.
        # KEEP IT PUBLISHED FOR GOOD (round-22): r_pid_pub is a single
        # scalar that the NEXT render overwrites within one tick (~5s,
        # or immediately when another key is in the same glob), so
        # round-18's "stay reachable" lasted exactly one frame. A
        # child that outlived even taskkill is precisely the one that
        # must stay reachable, so survivors accumulate in a list that
        # is published alongside the current child and retried on
        # every beat until they are really gone.
        case " $r_orphans " in
          *" $r_pid "*) : ;;
          *) r_orphans="${r_orphans}${r_orphans:+ }$r_pid" ;;
        esac
        # tracked in the list now - keeping it in r_pid_pub too would
        # publish the same pid twice on line 4 and leave it dangling
        # there long after the survivor list has pruned it (round-23)
        r_pid_pub=""
        raw_gen=$(( raw_gen + 1 ))
      fi
      # no rm here (round-20): $cache_tmp is only ever CREATED in the
      # success branch below and mv'd away in the same breath, so on
      # this path it never exists - and `rm` is a fork, on the one path
      # that only runs when forking is already failing.
      frame_bad=1
    elif wait "$r_pid" 2>/dev/null && [ -s "$raw_tmp" ]; then
      # -s gate: a renderer that exits 0 with EMPTY output (fork
      # exhaustion makes its jq capture come back blank and the script
      # end cleanly with no rows) must NOT overwrite the last good frame
      # with a zero-byte cache - the hook would then serve nothing and
      # every session's panel would blank precisely during the storms
      # this cache exists to ride out. Skip the frame instead.
      # STAMPED CACHE (round-6): line 1 is the render epoch, the rows
      # follow. The hook refuses to serve a stamp older than 60s, which
      # closes the last "panel lies" window: bad_streak only protects
      # frames the daemon actually renders, so when the DAEMON ITSELF
      # cannot run (spawn failing under fork exhaustion, script deleted)
      # the hook used to replay the last good frame forever - running
      # agents frozen at the same elapsed time, indistinguishable from
      # live. All builtins (mapfile+printf), no extra fork.
      mapfile -t _rows < "$raw_tmp" 2>/dev/null
      : > "$raw_tmp" 2>/dev/null
      printf -v _cache_ep '%(%s)T' -1
      { printf '%s
' "$_cache_ep"; printf '%s
' "${_rows[@]}"; } > "$cache_tmp" 2>/dev/null &&
        mv -f "$cache_tmp" "$panel_dir/cache.$key" 2>/dev/null
      bad_streak[$key]=0
    else
      : > "$raw_tmp" 2>/dev/null
      frame_bad=1
    fi
    if [ "$frame_bad" -eq 1 ]; then
      bad_streak[$key]=$(( ${bad_streak[$key]:-0} + 1 ))
      if [ "${bad_streak[$key]}" -ge 3 ]; then
        # persistent failure: stop serving the stale frame (see the
        # bad_streak comment above the loop)
        : > "$panel_dir/cache.$key" 2>/dev/null
        bad_streak[$key]=0
      fi
    fi
    # a survivor already moved itself into r_orphans and cleared this
    r_pid_pub=""
    rm -f "$panel_dir/render.$key" 2>/dev/null
    worked=1
  done
  [ "$once" -eq 1 ] && break
  if [ "$worked" -eq 1 ]; then
    idle=0
  else
    idle=$(( idle + 1 ))
  fi
  [ "$idle" -ge 400 ] && break
  [ "$once" -eq 0 ] && [ "$SECONDS" -ge "$daemon_max_life" ] && break
  if [ -p "$tick_fifo" ]; then
    read -t 0.3 -r _tick <> "$tick_fifo" 2>/dev/null
  else
    sleep 0.3 2>/dev/null || break
  fi
done
if [ "$once" -eq 0 ]; then
  # ownership-checked removal: if a second instance ever claimed the
  # file (crash-takeover races), exiting must NOT delete ITS live claim
  # - that deletion made the next hook tick spawn a THIRD instance whose
  # startup housekeeping then trampled the survivor's in-flight render
  cur_holder=""
  [ -r "$panel_dir/daemon.pid" ] && read -r cur_holder < "$panel_dir/daemon.pid"
  [ "$cur_holder" = "$$" ] && rm -f "$panel_dir/daemon.pid" 2>/dev/null
  rm -f "$tick_fifo" "$panel_dir"/cache.*.raw.$$.* 2>/dev/null
fi
exit 0
