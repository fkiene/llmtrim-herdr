#!/bin/sh
# open-dashboard.sh - action: open (or focus) the llmtrim live savings dashboard.
#
# Calls plugin.pane.open via the herdr RPC helper to surface the "dashboard"
# pane (id "dashboard", running `llmtrim status`).  Actions may exit
# non-zero on failure; errors are printed to stderr.
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/herdr-rpc.sh"

herdr_rpc plugin.pane.open \
    "$(jq -n \
        --arg plugin_id "llmtrim.proxy" \
        --arg entrypoint "dashboard" \
        '{plugin_id:$plugin_id, entrypoint:$entrypoint}')" >/dev/null
