#!/bin/bash
# planning-with-files: Stop hook for Cursor
# Checks if all phases in task_plan.md are complete.
# Returns followup_message to auto-continue if phases are incomplete.
# Always exits 0 — uses JSON stdout for control.

PLAN_FILE="task_plan.md"

if [ ! -f "$PLAN_FILE" ]; then
    # No plan file = no planning session, allow stop
    exit 0
fi

# Phase counting (scoped to `### Phase` blocks; at most 1 status per phase).
# Avoids false `COMPLETE > TOTAL` when status-looking lines appear OUTSIDE
# any phase section (e.g. summary blocks). HTML comments are ignored.
read TOTAL COMPLETE IN_PROGRESS PENDING <<EOF
$(awk '
  function flush() {
    if (in_phase) {
      if      (status == "complete")    complete++
      else if (status == "in_progress") in_progress++
      else if (status == "pending")     pending++
    }
  }
  BEGIN { total=0; complete=0; in_progress=0; pending=0; in_phase=0; status=""; in_comment=0 }
  /<!--/ { in_comment=1 }
  in_comment { if (/-->/) in_comment=0; next }
  /^### Phase/ {
    flush(); in_phase=1; total++; status=""
    if      ($0 ~ /\[complete\]/)    status="complete"
    else if ($0 ~ /\[in_progress\]/) status="in_progress"
    else if ($0 ~ /\[pending\]/)     status="pending"
    next
  }
  /^### / || /^## / { flush(); in_phase=0; status=""; next }
  !in_phase { next }
  status != "" { next }
  /\*\*Status:\*\*[[:space:]]*complete([^a-zA-Z_]|$)/    { status="complete";    next }
  /\*\*Status:\*\*[[:space:]]*in_progress([^a-zA-Z_]|$)/ { status="in_progress"; next }
  /\*\*Status:\*\*[[:space:]]*pending([^a-zA-Z_]|$)/     { status="pending";     next }
  /\[complete\]/    { status="complete";    next }
  /\[in_progress\]/ { status="in_progress"; next }
  /\[pending\]/     { status="pending";     next }
  END { flush(); printf "%d %d %d %d", total, complete, in_progress, pending }
' "$PLAN_FILE" 2>/dev/null)
EOF
: "${TOTAL:=0}" "${COMPLETE:=0}" "${IN_PROGRESS:=0}" "${PENDING:=0}"

if [ "$TOTAL" -eq 0 ]; then
    # No `### Phase` headings -> nothing to gate on. Allow stop.
    exit 0
fi

if [ "$COMPLETE" -ge "$TOTAL" ]; then
    # All phases complete — provide re-entry guidance
    echo "{\"followup_message\": \"[planning-with-files] ALL PHASES COMPLETE ($COMPLETE/$TOTAL). If the user has additional work, add new phases to task_plan.md before starting.\"}"
    exit 0
else
    # Phases incomplete — auto-continue via followup_message
    echo "{\"followup_message\": \"[planning-with-files] Task incomplete ($COMPLETE/$TOTAL phases done). Update progress.md, then read task_plan.md and continue working on the remaining phases.\"}"
    exit 0
fi
