#!/usr/bin/env bash
# Translate this host's tool-session environment into the shared bind interface.

set -u

REPO_ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
STATE_TOOL="$REPO_ROOT/skills/plan-files/scripts/session-state.sh"
SESSION_ID=${PWF_SESSION_ID:-}

if [ -z "$SESSION_ID" ]; then
    printf 'no verified session identity is available\n' >&2
    exit 1
fi

PWF_SESSION_ADAPTER=claude PWF_SESSION_ID="$SESSION_ID" exec bash "$STATE_TOOL" "$@"
