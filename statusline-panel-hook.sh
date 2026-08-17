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
# STDERR BLACKBOX (round-18): hard requirement 0c(a) - anything the host
# calls DIRECTLY must swallow its own stderr, because a single leaked
# byte blanks the whole bar. The main bar and the daemon both did this;
# the hook, which the host calls just as directly, did not. And the
# per-command `> file 2>/dev/null` idiom does NOT cover it: bash applies
# redirections left to right, so a failure to OPEN the target is
# reported on the fd 2 that is still the host's (measured: a directory
# sitting where the spool file goes leaks "Is a directory" to the host
# every ~5s tick). Its own fork-exhaustion retries would leak the same
# way - during exactly the storm this architecture exists to survive.
# Shares the daemon's log, which the daemon already rotates at startup.
# THE REDIRECT ITSELF MUST NOT LEAK (round-24): its OWN failure (a
# directory sitting where the log goes, an unwritable file or dir) is
# reported on the fd it is trying to replace - the very leak this line
# exists to stop. It cannot be wrapped in a redirected group either:
# bash restores fds when the group ends, which silently undoes the
# exec. So the two realistic failure modes are pre-checked with pure
# builtins, and the state-directory check moves up here so nothing
# else runs while stderr still belongs to the host.
[ -d "$panel_dir" ] || exit 0
hook_log="$panel_dir/daemon-err.log"
# and when it CANNOT be opened, fd 2 must still leave the host
# (round-25): skipping the redirect left every later diagnostic -
# including bash's own fork-retry storm - going straight to the bar.
if [ ! -d "$hook_log" ] &&
   { { [ -e "$hook_log" ] && [ -w "$hook_log" ]; } ||
     { [ ! -e "$hook_log" ] && [ -w "$panel_dir" ]; }; }; then
  exec 2>>"$hook_log"
else
  exec 2>/dev/null
fi
panel_daemon="${STATUSLINE_PANEL_DAEMON:-$HOME/.claude/statusline-panel-daemon.sh}"
# identity judgements must follow the CONFIGURED names (round-26): both
# paths are documented overrides, and a hardcoded filename made every
# check return false under a custom name - the wedged daemon was not
# killed, reap_failed stayed 0 because the case never matched, and the
# hook spawned a replacement anyway: the "only spawn, never reap"
# amplifier reinstated by configuration alone.
daemon_base="${panel_daemon##*/}"
renderer_base="${STATUSLINE_PANEL_RENDERER:-subagent-statusline.sh}"
renderer_base="${renderer_base##*/}"

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
  # FIRST ARGV AFTER BASH, NEVER THE LAST (round-30 - the law round-20
  # wrote for the watchdog, never applied to the three bash walks): this
  # loop kept overwriting until the end of cmdline, so the identity of
  # `bash <script> --once` came out as "--once" and every reclaim path
  # failed to recognise it. That exact shape is what test.sh spawns, and
  # it is how round-20's 14-CPU-hour leak happened. Options before the
  # script are skipped; a bare -c anywhere still voids the identity,
  # because then the "script" is an inline command string.
  REPLY_CMD=""
  [ -r "/proc/$1/cmdline" ] || return 0
  _ai_arg=""
  _ai_isc=0
  _ai_n=0
  while IFS= read -r -d '' _ai_arg; do
    _ai_n=$(( _ai_n + 1 ))
    [ "$_ai_arg" = "-c" ] && _ai_isc=1
    if [ "$_ai_n" -gt 1 ] && [ -z "$REPLY_CMD" ]; then
      case "$_ai_arg" in
        -*) : ;;
        *) REPLY_CMD=$_ai_arg ;;
      esac
    fi
    _ai_arg=""
  done < "/proc/$1/cmdline" 2>/dev/null
  # a cmdline whose tail lacks the trailing NUL leaves the last element
  # in the loop variable instead of the loop body
  if [ -n "$_ai_arg" ] && [ -z "$REPLY_CMD" ] && [ "$_ai_n" -ge 1 ]; then
    case "$_ai_arg" in
      -*) : ;;
      *) REPLY_CMD=$_ai_arg ;;
    esac
  fi
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
  # a reap that FAILED must not be followed by a spawn - see the
  # escalation note below
  reap_failed=0
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
    # accept the canonical name too (round-26 fix-up): STATUSLINE_PANEL_DAEMON
    # may point at a sentinel like /dev/null (the test harness does exactly
    # that to suppress respawns), and the REGISTERED daemon is then still a
    # normal install - matching only the configured basename made the hook
    # refuse to reap it
    case "$REPLY_CMD" in
      *"$daemon_base"|*statusline-panel-daemon.sh)
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
        kill -9 "$daemon_pid" 2>/dev/null
        # WINDOWS-SIDE ESCALATION (round-17, THIRD orphan storm, caught
        # live): a cygwin `kill -9` cannot kill a process wedged inside
        # the cygwin DLL - and that is the ONLY scenario this reap exists
        # for. Measured: kill -9 returns 0, the process does not budge
        # (two independent samples), while TerminateProcess on its NATIVE
        # pid kills it instantly. So the previous two "fixes" for this
        # incident class were reaping nothing whenever it actually
        # mattered: every ~65s the hook killed nothing, spawned a
        # replacement, and that replacement wedged too - one immortal
        # ~30%-CPU process per minute, forever. The native pid is read
        # from /proc/<pid>/winpid, i.e. from the very process we just
        # confirmed by cmdline - never from the pid file, which could be
        # stale. taskkill needs // to survive MSYS path mangling.
        # RE-CONFIRM BEFORE ESCALATING (round-18): `kill -0` stays true
        # for a moment after a SUCCESSFUL kill while the cygwin process
        # table entry drains, so it alone cannot tell "wedged" from "just
        # died". /proc/<pid> disappears immediately in the successful case
        # (measured, both detached and child shapes), so re-reading the
        # cmdline there is both the liveness proof and a fresh identity
        # check - a native kill is the one action in this file that could
        # hit a stranger if the pid were recycled, so it gets confirmed
        # twice and never fires on a corpse.
        if kill -0 "$daemon_pid" 2>/dev/null; then
          argv_identity "$daemon_pid"
          # THE CONFIGURED NAME BELONGS HERE TOO (round-30): the outer
          # case accepts *"$daemon_base" as well, but this inner one -
          # the gate in front of the native escalation and in front of
          # reap_failed - listed only the canonical filename. With
          # STATUSLINE_PANEL_DAEMON pointed at any other path (a
          # documented override), a wedged instance was TERM/KILLed
          # (which round-17 measured as a no-op on a process stuck inside
          # the cygwin DLL), never escalated to taskkill, and left
          # reap_failed at 0 - so the hook concluded the reclaim had
          # worked and spawned a replacement. That is the "only spawn,
          # never reap" amplifier reinstated by configuration alone,
          # which the comment above says round-26 closed; it closed the
          # outer case only.
          case "$REPLY_CMD" in
            *"$daemon_base"|*statusline-panel-daemon.sh)
              _wp=""
              [ -r "/proc/$daemon_pid/winpid" ] && read -r _wp < "/proc/$daemon_pid/winpid" 2>/dev/null
              [[ "$_wp" =~ ^[0-9]{1,10}$ ]] && command -v taskkill >/dev/null 2>&1 &&
                taskkill //F //PID "$_wp" >/dev/null 2>&1
              kill -0 "$daemon_pid" 2>/dev/null && [ -r "/proc/$daemon_pid/winpid" ] && reap_failed=1 ;;
          esac
        fi ;;
    esac
  fi
  # THE IN-FLIGHT RENDER CHILD (round-13): a wedged daemon is usually
  # wedged BECAUSE its child is stuck, and that child is NOT derivable
  # from here - hence line 4 of the pid file, which the daemon rewrites
  # on its 5s beat (empty while idle). This one IS group-killable: the
  # daemon starts it under `set -m`, so it leads its own group and the
  # renderer's own jq goes down with it. Same cmdline-tail identity
  # check as the daemon, so a recycled pid is never signalled.
  # LINE 4 IS A LIST (round-23): round-22 started publishing survivors
  # alongside the in-flight child, space separated, but this side still
  # matched the whole line against ^[0-9]+$ - which a space makes false,
  # so the branch was skipped entirely and NOTHING was reaped, not even
  # the current child. The one change made to keep survivors reachable
  # closed the only path that could reach them; iterate instead.
  # ALSO THE PERSISTED LIST (round-24): a daemon that died of idleness
  # or its lifetime cap takes the pid file with it, so line 4 is gone
  # exactly when a survivor is least reachable. The daemon keeps the
  # same list in a small file that outlives it; read both. (We do NOT
  # gate the respawn below on these: the survivor is already tracked
  # and retried by whatever daemon comes next, and refusing to spawn
  # would trade a leaked renderer for a permanently dark panel.)
  _rp_file=""
  [ -r "$panel_dir/orphans" ] && read -r _rp_file < "$panel_dir/orphans" 2>/dev/null
  # DEDUP, AND ONE NATIVE ESCALATION PER TICK (round-30): line 4 is built
  # from the daemon's own r_pid_pub PLUS r_orphans, and the orphans file
  # is that same r_orphans - so concatenating the two lists hands every
  # survivor to this loop TWICE, and each pass spends its own taskkill
  # exec. Survivors are by definition the ones taskkill did not kill, so
  # the cost is always paid in full: measured 4 taskkill calls and a 9s
  # hook for 2 survivors with a stubbed 2s taskkill, which at the ~31s
  # per exec this project has measured under fork exhaustion is about two
  # minutes. That is catastrophic for a hook whose entire reason to exist
  # is returning in milliseconds - the host re-invokes it every ~5s, the
  # stalled copies stack, and each one holds a fork slot that pushes the
  # exhaustion deeper. This is the same arithmetic round-29 removed on
  # the daemon side; the hook still had it. One escalation per tick is
  # enough: the next tick is 5 seconds away and the list is persistent.
  _rp_seen=""
  _rp_escalated=0
  for _rp in $daemon_rpid $_rp_file; do
    [[ "$_rp" =~ ^[0-9]{1,10}$ ]] || continue
    case " $_rp_seen " in
      *" $_rp "*) continue ;;
    esac
    _rp_seen="${_rp_seen}${_rp_seen:+ }$_rp"
    kill -0 "$_rp" 2>/dev/null || continue
    argv_identity "$_rp"
    case "$REPLY_CMD" in
      *"$renderer_base"|*subagent-statusline.sh)
        kill -- "-$_rp" 2>/dev/null
        kill "$_rp" 2>/dev/null
        kill -9 -- "-$_rp" 2>/dev/null
        if kill -0 "$_rp" 2>/dev/null && [ "$_rp_escalated" -eq 0 ]; then
          _rp_escalated=1
          _rwp=""
          [ -r "/proc/$_rp/winpid" ] && read -r _rwp < "/proc/$_rp/winpid" 2>/dev/null
          [[ "$_rwp" =~ ^[0-9]{1,10}$ ]] && command -v taskkill >/dev/null 2>&1 &&
            taskkill //F //PID "$_rwp" >/dev/null 2>&1
        fi ;;
    esac
  done
  # NEVER MINT A REPLACEMENT FOR SOMETHING WE COULD NOT KILL (round-17):
  # that is the whole amplifier. If even TerminateProcess did not get
  # rid of the old instance, the honest outcome is "no panel this tick"
  # (the host shows its default rows) until the watchdog clears it -
  # never "one more permanent CPU burner every 65 seconds", which has
  # now cost this machine 22, 3 and 3.9 CPU-hours in three separate
  # incidents.
  if [ "$reap_failed" -eq 0 ]; then
    ( bash "$panel_daemon" </dev/null >/dev/null 2>&1 & )
  fi
fi
exit 0
