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
key=""
case "$input" in
  *'"id"'*)
    # tolerant of compact ("id":"x") AND pretty ("id": "x") JSON: skip
    # to the first quote after the "id" key = the value's opening quote
    key=${input#*\"id\"}
    key=${key#*\"}
    key=${key%%\"*}
    key=${key//[!A-Za-z0-9_-]/}
    key=${key:0:24}
    ;;
esac
[ -n "$key" ] || exit 0
[ -d "$panel_dir" ] || exit 0

# newest-wins spool handoff: an unconsumed spool overwritten here is a
# deliberately skipped frame (the daemon always renders the freshest
# payload it can get)
printf '%s' "$input" > "$panel_dir/spool.$key.tmp.$$" 2>/dev/null &&
  mv -f "$panel_dir/spool.$key.tmp.$$" "$panel_dir/spool.$key.new" 2>/dev/null

# serve the latest rendered frame for this key - one tick behind live,
# which for cumulative token counts/elapsed times is imperceptible
if [ -r "$panel_dir/cache.$key" ]; then
  mapfile -t panel_cached < "$panel_dir/cache.$key" 2>/dev/null
  [ "${#panel_cached[@]}" -gt 0 ] && printf '%s\n' "${panel_cached[@]}"
fi

# ensure the daemon is alive (builtin kill -0 liveness probe; fully
# detached spawn so this hook never waits on it)
daemon_pid=""
[ -r "$panel_dir/daemon.pid" ] && read -r daemon_pid < "$panel_dir/daemon.pid" 2>/dev/null
if ! { [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; }; then
  ( bash "$panel_daemon" </dev/null >/dev/null 2>&1 & )
fi
exit 0
