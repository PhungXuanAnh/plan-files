#!/bin/bash
# planning-with-files: Agent stop hook for GitHub Copilot
# Checks if all phases in task_plan.md are complete.
# Injects continuation context if phases are incomplete.
# Always exits 0 — outputs JSON to stdout. Debug log written to
#   tmp/hook-logs/plan-with-files/agent-stop.log

INPUT=$(cat)

# --- Resolve plan directory (see post-tool-use.sh for full doc) -------------
PLAN_DIR=""
PLAN_SOURCE=""
if [ -f .plan-with-files ]; then
    TASK_ID=$(head -n 1 .plan-with-files 2>/dev/null | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if printf '%s' "$TASK_ID" | grep -Eq '^[A-Za-z0-9._-]+$' && [ "$TASK_ID" != "." ] && [ "$TASK_ID" != ".." ]; then
        CANDIDATE="tmp/plan-with-files/$TASK_ID"
        if [ -d "$CANDIDATE" ]; then
            PLAN_DIR="$CANDIDATE"
            PLAN_SOURCE=".plan-with-files -> $CANDIDATE"
        else
            PLAN_SOURCE=".plan-with-files -> $CANDIDATE (DIR MISSING -> no-op)"
        fi
    else
        PLAN_SOURCE=".plan-with-files -> '$TASK_ID' (INVALID id -> no-op)"
    fi
else
    PLAN_SOURCE="no .plan-with-files pointer -> no-op"
fi
PLAN_FILE=""
[ -n "$PLAN_DIR" ] && PLAN_FILE="$PLAN_DIR/task_plan.md"

# --- Logging setup -----------------------------------------------------------
LOG_DIR="tmp/hook-logs/plan-with-files"
LOG_FILE="$LOG_DIR/agent-stop.log"
mkdir -p "$LOG_DIR" 2>/dev/null
# Rotate log: trigger at 3000 lines, keep last 2500 (hysteresis avoids per-call rotation)
LOG_MAX_LINES=3000
LOG_KEEP_LINES=2500
if [ -f "$LOG_FILE" ]; then
    _line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$_line_count" -gt "$LOG_MAX_LINES" ]; then
        tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
    fi
fi
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
log() { printf '[%s] %s\n' "$TS" "$1" >> "$LOG_FILE" 2>/dev/null; }

log "=== agent-stop ==="
log "cwd: $(pwd)"
log "plan source: $PLAN_SOURCE -> $PLAN_FILE"
INPUT_PREVIEW=$(printf '%s' "$INPUT" | tr '\n' ' ' | cut -c 1-300)
log "stdin (first 300 chars, ${#INPUT} total): $INPUT_PREVIEW"

if [ ! -f "$PLAN_FILE" ]; then
    log "${PLAN_FILE:-task_plan.md}: ABSENT -> emitting {} (no-op)"
    echo '{}'
    exit 0
fi
log "${PLAN_FILE}: present ($(wc -c < "$PLAN_FILE" | tr -d ' ') bytes)"

# Count total phases
TOTAL=$(grep -c "### Phase" "$PLAN_FILE" || true)

# Check for **Status:** format first
COMPLETE=$(grep -cF "**Status:** complete" "$PLAN_FILE" || true)
IN_PROGRESS=$(grep -cF "**Status:** in_progress" "$PLAN_FILE" || true)
PENDING=$(grep -cF "**Status:** pending" "$PLAN_FILE" || true)

FORMAT="Status:"
# Fallback: check for [complete] inline format
if [ "$COMPLETE" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ] && [ "$PENDING" -eq 0 ]; then
    COMPLETE=$(grep -c "\[complete\]" "$PLAN_FILE" || true)
    IN_PROGRESS=$(grep -c "\[in_progress\]" "$PLAN_FILE" || true)
    PENDING=$(grep -c "\[pending\]" "$PLAN_FILE" || true)
    FORMAT="[bracket]"
fi

: "${TOTAL:=0}"
: "${COMPLETE:=0}"
: "${IN_PROGRESS:=0}"
: "${PENDING:=0}"

log "format detected: $FORMAT"
log "phases: total=$TOTAL complete=$COMPLETE in_progress=$IN_PROGRESS pending=$PENDING"

# --- Remaining-in-current-phase snippet (count + first unchecked) ----------
PHASE_RAW=$(awk '
  /^## Current Phase[[:space:]]*$/ { capture=1; next }
  /^## / { capture=0 }
  capture { print }
' "$PLAN_FILE" 2>/dev/null | awk 'BEGIN{c=0} /<!--/{c=1} c==0{print} /-->/{c=0}' | sed -e '/./,$!d')
PHASE_NUM=$(printf '%s' "$PHASE_RAW" | grep -oE 'Phase [0-9]+' | head -1)
REMAINING_LINE=""
if [ -n "$PHASE_NUM" ]; then
    REMAINING=$(awk -v phase="$PHASE_NUM" '
      BEGIN { in_phase=0; in_comment=0; count=0; first="" }
      /<!--/ { in_comment=1 }
      in_comment { if (/-->/) in_comment=0; next }
      /^### / {
        if (in_phase) { exit }
        if ($0 ~ ("^### " phase "([: ]|$)")) in_phase=1
        next
      }
      !in_phase { next }
      /^- \[ \]/ {
        count++
        if (first=="") { first=$0; sub(/^- \[ \] */, "", first) }
      }
      END { printf "%d\t%s", count, first }
    ' "$PLAN_FILE" 2>/dev/null)
    REMAINING_COUNT=$(printf '%s' "$REMAINING" | cut -f1)
    REMAINING_FIRST=$(printf '%s' "$REMAINING" | cut -f2-)
    [ ${#REMAINING_FIRST} -gt 200 ] && REMAINING_FIRST="$(printf '%s' "$REMAINING_FIRST" | cut -c 1-200)..."
    if [ -n "$REMAINING_COUNT" ] && [ "$REMAINING_COUNT" -gt 0 ]; then
        REMAINING_LINE=" ${PHASE_NUM}: ${REMAINING_COUNT} unchecked item(s). First: ${REMAINING_FIRST}"
    fi
    log "remaining: count=${REMAINING_COUNT:-?}"
fi

if [ "$COMPLETE" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    MSG="[planning-with-files] ALL PHASES COMPLETE ($COMPLETE/$TOTAL). If the user has additional work, add new phases to ${PLAN_FILE} before starting."
    log "decision: ALL COMPLETE"
    PYTHON=$(command -v python3 || command -v python)
    ESCAPED=$(echo "$MSG" | $PYTHON -c "import sys,json; print(json.dumps(sys.stdin.read(), ensure_ascii=False))" 2>/dev/null || echo "\"\"")
    OUTPUT="{\"hookSpecificOutput\":{\"hookEventName\":\"AgentStop\",\"additionalContext\":$ESCAPED}}"
    log "stdout: ${#OUTPUT} chars"
    echo "$OUTPUT"
    exit 0
fi

MSG="[planning-with-files] Task incomplete ($COMPLETE/$TOTAL phases done).${REMAINING_LINE} Update progress.md, then read ${PLAN_FILE} and continue working on the remaining phases."
log "decision: INCOMPLETE"
PYTHON=$(command -v python3 || command -v python)
ESCAPED=$(echo "$MSG" | $PYTHON -c "import sys,json; print(json.dumps(sys.stdin.read(), ensure_ascii=False))" 2>/dev/null || echo "\"\"")
OUTPUT="{\"hookSpecificOutput\":{\"hookEventName\":\"AgentStop\",\"additionalContext\":$ESCAPED}}"
log "stdout: ${#OUTPUT} chars"
echo "$OUTPUT"
exit 0
