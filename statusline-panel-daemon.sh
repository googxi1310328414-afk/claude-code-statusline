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
#                    conflict the holder's liveness is probed and a
#                    stale pid is taken over
#   daemon-err.log   stderr blackbox, self-rotated at ~500 lines
# <key> = first task id of the payload (see the hook's comment) - each
# concurrent session gets its own spool/cache pair.
#
# LIFECYCLE: spawned detached by any hook tick that finds the pid dead;
# exits by itself after ~2min without work (sessions closed / agents
# done); a crashed instance is simply respawned on the next tick.
# Renders run the ordinary panel script as a CHILD so every rendering
# semantic stays in exactly one place - a hung child (<1s normally) is
# reaped by the statusline watchdog task and the daemon retries on the
# next spool. The 0.3s idle tick uses the fifo `read -t` trick - zero
# spawns per tick; if mkfifo is unavailable it falls back to one
# external sleep per tick. --once processes pending spools and exits
# (test harness mode; skips the single-instance gate).
export LC_ALL=C.UTF-8
panel_dir="${STATUSLINE_PANEL_DIR:-$HOME/.claude/statusline-panel.d}"
renderer="${STATUSLINE_PANEL_RENDERER:-$HOME/.claude/subagent-statusline.sh}"
[ -d "$panel_dir" ] || exit 0
once=0
[ "$1" = "--once" ] && once=1

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
    printf '%s\n' "$$" > "$panel_dir/daemon.pid" 2>/dev/null || exit 0
  fi
  # startup housekeeping: orphaned in-flight claims from a crashed
  # predecessor, and caches nothing has touched for a day
  rm -f "$panel_dir"/render.* 2>/dev/null
  find "$panel_dir" -name 'cache.*' -mmin +1440 -delete 2>/dev/null
fi

tick_fifo="$panel_dir/.tick.fifo"
[ -p "$tick_fifo" ] || mkfifo "$tick_fifo" 2>/dev/null

shopt -s nullglob
idle=0
while :; do
  worked=0
  for sp in "$panel_dir"/spool.*.new; do
    key=${sp##*/spool.}
    key=${key%.new}
    mv -f "$sp" "$panel_dir/render.$key" 2>/dev/null || continue
    if bash "$renderer" < "$panel_dir/render.$key" > "$panel_dir/cache.$key.tmp.$$" 2>>"$err_log"; then
      mv -f "$panel_dir/cache.$key.tmp.$$" "$panel_dir/cache.$key" 2>/dev/null
    else
      rm -f "$panel_dir/cache.$key.tmp.$$" 2>/dev/null
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
[ "$once" -eq 0 ] && rm -f "$panel_dir/daemon.pid" 2>/dev/null
exit 0
