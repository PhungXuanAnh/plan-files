#!/usr/bin/env bash
set -u

PROVIDER=${1:-}
REPO_ROOT=${2:-}
BIND_TOOL=${3:-}
[ -n "$PROVIDER" ] && [ -d "$REPO_ROOT/skills/plan-files/scripts" ] && [ -x "$BIND_TOOL" ] \
    || { printf '{}'; exit 0; }
INPUT=$(cat)
LOG_DIR="tmp/hook-logs/plan-files"
LOG_FILE="$LOG_DIR/user-prompt-submit.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
printf '[%s] event=UserPromptSubmit provider=%s input_bytes=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$PROVIDER" "${#INPUT}" >> "$LOG_FILE" 2>/dev/null || true
CONTEXT=$(printf '%s' "$INPUT" \
    | bash "$REPO_ROOT/skills/plan-files/scripts/prompt-candidate.sh" "$PROVIDER" "$BIND_TOOL")

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
