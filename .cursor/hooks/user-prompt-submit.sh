#!/bin/bash
# Restore trusted hot context on each Cursor user prompt.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=planning-common.sh
source "$SCRIPT_DIR/planning-common.sh"
[ -f "$PLAN_FILE" ] || exit 0

printf '[planning-with-files] Active task: %s\n\n=== tasks.md (hot state) ===\n' "$TASK_ID"
sed -n '1,120p' "$PLAN_FILE"
if [ -f "$PLAN_DIR/decisions.md" ]; then
    printf '\n=== decisions.md ===\n'
    sed -n '1,100p' "$PLAN_DIR/decisions.md"
fi

HANDOFF_WARN=$(planning_handoff_warning "$PLAN_DIR")
if [ -f "$PLAN_DIR/handoff.md" ] && [ -z "$HANDOFF_WARN" ]; then
    printf '\n=== fresh handoff.md ===\n'
    sed -n '1,50p' "$PLAN_DIR/handoff.md"
elif [ -n "$HANDOFF_WARN" ]; then
    printf '\n%s\n' "$HANDOFF_WARN"
fi

printf '\n[planning-with-files] Read the current summary in findings.md and cold history only as needed.\n'
exit 0
