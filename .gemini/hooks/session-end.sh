#!/bin/bash
# Report incomplete or malformed pointer-selected Gemini tasks at session end.

cat >/dev/null
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=planning-common.sh
source "$SCRIPT_DIR/planning-common.sh"
[ -f "$PLAN_FILE" ] || { echo '{}'; exit 0; }

count_phases "$PLAN_FILE"
FORMAT_ISSUE=$(check_task_plan_format "$PLAN_FILE")
if [ -n "$FORMAT_ISSUE" ]; then
    RESULT="[planning-with-files] $(task_plan_format_message "$FORMAT_ISSUE" "$PLAN_FILE" "$TOTAL") Fix it before ending the task."
else
    NON_PHASE_HEADING=$(check_non_phase_work "$PLAN_FILE")
    if [ -n "$NON_PHASE_HEADING" ]; then
        RESULT="[planning-with-files] Move unchecked work under '$NON_PHASE_HEADING' into a valid '### Phase N: Title' block before ending the task."
    else
        STATUS_LIE=""
        while IFS=$'\t' read -r NUM STATUS UNCHECKED FIRST; do
            if [ "$STATUS" = "complete" ] && [ "${UNCHECKED:-0}" -gt 0 ]; then
                STATUS_LIE="Phase $NUM is complete but still has $UNCHECKED unchecked item(s). Finish them or reopen/split the phase."
                break
            fi
        done <<< "$(phase_summary "$PLAN_FILE")"

        SETTLED=$((COMPLETE + DEFERRED))
        if [ -n "$STATUS_LIE" ]; then
            RESULT="[planning-with-files] $STATUS_LIE"
        elif [ "$SETTLED" -ge "$TOTAL" ]; then
            echo '{}'
            exit 0
        elif [ "$COMPLETE" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ] && [ "$DEFERRED" -eq 0 ]; then
            echo '{}'
            exit 0
        else
            CURRENT_BODY=$(current_phase_pointer "$PLAN_FILE")
            CURRENT_NUM=${CURRENT_BODY#Phase }
            CURRENT_STATUS=$(phase_summary "$PLAN_FILE" | awk -F '\t' -v num="$CURRENT_NUM" '$1 == num { print $2; exit }')
            if [ "$CURRENT_STATUS" = "complete" ] || [ "$CURRENT_STATUS" = "deferred" ]; then
                RESULT="[planning-with-files] STALE Current Phase in $PLAN_FILE: $CURRENT_BODY is $CURRENT_STATUS while work remains. Point it at the next incomplete phase and continue."
            else
                RESULT="[planning-with-files] Active task '$TASK_ID' is incomplete. Update its Resume Checkpoint and continue. If the user explicitly requested a pause or an external blocker prevents progress, refresh optional handoff.md after the required planning files and defer only with an allowed explicit reason."
            fi
        fi
    fi
fi

ESCAPED=$(printf '%s' "$RESULT" | gemini_json_string)
echo "{\"systemMessage\":$ESCAPED}"
exit 0
