#!/usr/bin/env bash
# Translate a provider's verified session identity into the shared bind interface.

set -u

PROVIDER=${1:-}
REPO_ROOT=${2:-}
SESSION_ID=${3:-}
shift 3 2>/dev/null || exit 2
STATE_TOOL="$REPO_ROOT/skills/plan-files/scripts/session-state.sh"

if [ -z "$PROVIDER" ] || [ -z "$SESSION_ID" ]; then
    printf 'no verified session identity is available\n' >&2
    exit 1
fi

PWF_SESSION_ADAPTER="$PROVIDER" PWF_SESSION_ID="$SESSION_ID" exec bash "$STATE_TOOL" "$@"
