#!/bin/bash
# Remind Gemini to maintain the pointer-selected task after writes.

cat >/dev/null
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=planning-common.sh
source "$SCRIPT_DIR/planning-common.sh"
[ -f "$PLAN_FILE" ] || { echo '{}'; exit 0; }

count_phases "$PLAN_FILE"
MESSAGE="[planning-with-files] Update $PLAN_FILE after meaningful progress and keep its Resume Checkpoint current."
for WARNING in \
    "$(planning_file_budget_warning "$PLAN_DIR")" \
    "$(planning_handoff_warning "$PLAN_DIR")" \
    "$(task_plan_format_message "$(check_task_plan_format "$PLAN_FILE")" "$PLAN_FILE" "$TOTAL")"; do
    [ -n "$WARNING" ] && MESSAGE="$MESSAGE
$WARNING"
done
ESCAPED=$(printf '%s' "$MESSAGE" | gemini_json_string)
echo "{\"additionalContext\":$ESCAPED}"
exit 0
