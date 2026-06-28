#!/bin/sh
# stop-annotate.sh - workspace.closed hook. Stops the per-workspace savings poller.
set -u

STATE="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}"
WS=$(printf '%s' "${HERDR_WORKSPACE_ID:-default}" | tr -dc 'A-Za-z0-9._-')
[ -n "$WS" ] || WS=default
PIDF="$STATE/$WS.poller.pid"

[ -f "$PIDF" ] || exit 0
pid=$(cat "$PIDF" 2>/dev/null | tr -dc '0-9' || true)
# Only kill it if it is still our poller (guard against PID reuse).
if [ -n "$pid" ] && ps -p "$pid" -o args= 2>/dev/null | grep -q savings-annotate; then
    kill "$pid" 2>/dev/null || true
fi
rm -f "$PIDF" 2>/dev/null || true
exit 0
