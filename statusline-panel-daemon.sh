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
#   spool.<key>.new  newest un-rendered payload (atomic mv handoff from
#                    the hook; overwriting an unconsumed spool = a
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
  mapfile -t _el < "$err_log" 2>/dev/null
  [ "${#_el[@]}" -gt 500 ] && : > "$err_log" 2>/dev/null
fi
exec 2>>"$err_log"

if [ "$once" -eq 0 ]; then
  if ! ( set -C; printf '%s\n' "$$" > "$panel_dir/daemon.pid" ) 2>/dev/null; then
    holder=""
    [ -r "$panel_dir/daemon.pid" ] && read -r holder < "$panel_dir/daemon.pid"
    if [ -n "$holder" ] && [ "$holder" != "$$" ] && kill -0 "$holder" 2>/dev/null; then
      exit 0
    fi
    # stale/empty claim: remove it and retry the EXCLUSIVE create once -
    # of two concurrent takeover attempts exactly one wins the noclobber
    # race, the loser exits and the next hook tick re-probes the winner
    rm -f "$panel_dir/daemon.pid" 2>/dev/null
    ( set -C; printf '%s\n' "$$" > "$panel_dir/daemon.pid" ) 2>/dev/null || exit 0
  fi
  # startup housekeeping: orphaned in-flight claims from a crashed
  # predecessor, caches nothing has touched for a day, and orphaned
  # per-PID tmp files a killed hook/daemon left behind (age-gated so a
  # LIVE instance's in-flight tmp, seconds old, is never swept)
  rm -f "$panel_dir"/render.* 2>/dev/null
  find "$panel_dir" \( -name 'cache.*' -mmin +1440 -o -name 'spool.*.tmp.*' -mmin +10 \) -delete 2>/dev/null
fi

tick_fifo="$panel_dir/.tick.fifo"
[ -p "$tick_fifo" ] || mkfifo "$tick_fifo" 2>/dev/null

shopt -s nullglob
idle=0
render_seq=0
while :; do
  worked=0
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
    bash "$renderer" < "$panel_dir/render.$key" > "$cache_tmp" 2>>"$err_log" &
    r_pid=$!
    r_waited=0
    while kill -0 "$r_pid" 2>/dev/null; do
      [ "$r_waited" -ge "$render_ticks" ] && break
      if [ -p "$tick_fifo" ]; then
        read -t 0.3 -r _tick <> "$tick_fifo" 2>/dev/null
      else
        sleep 0.3 2>/dev/null || break
      fi
      r_waited=$(( r_waited + 1 ))
    done
    if kill -0 "$r_pid" 2>/dev/null; then
      # deadline expired: kill the hung child, skip this frame (the
      # cache keeps serving the previous good frame; the next spool
      # retries with a fresh payload)
      kill "$r_pid" 2>/dev/null
      wait "$r_pid" 2>/dev/null
      rm -f "$cache_tmp" 2>/dev/null
    elif wait "$r_pid" 2>/dev/null; then
      mv -f "$cache_tmp" "$panel_dir/cache.$key" 2>/dev/null
    else
      rm -f "$cache_tmp" 2>/dev/null
    fi
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
fi
exit 0
