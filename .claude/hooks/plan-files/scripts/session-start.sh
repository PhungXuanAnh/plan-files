#!/usr/bin/env bash
# Persist Claude's hook session id for later Bash-based plan binding.

set -u

REPO_ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
STATE_TOOL="$REPO_ROOT/skills/plan-files/scripts/session-state.sh"
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | "$STATE_TOOL" session-id 2>/dev/null || true)

if [ -n "$SESSION_ID" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    # Every shell inherits these, including other agents it launches; the host
    # pid lets their planning helpers ignore an identity that is not their own.
    HOST_PID=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from session_runtime import host_agent; print(host_agent()[1] or "")' \
        "$REPO_ROOT/skills/plan-files/scripts" 2>/dev/null || true)
    {
        printf 'export PWF_SESSION_ADAPTER=claude\n'
        printf 'export PWF_SESSION_ID=%s\n' "$SESSION_ID"
        [ -z "$HOST_PID" ] || printf 'export PWF_SESSION_OWNER=%s:%s\n' "$HOST_PID" "$SESSION_ID"
    } >> "$CLAUDE_ENV_FILE"
fi

printf '{}'
