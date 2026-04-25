#!/bin/bash
# planning-with-files: Agent stop hook for GitHub Copilot
# Checks if all phases in task_plan.md are complete.
# Injects continuation context if phases are incomplete.
# Always exits 0 — outputs JSON to stdout. Debug log written to
#   tmp/hook-logs/plan-with-files/agent-stop.log
#
# Pure bash (no python dependency). Tested on bash 4+ (Ubuntu/Debian/Arch).

set -u
set -o pipefail 2>/dev/null || true

INPUT=$(cat)

# --- JSON escape (bash-only, no python) -------------------------------------
# Handles: backslash, double-quote, tab, CR, LF. Sufficient for our use case
# where strings come from plan files + hook-generated messages (no embedded
# control chars beyond whitespace).
json_escape() {
    local s=${1:-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '"%s"' "$s"
}

# --- Safe match counters (grep -c returns 1 on zero matches, breaking $((..))) -
gcount()  { local n; n=$(grep -c  "$1" "$2" 2>/dev/null || true); printf '%d' "${n:-0}"; }
gcountF() { local n; n=$(grep -cF "$1" "$2" 2>/dev/null || true); printf '%d' "${n:-0}"; }

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

# --- Logging setup (flock-protected against parallel hook processes) --------
LOG_DIR="tmp/hook-logs/plan-with-files"
LOG_FILE="$LOG_DIR/agent-stop.log"
LOG_LOCK="$LOG_FILE.lock"
LOG_MAX_LINES=3000
LOG_KEEP_LINES=2500
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Rotate ONCE at start, inside the lock — concurrent hook processes won't
# both truncate the same file.
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

log "=== agent-stop ==="
log "cwd: $(pwd)"
log "plan source: $PLAN_SOURCE -> $PLAN_FILE"
INPUT_PREVIEW=$(printf '%s' "$INPUT" | tr '\n' ' ' | cut -c 1-300)
log "stdin (first 300 chars, ${#INPUT} total): $INPUT_PREVIEW"

# --- stop_hook_active guard --------------------------------------------------
# Per docs: if we previously blocked the Stop and the agent is now stopping
# again (after running our reason), `stop_hook_active=true` is set in stdin.
# We MUST emit {} in that case to avoid an infinite loop that burns premium
# requests. Pure-grep parse: matches `"stop_hook_active": true` with optional
# whitespace and a non-letter trailer (so `truthy`/`truely` won't false-match).
if printf '%s' "$INPUT" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true([^a-zA-Z]|$)'; then
    STOP_HOOK_ACTIVE=true
else
    STOP_HOOK_ACTIVE=false
fi
log "stop_hook_active: $STOP_HOOK_ACTIVE"
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    log "decision: GUARDED (stop_hook_active=true) -> emitting {} to break loop"
    echo '{}'
    exit 0
fi

if [ ! -f "$PLAN_FILE" ]; then
    log "${PLAN_FILE:-task_plan.md}: ABSENT -> emitting {} (no-op)"
    echo '{}'
    exit 0
fi
log "${PLAN_FILE}: present ($(wc -c < "$PLAN_FILE" | tr -d ' ') bytes)"

# --- Phase counting (unified: sum BOTH `**Status:**` and `[bracket]` formats) -
# Plan files MAY use either format or mix them; previous logic only counted
# the bracket form when Status form had zero matches, which under-counted
# mixed files. Summing is safe because the two markers are disjoint.
TOTAL=$(gcount "^### Phase" "$PLAN_FILE")
COMPLETE=$((    $(gcountF "**Status:** complete"    "$PLAN_FILE") + $(gcountF "[complete]"    "$PLAN_FILE") ))
IN_PROGRESS=$(( $(gcountF "**Status:** in_progress" "$PLAN_FILE") + $(gcountF "[in_progress]" "$PLAN_FILE") ))
PENDING=$((     $(gcountF "**Status:** pending"     "$PLAN_FILE") + $(gcountF "[pending]"     "$PLAN_FILE") ))

log "phases: total=$TOTAL complete=$COMPLETE in_progress=$IN_PROGRESS pending=$PENDING"

# --- Remaining-in-current-phase snippet (count + first unchecked) ----------
PHASE_RAW=$(awk '
  /^## Current Phase[[:space:]]*$/ { capture=1; next }
  /^## / { capture=0 }
  capture { print }
' "$PLAN_FILE" 2>/dev/null | awk 'BEGIN{c=0} /<!--/{c=1} c==0{print} /-->/{c=0}' | sed -e '/./,$!d')
PHASE_NUM=$(printf '%s' "$PHASE_RAW" | grep -oE 'Phase [0-9]+' | head -1 || true)
REMAINING_LINE=""
if [ -n "${PHASE_NUM:-}" ]; then
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
    if [ -n "${REMAINING_COUNT:-}" ] && [ "$REMAINING_COUNT" -gt 0 ]; then
        REMAINING_LINE=" ${PHASE_NUM}: ${REMAINING_COUNT} unchecked item(s). First: ${REMAINING_FIRST}"
    fi
    log "remaining: count=${REMAINING_COUNT:-?}"
fi

if [ "$COMPLETE" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    # All phases done -> let the agent stop normally. No block, no message.
    log "decision: ALL COMPLETE -> emitting {} (allow stop)"
    echo '{}'
    exit 0
fi

# Task incomplete -> BLOCK the stop and tell the agent why to continue.
# Per docs (https://code.visualstudio.com/docs/copilot/customization/hooks#_stop):
#   hookEventName must be exactly "Stop"; use decision="block" + reason
#   (additionalContext does NOT apply to Stop hooks).
REASON="[planning-with-files] Task incomplete ($COMPLETE/$TOTAL phases done).${REMAINING_LINE} Update progress.md, then read ${PLAN_FILE} and continue working on the remaining phases. If you genuinely cannot continue (blocked / waiting on user), say so explicitly so the user can intervene."
log "decision: BLOCK ($COMPLETE/$TOTAL phases done)"
ESCAPED_REASON=$(json_escape "$REASON")
OUTPUT="{\"hookSpecificOutput\":{\"hookEventName\":\"Stop\",\"decision\":\"block\",\"reason\":$ESCAPED_REASON}}"
log "stdout: ${#OUTPUT} chars"
echo "$OUTPUT"
exit 0
