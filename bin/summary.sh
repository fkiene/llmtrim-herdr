#!/bin/sh
# summary.sh - action: fire a notification.show with the current session savings.
#
# Parses `llmtrim status --json` with the same honest-savings logic as
# savings-annotate.sh (off / net / gross / --), then calls notification.show.
# Actions may exit non-zero on failure; errors are printed to stderr.
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/herdr-rpc.sh"

# Resolve llmtrim once (PATH-hijack guard).
LLMTRIM=$(command -v llmtrim 2>/dev/null || true)
if [ -z "$LLMTRIM" ]; then
    echo "llmtrim: binary not found in PATH" >&2
    exit 1
fi

# Write the (potentially multi-megabyte) JSON to a temp file. Passing it via
# an env var would hit the ARG_MAX / execve E2BIG limit on real machines,
# causing python3 to always fall through to the safe "Session: --" sentinel.
_json_file=$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/llmtrim_summary_$$.json")
trap 'rm -f "${_json_file:-}"' EXIT INT TERM
"$LLMTRIM" status --json 2>/dev/null > "$_json_file" || printf '{}' > "$_json_file"

# Parse with python3 using the same honest-savings logic as savings-annotate.sh.
# Pass the PATH via _SUMMARY_JSON_PATH; python3 prints exactly two lines:
#   line 1 -> notification title
#   line 2 -> notification body
_OUT=$(_SUMMARY_JSON_PATH="$_json_file" python3 - <<'PY'
import json, os, sys

path = os.environ.get("_SUMMARY_JSON_PATH", "")
try:
    with open(path) as _f:
        d = json.load(_f)
except Exception:
    print("llmtrim savings")
    print("Session: --")
    sys.exit(0)

TITLE = "llmtrim savings"

# Case (1): daemon absent or not running.
daemon = d.get("daemon")
if daemon is None:
    print(TITLE)
    print("Proxy is not running.")
    sys.exit(0)

running = False
if daemon.get("running") is not None:
    running = bool(daemon["running"])
elif daemon.get("health") not in (None, "stopped", "degraded"):
    running = True

if not running:
    print(TITLE)
    print("Proxy is not running.")
    sys.exit(0)

# Case (3): cost present with round_trip_pct -> honest net-of-cache figure.
cost = d.get("cost")
if cost is not None:
    pct = cost.get("round_trip_pct")
    if pct is not None:
        val = int(round(float(pct)))
        if val > 0:
            net_usd = cost.get("net_saved_usd")
            if net_usd is not None:
                body = "Session: -{}% net  (net saved ${:.2f})".format(val, float(net_usd))
            else:
                body = "Session: -{}% net".format(val)
            print(TITLE)
            print(body)
            sys.exit(0)

# Case (2): cost null -- show gross saved_pct without "net" label.
inp = d.get("input") or {}
saved = inp.get("saved_pct")
if saved is not None and int(round(float(saved))) > 0:
    val = int(round(float(saved)))
    body = "Session: -{}%  (gross input)".format(val)
else:
    body = "Session: --"

print(TITLE)
print(body)
PY
)
rm -f "$_json_file"

_TITLE=$(printf '%s\n' "$_OUT" | head -n1)
_BODY=$(printf '%s\n' "$_OUT" | tail -n +2)

herdr_rpc notification.show \
    "$(jq -n --arg t "$_TITLE" --arg b "$_BODY" '{title:$t, body:$b}')" \
    >/dev/null
