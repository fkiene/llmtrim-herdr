#!/bin/sh
# herdr-rpc.sh - minimal JSON-over-socket client for the herdr plugin socket.
#
# Transport: AF_UNIX stream socket at $HERDR_SOCKET_PATH. The herdr server reads
# one newline-terminated JSON request per write and replies with newline-delimited
# JSON (src/api/server.rs). The Windows named-pipe path lives in the .ps1 twin.
#
# Sourced API:  herdr_rpc <method> <params-json>
#   prints the response "result" as JSON on success (exit 0);
#   prints "herdr-rpc: ..." to stderr and returns non-zero on transport/RPC error.
#
# CLI:  herdr-rpc.sh <method> <params-json>   (same behavior; for tests)
#
# Requires python3 (guaranteed by the plugin's documented prerequisites). No
# socat/nc/jq dependency, and never bash /dev/tcp (TCP only, not unix sockets).

herdr_rpc() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "herdr-rpc: python3 is required but not found in PATH" >&2
        return 1
    fi
    # Temp vars are intentionally not `local` (not POSIX); the _hr_ prefix avoids
    # collisions with the sibling scripts that source this file.
    _hr_method="$1"
    _hr_params="${2:-{\}}"
    if [ -z "$_hr_method" ]; then
        echo "herdr-rpc: method is required" >&2
        return 2
    fi
    # Default-expand: callers run under `set -u`, where a bare unset reference is a
    # fatal error that aborts the whole hook (their `|| true` cannot catch it).
    if [ -z "${HERDR_SOCKET_PATH:-}" ]; then
        echo "herdr-rpc: HERDR_SOCKET_PATH is unset (not running under herdr?)" >&2
        return 1
    fi
    HERDR_RPC_METHOD="$_hr_method" HERDR_RPC_PARAMS="$_hr_params" python3 - <<'PY'
import json, os, socket, sys, uuid

path = os.environ["HERDR_SOCKET_PATH"]
method = os.environ["HERDR_RPC_METHOD"]
params_raw = os.environ.get("HERDR_RPC_PARAMS") or "{}"

try:
    params = json.loads(params_raw)
except json.JSONDecodeError as exc:
    print(f"herdr-rpc: invalid params JSON: {exc}", file=sys.stderr)
    sys.exit(2)

req = {"id": uuid.uuid4().hex, "method": method, "params": params}

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(path)
    sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
        # Bound the response: a legit pane.report_metadata reply is a few bytes.
        # Cap it so a misbehaving/hijacked socket can't flood us into OOM.
        if len(buf) > 65536:
            print("herdr-rpc: response too large", file=sys.stderr)
            sys.exit(1)
    sock.close()
except OSError as exc:
    print(f"herdr-rpc: socket error: {exc}", file=sys.stderr)
    sys.exit(1)

line = buf.split(b"\n", 1)[0].decode("utf-8", errors="replace")
if not line:
    print("herdr-rpc: empty response from herdr", file=sys.stderr)
    sys.exit(1)

try:
    resp = json.loads(line)
except json.JSONDecodeError as exc:
    print(f"herdr-rpc: malformed response: {exc}", file=sys.stderr)
    sys.exit(1)

err = resp.get("error")
if err:
    print(f"herdr-rpc: rpc error {err.get('code')}: {err.get('message')}", file=sys.stderr)
    sys.exit(1)

print(json.dumps(resp.get("result")))
PY
}

# Execute directly (not sourced) -> CLI mode.
case "${0##*/}" in
herdr-rpc.sh)
    herdr_rpc "$@"
    ;;
esac
