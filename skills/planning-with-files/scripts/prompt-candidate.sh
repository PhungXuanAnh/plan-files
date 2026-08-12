#!/usr/bin/env bash
# Suspend any prior lease and print candidate identity for an adapter to wrap.

set -u
set -o pipefail 2>/dev/null || true

ADAPTER_ID=${1:-}
BIND_TOOL=${2:-}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE_TOOL="$SCRIPT_DIR/session-state.sh"
INPUT=$(cat)

if [ -z "$ADAPTER_ID" ] || [ ! -x "$BIND_TOOL" ] \
    || [ "${PLANNING_DISABLED:-0}" = "1" ] || [ -e .plan-with-files-skip ]; then
    exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | "$STATE_TOOL" session-id 2>/dev/null || true)
if [ -z "$SESSION_ID" ]; then
    exit 0
fi

CANDIDATE=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" pending "$ADAPTER_ID" "$SESSION_ID" 2>/dev/null || true)
if [ -z "$CANDIDATE" ]; then
    exit 0
fi

CONTEXT=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" candidate-context "$CANDIDATE" "$BIND_TOOL" 2>/dev/null || true)
if [ -z "$CONTEXT" ]; then
    exit 0
fi

printf '%s' "$CONTEXT"
