#!/usr/bin/env bash
# Stable compatibility entrypoint; session policy lives in the shared Python core.
set -eu
SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$SCRIPT_DIR/session_state.py" "$@"
