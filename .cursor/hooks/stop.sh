#!/bin/bash
# Cursor stop gate for the pointer-selected task.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=planning-common.sh
source "$SCRIPT_DIR/planning-common.sh"
[ -f "$PLAN_FILE" ] || exit 0

follow_up() {
    printf '{"followup_message":%s}\n' "$(cursor_json_string "$1")"
}

count_phases "$PLAN_FILE"
FORMAT_ISSUE=$(check_task_plan_format "$PLAN_FILE")
if [ -n "$FORMAT_ISSUE" ]; then
    follow_up "[planning-with-files] $(task_plan_format_message "$FORMAT_ISSUE" "$PLAN_FILE" "$TOTAL") Fix it before stopping."
    exit 0
fi

NON_PHASE_HEADING=$(check_non_phase_work "$PLAN_FILE")
if [ -n "$NON_PHASE_HEADING" ]; then
    follow_up "[planning-with-files] Move unchecked work under '$NON_PHASE_HEADING' into a valid '### Phase N: Title' block before stopping."
    exit 0
fi

while IFS=$'\t' read -r NUM STATUS UNCHECKED FIRST; do
    if [ "$STATUS" = "complete" ] && [ "${UNCHECKED:-0}" -gt 0 ]; then
        follow_up "[planning-with-files] Phase $NUM is complete but still has $UNCHECKED unchecked item(s). Finish them or reopen/split the phase."
        exit 0
    fi
done <<< "$(phase_summary "$PLAN_FILE")"

SETTLED=$((COMPLETE + DEFERRED))
[ "$SETTLED" -ge "$TOTAL" ] && exit 0
[ "$COMPLETE" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ] && [ "$DEFERRED" -eq 0 ] && exit 0

CURRENT_BODY=$(current_phase_pointer "$PLAN_FILE")
CURRENT_NUM=${CURRENT_BODY#Phase }
CURRENT_STATUS=$(phase_summary "$PLAN_FILE" | awk -F '\t' -v num="$CURRENT_NUM" '$1 == num { print $2; exit }')
if [ "$CURRENT_STATUS" = "complete" ] || [ "$CURRENT_STATUS" = "deferred" ]; then
    follow_up "[planning-with-files] STALE Current Phase in $PLAN_FILE: $CURRENT_BODY is $CURRENT_STATUS while work remains. Point it at the next incomplete phase and continue."
    exit 0
fi

follow_up "[planning-with-files] Task incomplete ($SETTLED/$TOTAL phases settled). Update the Resume Checkpoint in $PLAN_FILE and continue. If the user explicitly requested a pause or an external blocker prevents progress, refresh optional handoff.md after the required planning files and defer only with an allowed explicit reason."
exit 0
