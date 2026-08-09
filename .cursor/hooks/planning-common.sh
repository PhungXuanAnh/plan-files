#!/bin/bash
# Shared pointer resolution and JSON escaping for Cursor hooks.

HOOK_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$HOOK_DIR/../.." && pwd)"
# shellcheck source=../../.codex/hooks/planning-with-files/scripts/common.sh
source "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/common.sh"

PROJECT_ROOT="${CURSOR_PROJECT_DIR:-$PWD}"
[ -f "$PROJECT_ROOT/.plan-with-files" ] || PROJECT_ROOT="$REPO_ROOT"
resolve_plan_dir "$PROJECT_ROOT"

cursor_json_string() {
    local _value="${1:-}"
    _value=${_value//\\/\\\\}
    _value=${_value//\"/\\\"}
    _value=${_value//$'\t'/\\t}
    _value=${_value//$'\r'/\\r}
    _value=${_value//$'\n'/\\n}
    printf '"%s"' "$_value"
}
