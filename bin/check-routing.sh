#!/bin/sh
# check-routing.sh - pane.agent_detected hook.
#
# Verify routing is actually live (proxy env present AND daemon responding), not
# merely that setup ran. Warn at most once per workspace, and self-heal: the
# warning clears once routing is confirmed, so a later relaunch stops nagging.
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/herdr-rpc.sh"

STATE="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}"
# Sanitize anything used in a state filename (no path traversal via $WS/$HOST).
HOST=$(hostname 2>/dev/null | tr -dc 'A-Za-z0-9._-' || true)
[ -n "$HOST" ] || HOST=unknown
WS=$(printf '%s' "${HERDR_WORKSPACE_ID:-default}" | tr -dc 'A-Za-z0-9._-')
[ -n "$WS" ] || WS=default
mkdir -p "$STATE" 2>/dev/null || true

CONFIRMED="$STATE/routing_confirmed.$WS.$HOST"
WARNED="$STATE/routing_warned.$WS.$HOST"

[ -f "$CONFIRMED" ] && exit 0

notify() { # title, body
    herdr_rpc notification.show \
        "$(jq -n --arg t "$1" --arg b "$2" '{title:$t, body:$b}')" \
        >/dev/null 2>&1 || true
}
warn_once() { # title, body  -- one warning per workspace until routing confirmed
    [ -f "$WARNED" ] && return 0
    notify "$1" "$2"
    : > "$WARNED" 2>/dev/null || true
}

proxy="${HTTPS_PROXY:-${https_proxy:-}}"
if [ -z "$proxy" ]; then
    warn_once "llmtrim: relaunch herdr" \
        "Routing is configured but herdr started before it. Relaunch herdr once to route agents through the proxy."
    exit 0
fi

# Proxy env present: confirm the daemon is actually up (frozen contract: status
# --json always exits 0; read .daemon, treating a missing object as not running).
LLMTRIM=$(command -v llmtrim 2>/dev/null || true)
running=false
if [ -n "$LLMTRIM" ]; then
    js=$("$LLMTRIM" status --json 2>/dev/null || echo '{}')
    running=$(printf '%s' "$js" | jq -r '(.daemon.running // false)' 2>/dev/null || echo false)
fi

if [ "$running" = "true" ]; then
    : > "$CONFIRMED" 2>/dev/null || true
    rm -f "$WARNED" 2>/dev/null || true
    exit 0
fi

warn_once "llmtrim: daemon down" \
    "The proxy environment is set but the llmtrim daemon is not responding. Run: llmtrim start"
exit 0
