#!/usr/bin/env bash
# Grok-only envelope/session normalization; planning policy stays in shared cores.

GROK_ADAPTER_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GROK_REPO_ROOT=$(CDPATH= cd -P -- "$GROK_ADAPTER_DIR/../../../.." && pwd)

grok_input_has_verified_session() {
    [ -n "${GROK_SESSION_ID:-}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    GROK_EXPECTED_SESSION_ID="$GROK_SESSION_ID" python3 -c 'import json, os, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
value = None
if isinstance(payload, dict):
    value = payload.get("sessionId") or payload.get("session_id")
raise SystemExit(0 if isinstance(value, str) and value == os.environ["GROK_EXPECTED_SESSION_ID"] else 1)'
}

grok_input_string() {
    local camel=${1:-} snake=${2:-}
    GROK_INPUT_CAMEL="$camel" GROK_INPUT_SNAKE="$snake" python3 -c 'import json, os, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
value = payload.get(os.environ["GROK_INPUT_CAMEL"])
if value is None and os.environ["GROK_INPUT_SNAKE"]:
    value = payload.get(os.environ["GROK_INPUT_SNAKE"])
if isinstance(value, str):
    sys.stdout.write(value)'
}
