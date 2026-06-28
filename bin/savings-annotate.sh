#!/bin/sh
# savings-annotate.sh - per-workspace live token-savings poller.
#
# Long-running process forked by bootstrap.sh on workspace.created.
# Every POLL_SECS seconds: reads `llmtrim status --json`, builds a badge
# string, and pushes it via pane.report_metadata (custom_status field).
#
# Lifecycle:
#   Start: bootstrap.sh forks this script and records $! in the pid file.
#          Do NOT write the pid file here -- that creates a double-writer race.
#   Stop:  stop-annotate.sh (workspace.closed) kills by pid file.
#   Reap:  bootstrap.sh matches "savings-annotate" in `ps -p PID -o args=`
#          before killing a stale instance -- do NOT exec another program
#          (that replaces the process image and breaks the ps match).
#
# Failures are always silent: every iteration is wrapped so a bad parse,
# an RPC error, or a transient llmtrim hiccup never kills the loop.
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/herdr-rpc.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

POLL_SECS=20
# ttl_ms must exceed the poll interval; 5 s of headroom keeps the badge from
# vanishing between polls under transient slowness.
TTL_MS=25000

# ---------------------------------------------------------------------------
# Resolve llmtrim once (PATH-hijack guard)
# ---------------------------------------------------------------------------

LLMTRIM=$(command -v llmtrim 2>/dev/null || true)
if [ -z "$LLMTRIM" ]; then
    # llmtrim absent -- bootstrap already notified the user; exit cleanly.
    exit 0
fi

# ---------------------------------------------------------------------------
# Pane ID
#
# Inherited from bootstrap's hook environment ($HERDR_PANE_ID = the focused
# pane when workspace.created fired). It can become stale if that pane closes;
# every RPC call is best-effort (|| true) so a stale id is harmless.
# ---------------------------------------------------------------------------

PANE_ID="${HERDR_PANE_ID:-}"

# ---------------------------------------------------------------------------
# Badge builder
#
# Three cases:
#   (1) daemon absent / stopped  ->  "llmtrim: off"
#   (2) daemon up, cost null     ->  "llmtrim -NN%"   (gross saved_pct; never
#                                    labelled "net" -- that would be dishonest)
#   (3) daemon up, cost present  ->  "llmtrim -NN% net"  (round_trip_pct,
#                                    the honest net-of-cache figure)
#
# The cross-cutting "honest savings" rule forbids showing .cost.round_trip_pct
# when .cost is null and forbids labelling .input.saved_pct as "net".
# ---------------------------------------------------------------------------

_build_badge() {
    # $1 is the PATH to a JSON file, never the JSON itself.  The JSON can be
    # several megabytes; passing it via env/argv would hit the ARG_MAX / execve
    # E2BIG limit.  A file path is always short and safe in an env var.
    _BADGE_PATH="$1" python3 - <<'PY'
import json, os, re, sys

path = os.environ.get("_BADGE_PATH", "")
try:
    with open(path) as _f:
        d = json.load(_f)
except Exception:
    print("llmtrim: --")
    sys.exit(0)

# Case (1): daemon absent or not running.
daemon = d.get("daemon")
if daemon is None:
    print("llmtrim: off")
    sys.exit(0)

running = False
if daemon.get("running") is not None:
    running = bool(daemon["running"])
elif daemon.get("health") not in (None, "stopped", "degraded"):
    running = True

if not running:
    print("llmtrim: off")
    sys.exit(0)

# Case (3): cost present with round_trip_pct -> honest net figure.
# Only claim a reduction when it rounds to a positive whole percent: "-0%"
# would assert savings of zero, which the honest-figure rule forbids.
cost = d.get("cost")
if cost is not None:
    pct = cost.get("round_trip_pct")
    if pct is not None:
        val = int(round(float(pct)))
        if val > 0:
            badge = "llmtrim -{}% net".format(val)
            badge = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", badge)[:80]
            print(badge)
            sys.exit(0)

# Case (2): cost null -- show gross saved_pct without "net" label.
inp = d.get("input") or {}
saved = inp.get("saved_pct")
if saved is not None and int(round(float(saved))) > 0:
    val = int(round(float(saved)))
    badge = "llmtrim -{}%".format(val)
else:
    badge = "llmtrim: --"

badge = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", badge)[:80]
print(badge)
PY
}

# ---------------------------------------------------------------------------
# Main poll loop
# ---------------------------------------------------------------------------

# Belt-and-suspenders cleanup. _json_file is assigned inside the loop, so use
# ${_json_file:-} to avoid an unbound-variable error under set -u before the
# first assignment completes.
trap 'rm -f "${_json_file:-}"' EXIT INT TERM

while :; do
    # Wrap the full iteration body. A parse error, RPC failure, or transient
    # llmtrim problem must never exit the loop.
    #
    # Write the (potentially multi-megabyte) JSON to a temp file rather than
    # capturing it into a shell variable and passing it to python3 via an env
    # var.  Env + argv share the ARG_MAX limit (~2 MB); a 5-6 MB status payload
    # causes execve to fail with E2BIG, which was causing the badge to always
    # fall back to "llmtrim: --".  Shell variables and files are not subject to
    # ARG_MAX; only the handoff to a child process is.
    _json_file=$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/llmtrim_badge_$$.json")
    "$LLMTRIM" status --json 2>/dev/null > "$_json_file" || printf '{}' > "$_json_file"
    _badge=$(_build_badge "$_json_file" 2>/dev/null || echo "llmtrim: --")
    rm -f "$_json_file"

    if [ -n "$PANE_ID" ]; then
        # JSON is built with jq --arg so the badge value is properly escaped
        # regardless of what characters it contains (cross-cutting no-interpolation rule).
        herdr_rpc pane.report_metadata \
            "$(jq -n \
                --arg  pane_id       "$PANE_ID" \
                --arg  source        "llmtrim" \
                --arg  custom_status "$_badge" \
                --argjson ttl_ms     "$TTL_MS" \
                '{pane_id:$pane_id,source:$source,custom_status:$custom_status,ttl_ms:$ttl_ms}')" \
            >/dev/null 2>&1 || true
    fi

    sleep "$POLL_SECS"
done
