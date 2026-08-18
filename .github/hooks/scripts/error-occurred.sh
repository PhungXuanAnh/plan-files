#!/bin/bash
# planning-with-files: Error hook for GitHub Copilot
# Logs errors to tasks.md when the agent encounters an error.
# Always exits 0 — outputs JSON to stdout. Debug log written to
#   tmp/hook-logs/plan-with-files/error-occurred.log
#
# Bash 4+ hook; session JSON uses jq, Python 3, or Node and otherwise fails closed.

set -u
set -o pipefail 2>/dev/null || true

INPUT=$(cat)
PROVIDER=copilot
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
STATE_TOOL="$REPO_ROOT/skills/planning-with-files/scripts/session-state.sh"

# Copilot invokes this script directly with whatever cwd the editor last set,
# with no wrapper to correct it first. A submodule's own toplevel is not the
# workspace root, so cd out to the outermost superproject before any relative
# path below (the skip marker, log files, $PWD passed to session-state.sh) is
# used — otherwise a cwd inside a submodule silently misses the session lease.
cd "$(bash "$REPO_ROOT/skills/planning-with-files/scripts/resolve-project-root.sh")" 2>/dev/null || true

if [ "${PLANNING_DISABLED:-0}" = "1" ] || [ -e .plan-with-files-skip ]; then
    printf '{}'
    exit 0
fi
SESSION_ID=$(printf '%s' "$INPUT" | "$STATE_TOOL" session-id 2>/dev/null || true)
PLAN_DIR=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" resolve "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)
if [ -z "$PLAN_DIR" ]; then
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

PLAN_SOURCE="$PROVIDER session lease -> $PLAN_DIR"
PLAN_FILE="$PLAN_DIR/tasks.md"

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
