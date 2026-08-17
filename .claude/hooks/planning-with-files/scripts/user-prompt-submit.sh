#!/usr/bin/env bash
set -u

REPO_ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
BIND_TOOL="$REPO_ROOT/.claude/hooks/planning-with-files/scripts/bind-session.sh"
INPUT=$(cat)
LOG_DIR="tmp/hook-logs/plan-with-files"
LOG_FILE="$LOG_DIR/user-prompt-submit.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
printf '[%s] event=UserPromptSubmit provider=claude input_bytes=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${#INPUT}" >> "$LOG_FILE" 2>/dev/null || true
CONTEXT=$(printf '%s' "$INPUT" \
    | bash "$REPO_ROOT/skills/planning-with-files/scripts/prompt-candidate.sh" claude "$BIND_TOOL")

if [ -z "$CONTEXT" ]; then
    printf '[%s] candidate=none\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$LOG_FILE" 2>/dev/null || true
    printf '{}'
    exit 0
fi

printf '[%s] candidate_context=emitted\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$LOG_FILE" 2>/dev/null || true

json_escape() {
    local value=${1:-}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\t'/\\t}
    value=${value//$'\r'/\\r}
    value=${value//$'\n'/\\n}
    printf '"%s"' "$value"
}

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}' \
    "$(json_escape "$CONTEXT")"
