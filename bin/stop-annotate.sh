#!/bin/sh
# stop-annotate.sh - workspace.closed hook. Stops the per-workspace savings poller.
set -u

STATE="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}"
WS=$(printf '%s' "${HERDR_WORKSPACE_ID:-default}" | tr -dc 'A-Za-z0-9._-')
[ -n "$WS" ] || WS=default
PIDF="$STATE/$WS.poller.pid"

if [ -f "$PIDF" ]; then
    pid=$(cat "$PIDF" 2>/dev/null | tr -dc '0-9' || true)
    # Only kill it if it is still our poller (guard against PID reuse).
    if [ -n "$pid" ] && ps -p "$pid" -o args= 2>/dev/null | grep -q savings-annotate; then
        kill "$pid" 2>/dev/null || true
    fi
fi

# Also sweep by command line, like bootstrap.sh: the pid file can be missing or
# point at only one of several pollers for this $WS. Pollers started before the
# TERM fix ignore TERM, so escalate to KILL for any that survive a short grace.
_sweep() { # signal
    ps -Ao pid=,args= 2>/dev/null | while read -r _pid _args; do
        case "$_args" in
        *"savings-annotate.sh $WS") kill "$1" "$_pid" 2>/dev/null || true ;;
        esac
    done
}
_sweep -TERM
sleep 1
_sweep -KILL
rm -f "$PIDF" 2>/dev/null || true
exit 0
