#!/bin/bash
# Debounced Cursor reminder for the pointer-selected task.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=planning-common.sh
source "$SCRIPT_DIR/planning-common.sh"
[ -f "$PLAN_FILE" ] || exit 0

DEBOUNCE_SECS=60
TS_FILE="$PLAN_DIR/.cursor-hook-nudge-ts"
LOCK_FILE="$TS_FILE.lock"
EMIT=false
{
    flock -x 9 || true
    NOW=$(date +%s)
    LAST=0
    [ -f "$TS_FILE" ] && LAST=$(sed -n '1p' "$TS_FILE" 2>/dev/null || echo 0)
    LAST=${LAST:-0}
    if [ $((NOW - LAST)) -ge "$DEBOUNCE_SECS" ]; then
        EMIT=true
        printf '%s' "$NOW" > "$TS_FILE"
    fi
} 9>>"$LOCK_FILE" 2>/dev/null || true
[ "$EMIT" = "true" ] || exit 0

count_phases "$PLAN_FILE"
MESSAGE="[planning-with-files] Update $PLAN_FILE after meaningful progress and keep its Resume Checkpoint current."
BUDGET_WARN=$(planning_file_budget_warning "$PLAN_DIR")
HANDOFF_WARN=$(planning_handoff_warning "$PLAN_DIR")
FORMAT_ISSUE=$(check_task_plan_format "$PLAN_FILE")
FORMAT_WARN=$(task_plan_format_message "$FORMAT_ISSUE" "$PLAN_FILE" "$TOTAL")
[ -n "$BUDGET_WARN" ] && MESSAGE="$MESSAGE
$BUDGET_WARN"
[ -n "$HANDOFF_WARN" ] && MESSAGE="$MESSAGE
$HANDOFF_WARN"
[ -n "$FORMAT_WARN" ] && MESSAGE="$MESSAGE
[planning-with-files] $FORMAT_WARN"
printf '%s\n' "$MESSAGE"
exit 0
