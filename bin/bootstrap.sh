#!/bin/sh
# bootstrap.sh - workspace.created hook.
#
# Idempotent. Wires routing (llmtrim setup), starts the daemon, discloses once
# (re-fires only when setup actually changed the CA), and launches the
# per-workspace savings poller. Never blocks herdr: every failure path exits 0.
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/herdr-rpc.sh"

STATE="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}"
# Sanitize anything that lands in a state filename: strip path separators and
# other surprises so $WS/$HOST can never traverse out of $STATE.
HOST=$(hostname 2>/dev/null | tr -dc 'A-Za-z0-9._-' || true)
[ -n "$HOST" ] || HOST=unknown
WS=$(printf '%s' "${HERDR_WORKSPACE_ID:-default}" | tr -dc 'A-Za-z0-9._-')
[ -n "$WS" ] || WS=default
mkdir -p "$STATE" 2>/dev/null || true

notify() { # title, body  -- best effort, never blocks
    herdr_rpc notification.show \
        "$(jq -n --arg t "$1" --arg b "$2" '{title:$t, body:$b}')" \
        >/dev/null 2>&1 || true
}

# Resolve llmtrim once (PATH-hijack guard); if absent, point the user at install.
LLMTRIM=$(command -v llmtrim 2>/dev/null || true)
if [ -z "$LLMTRIM" ]; then
    notify "llmtrim not found" \
        "Install llmtrim and relaunch herdr to enable token-cost compression."
    exit 0
fi

CA="${LLMTRIM_HOME:-$HOME/.llmtrim}/ca.pem"
SENTINEL="$STATE/disclosure_shown.$HOST"

ca_fingerprint() {
    if [ -f "$CA" ]; then cksum "$CA" 2>/dev/null | cut -d' ' -f1; else echo none; fi
}

# Idempotent wiring + daemon start. Capture the CA fingerprint across setup so a
# regenerated CA (real, security-relevant change) re-fires the disclosure.
before=$(ca_fingerprint)
"$LLMTRIM" setup >/dev/null 2>&1 || true
"$LLMTRIM" start >/dev/null 2>&1 || true
after=$(ca_fingerprint)

if [ ! -f "$SENTINEL" ] || [ "$before" != "$after" ]; then
    herdr_rpc plugin.pane.open \
        "$(jq -n --arg pid "llmtrim.proxy" --arg ep "welcome" \
            '{plugin_id:$pid, entrypoint:$ep}')" >/dev/null 2>&1 || true
    notify "llmtrim is active" \
        "Agent HTTPS now routes through a local proxy that reads traffic in plaintext to compress it. Details and undo are in the llmtrim setup pane."
    printf '%s\n' "$after" > "$SENTINEL" 2>/dev/null || true
fi

# Per-workspace savings poller: reap any stale one, then fork a fresh poller with
# stdio fully detached (herdr does not reap the process group, but the hook's
# pipe-reader threads block until the inherited stdout/stderr FDs are released).
PIDF="$STATE/$WS.poller.pid"
if [ -f "$PIDF" ]; then
    oldpid=$(cat "$PIDF" 2>/dev/null | tr -dc '0-9' || true)
    # Only signal it if it is still OUR poller: a bare PID can have been recycled
    # to an unrelated process. Match the command line before killing.
    if [ -n "$oldpid" ] && ps -p "$oldpid" -o args= 2>/dev/null | grep -q savings-annotate; then
        kill "$oldpid" 2>/dev/null || true
    fi
    rm -f "$PIDF" 2>/dev/null || true
fi
if [ -x "$SELF_DIR/savings-annotate.sh" ]; then
    "$SELF_DIR/savings-annotate.sh" >/dev/null 2>&1 </dev/null &
    # Record the child PID synchronously here so stop-annotate and the next
    # bootstrap can always find it (no race waiting for the poller to self-write).
    echo $! > "$PIDF" 2>/dev/null || true
fi

exit 0
