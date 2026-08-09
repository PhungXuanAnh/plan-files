#!/bin/bash
# Shared pointer resolution and JSON escaping for Gemini hooks.

HOOK_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$HOOK_DIR/../.." && pwd)"
# shellcheck source=../../.codex/hooks/planning-with-files/scripts/common.sh
source "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/common.sh"

PROJECT_ROOT="${GEMINI_PROJECT_DIR:-$REPO_ROOT}"
resolve_plan_dir "$PROJECT_ROOT"

gemini_json_string() {
    local _python
    _python=$(command -v python3 || command -v python || true)
    if [ -n "$_python" ]; then
        "$_python" -c 'import json,sys; print(json.dumps(sys.stdin.read(), ensure_ascii=False))'
        return
    fi
    local _value
    _value=$(cat)
    _value=${_value//\\/\\\\}
    _value=${_value//\"/\\\"}
    _value=${_value//$'\t'/\\t}
    _value=${_value//$'\r'/\\r}
    _value=${_value//$'\n'/\\n}
    printf '"%s"' "$_value"
}
