#!/bin/bash
# Restore trusted hot context for the pointer-selected Gemini task.

cat >/dev/null
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=planning-common.sh
source "$SCRIPT_DIR/planning-common.sh"
[ -f "$PLAN_FILE" ] || { echo '{}'; exit 0; }

CONTEXT=$(printf '[planning-with-files] Active task: %s\n\n=== tasks.md ===\n' "$TASK_ID"; sed -n '1,120p' "$PLAN_FILE"; if [ -f "$PLAN_DIR/decisions.md" ]; then printf '\n=== decisions.md ===\n'; sed -n '1,100p' "$PLAN_DIR/decisions.md"; fi)
HANDOFF_WARN=$(planning_handoff_warning "$PLAN_DIR")
if [ -f "$PLAN_DIR/handoff.md" ] && [ -z "$HANDOFF_WARN" ]; then
    CONTEXT="$CONTEXT

=== fresh handoff.md ===
$(sed -n '1,50p' "$PLAN_DIR/handoff.md")"
elif [ -n "$HANDOFF_WARN" ]; then
    CONTEXT="$CONTEXT

$HANDOFF_WARN"
fi
CONTEXT="$CONTEXT

[planning-with-files] Read the current findings summary and cold history only as needed."
ESCAPED=$(printf '%s' "$CONTEXT" | gemini_json_string)
echo "{\"hookSpecificOutput\":{\"additionalContext\":$ESCAPED}}"
exit 0
