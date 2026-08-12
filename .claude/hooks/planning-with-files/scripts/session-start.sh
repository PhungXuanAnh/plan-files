#!/usr/bin/env bash
# Persist Claude's hook session id for later Bash-based plan binding.

set -u

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
STATE_TOOL="$REPO_ROOT/skills/planning-with-files/scripts/session-state.sh"
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | "$STATE_TOOL" session-id 2>/dev/null || true)

if [ -n "$SESSION_ID" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    {
        printf 'export PWF_SESSION_ADAPTER=claude\n'
        printf 'export PWF_SESSION_ID=%s\n' "$SESSION_ID"
    } >> "$CLAUDE_ENV_FILE"
fi

printf '{}'
