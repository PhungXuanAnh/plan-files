#!/bin/bash
# planning-with-files: Error hook for GitHub Copilot
# Logs errors to task_plan.md when the agent encounters an error.
# Always exits 0 — outputs JSON to stdout. Debug log written to
#   tmp/hook-logs/plan-with-files/error-occurred.log

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
LOG_FILE="$LOG_DIR/error-occurred.log"
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

log "=== error-occurred ==="
log "cwd: $(pwd)"
log "plan source: $PLAN_SOURCE -> $PLAN_FILE"
INPUT_PREVIEW=$(printf '%s' "$INPUT" | tr '\n' ' ' | cut -c 1-500)
log "stdin (first 500 chars, ${#INPUT} total): $INPUT_PREVIEW"

if [ ! -f "$PLAN_FILE" ]; then
    log "${PLAN_FILE:-task_plan.md}: ABSENT -> emitting {} (no-op)"
    echo '{}'
    exit 0
fi
log "${PLAN_FILE}: present"

# Extract error message from input JSON
PYTHON=$(command -v python3 || command -v python)
ERROR_MSG=$($PYTHON -c "
import sys, json
try:
    data = json.load(sys.stdin)
    msg = data.get('error', {}).get('message', '') if isinstance(data.get('error'), dict) else str(data.get('error', ''))
    print(msg[:200])
except:
    print('')
" <<< "$INPUT" 2>/dev/null || echo "")

if [ -n "$ERROR_MSG" ]; then
    log "extracted error.message (truncated to 200): $ERROR_MSG"
    CONTEXT="[planning-with-files] Error detected: ${ERROR_MSG}. Log this error in ${PLAN_FILE} under Errors Encountered with the attempt number and resolution."
    ESCAPED=$($PYTHON -c "import sys,json; print(json.dumps(sys.stdin.read(), ensure_ascii=False))" <<< "$CONTEXT" 2>/dev/null || echo "\"\"")
    OUTPUT="{\"hookSpecificOutput\":{\"hookEventName\":\"ErrorOccurred\",\"additionalContext\":$ESCAPED}}"
    log "stdout: ${#OUTPUT} chars"
    echo "$OUTPUT"
else
    log "no error.message found in stdin -> emitting {}"
    echo '{}'
fi

exit 0
