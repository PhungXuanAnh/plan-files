#!/bin/bash
# planning-with-files: Error hook for GitHub Copilot
# Logs errors to tasks.md when the agent encounters an error.
# Always exits 0 — outputs JSON to stdout. Debug log written to
#   tmp/hook-logs/plan-with-files/error-occurred.log
#
# Pure bash (no python dependency). Tested on bash 4+ (Ubuntu/Debian/Arch).

set -u
set -o pipefail 2>/dev/null || true

INPUT=$(cat)

# --- Early skip: hooks only run when a real task pointer is present ---------
# Skip silently (emit `{}` and exit 0) if ANY of the following is true:
#   1. `.plan-with-files-skip` marker file exists at CWD (manual opt-out)
#   2. `.plan-with-files` pointer file is missing
#   3. `.plan-with-files` pointer file is empty (whitespace-only counts as empty)
# This makes the pointer file the explicit opt-in: worktrees, worktree-
# container workspaces, and unrelated projects all stay silent.
if [ -e .plan-with-files-skip ] \
    || [ ! -f .plan-with-files ] \
    || [ -z "$(tr -d '[:space:]' < .plan-with-files 2>/dev/null)" ]; then
    printf '{}'
    exit 0
fi

# --- JSON escape (bash-only, no python) -------------------------------------
json_escape() {
    local s=${1:-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '"%s"' "$s"
}

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
[ -n "$PLAN_DIR" ] && PLAN_FILE="$PLAN_DIR/tasks.md"

# --- Logging setup (flock-protected against parallel hook processes) --------
LOG_DIR="tmp/hook-logs/plan-with-files"
LOG_FILE="$LOG_DIR/error-occurred.log"
LOG_LOCK="$LOG_FILE.lock"
LOG_MAX_LINES=3000
LOG_KEEP_LINES=2500
mkdir -p "$LOG_DIR" 2>/dev/null || true

{
    flock -x 9 || true
    if [ -f "$LOG_FILE" ]; then
        _line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "${_line_count:-0}" -gt "$LOG_MAX_LINES" ]; then
            tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null \
                && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
        fi
    fi
} 9>>"$LOG_LOCK" 2>/dev/null || true

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
log() {
    local msg=${1:-}
    {
        flock -x 9 || true
        printf '[%s] %s\n' "$TS" "$msg" >> "$LOG_FILE"
    } 9>>"$LOG_LOCK" 2>/dev/null || true
}

log "=== error-occurred ==="
log "cwd: $(pwd)"
log "plan source: $PLAN_SOURCE -> $PLAN_FILE"
INPUT_PREVIEW=$(printf '%s' "$INPUT" | tr '\n' ' ' | cut -c 1-500)
log "stdin (first 500 chars, ${#INPUT} total): $INPUT_PREVIEW"

if [ ! -f "$PLAN_FILE" ]; then
    log "${PLAN_FILE:-tasks.md}: ABSENT -> emitting {} (no-op)"
    echo '{}'
    exit 0
fi
log "${PLAN_FILE}: present"

# --- Extract error message from input JSON (bash-only) ----------------------
# Two shapes accepted:
#   {"error":{"message":"..."}}  -> nested
#   {"error":"..."}              -> top-level string
# Limitation: does NOT decode escaped quotes inside the message (\" mid-value
# would split early). Acceptable for a 200-char preview that is itself meant
# only to nudge the agent to log the error in tasks.md.
ERROR_MSG=$(printf '%s' "$INPUT" \
    | grep -oE '"message"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 \
    | sed -E 's/^"message"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)
if [ -z "${ERROR_MSG:-}" ]; then
    ERROR_MSG=$(printf '%s' "$INPUT" \
        | grep -oE '"error"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed -E 's/^"error"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)
fi
ERROR_MSG=${ERROR_MSG:0:200}

if [ -n "${ERROR_MSG:-}" ]; then
    log "extracted error.message (truncated to 200): $ERROR_MSG"
    CONTEXT="[planning-with-files] Error detected: ${ERROR_MSG}. Log this error in ${PLAN_FILE} under Errors Encountered with the attempt number and resolution."
    ESCAPED=$(json_escape "$CONTEXT")
    OUTPUT="{\"hookSpecificOutput\":{\"hookEventName\":\"ErrorOccurred\",\"additionalContext\":$ESCAPED}}"
    log "stdout: ${#OUTPUT} chars"
    echo "$OUTPUT"
else
    log "no error.message found in stdin -> emitting {}"
    echo '{}'
fi

exit 0
