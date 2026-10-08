#!/bin/bash
# Check if all phases in the authoritative plan are complete
# Always exits 0 — uses stdout for status reporting
# Used by Stop hook to report task completion status

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
PLAN_FILE="${1:-$(planning_plan_file "$PWD")}"

if [ ! -f "$PLAN_FILE" ]; then
    echo "[plan-files] No plan.md or legacy tasks.md found - no active planning session."
    exit 0
fi

# Count total phases
TOTAL=$(grep -c "### Phase" "$PLAN_FILE" || true)

# Check for **Status:** format first
COMPLETE=$(grep -cF "**Status:** complete" "$PLAN_FILE" || true)
IN_PROGRESS=$(grep -cF "**Status:** in_progress" "$PLAN_FILE" || true)
PENDING=$(grep -cF "**Status:** pending" "$PLAN_FILE" || true)
# Blocked: only count when "(non-empty reason)" is present.
BLOCKED=$(grep -cE '\*\*Status:\*\*[[:space:]]*blocked[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)' "$PLAN_FILE" || true)
# Deferred: only count when "(non-empty reason)" is present.
DEFERRED=$(grep -cE '\*\*Status:\*\*[[:space:]]*deferred[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)' "$PLAN_FILE" || true)

# Default to 0 if empty
: "${TOTAL:=0}"
: "${COMPLETE:=0}"
: "${IN_PROGRESS:=0}"
: "${PENDING:=0}"
: "${BLOCKED:=0}"
: "${DEFERRED:=0}"

SETTLED=$((COMPLETE + BLOCKED + DEFERRED))

# Report status (always exit 0 — incomplete task is a normal state)
if [ "$SETTLED" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    if [ "$BLOCKED" -gt 0 ] || [ "$DEFERRED" -gt 0 ]; then
        echo "[plan-files] ALL PHASES SETTLED ($COMPLETE complete + $BLOCKED blocked + $DEFERRED deferred / $TOTAL). If the user has additional work, add new phases to $PLAN_FILE before starting."
    else
        echo "[plan-files] ALL PHASES COMPLETE ($COMPLETE/$TOTAL). If the user has additional work, add new phases to $PLAN_FILE before starting."
    fi
else
    echo "[plan-files] Task in progress ($SETTLED/$TOTAL phases settled - $COMPLETE complete, $BLOCKED blocked, $DEFERRED deferred). Update $PLAN_FILE before stopping."
    if [ "$IN_PROGRESS" -gt 0 ]; then
        echo "[plan-files] $IN_PROGRESS phase(s) still in progress."
    fi
    if [ "$PENDING" -gt 0 ]; then
        echo "[plan-files] $PENDING phase(s) pending."
    fi
fi
exit 0
