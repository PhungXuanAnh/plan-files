#!/usr/bin/env bash
set -u

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
BIND_TOOL="$REPO_ROOT/.codex/hooks/planning-with-files/scripts/bind-session.sh"
INPUT=$(cat)
CONTEXT=$(printf '%s' "$INPUT" \
    | bash "$REPO_ROOT/skills/planning-with-files/scripts/prompt-candidate.sh" codex "$BIND_TOOL")

if [ -z "$CONTEXT" ]; then
    printf '{}'
    exit 0
fi

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
