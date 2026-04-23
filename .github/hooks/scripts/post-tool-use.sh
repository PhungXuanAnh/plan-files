#!/bin/bash
# planning-with-files: Post-tool-use hook for GitHub Copilot
# Runs AFTER every tool call. Anchors goals (re-injecting Goal + Current Phase
# from task_plan.md, size-bounded per section) and nudges progress logging.
# No-op when task_plan.md does not exist - zero pollution on non-planning sessions.
# Always exits 0 - outputs JSON to stdout. Debug log written to
#   tmp/hook-logs/plan-with-files/post-tool-use.log

INPUT=$(cat)

# --- Resolve plan directory --------------------------------------------------
# Strict resolution: requires `.plan-with-files` pointer (workspace root) whose
# first line is a task id, e.g.
#   $ cat .plan-with-files
#   JIRA-1234
# -> hook reads tmp/plan-with-files/JIRA-1234/task_plan.md
# If pointer missing / invalid / target dir missing -> no-op (zero pollution).
# The planning-with-files skill is responsible for creating both the pointer
# and the per-task directory; hooks never write files.
PLAN_DIR=""
PLAN_SOURCE=""
if [ -f .plan-with-files ]; then
    TASK_ID=$(head -n 1 .plan-with-files 2>/dev/null | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # whitelist: alnum, dash, underscore, dot; reject empty / .. / path separators
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
LOG_FILE="$LOG_DIR/post-tool-use.log"
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

log "=== post-tool-use ==="
log "cwd: $(pwd)"
log "plan source: $PLAN_SOURCE -> $PLAN_FILE"
INPUT_PREVIEW=$(printf '%s' "$INPUT" | tr '\n' ' ' | cut -c 1-300)
log "stdin (first 300 chars, ${#INPUT} total): $INPUT_PREVIEW"

if [ ! -f "$PLAN_FILE" ]; then
    log "${PLAN_FILE:-task_plan.md}: ABSENT -> emitting {} (no-op, zero pollution)"
    echo '{}'
    exit 0
fi
PLAN_BYTES=$(wc -c < "$PLAN_FILE" | tr -d ' ')
log "${PLAN_FILE}: present (${PLAN_BYTES} bytes)"

# Per-section hard caps. Prevents runaway model verbosity from inflating
# per-tool-call cost while preserving BOTH sections (the previous combined
# 800-char cap could starve Current Phase if Goal exhausted the budget).
MAX_GOAL_CHARS=700      # ~100 words / 2-3 sentences
MAX_PHASE_CHARS=100     # ~15 words; Current Phase is meant to be a label
TRUNC_MARKER="[truncated by post-tool-use hook — full text in ${PLAN_FILE}; this section is too long for per-call injection, consider shortening it there]"

extract_section() {
    awk -v name="$1" '
      $0 ~ "^## " name "[[:space:]]*$" { capture=1; next }
      /^## / { capture=0 }
      capture { print }
    ' "$PLAN_FILE" 2>/dev/null \
      | awk 'BEGIN{c=0} /<!--/{c=1} c==0{print} /-->/{c=0}' \
      | sed -e '/./,$!d' \
      | awk 'NF { last=NR } { lines[NR]=$0 } END { for (i=1;i<=last;i++) print lines[i] }'
}

cap() {
    local text="$1"; local max="$2"; local label="$3"
    if [ ${#text} -gt $max ]; then
        log "$label: ${#text} chars -> TRUNCATED to $max"
        printf '%s\n%s' "$(printf '%s' "$text" | cut -c 1-$max)" "$TRUNC_MARKER"
    else
        log "$label: ${#text} chars (within cap $max)"
        printf '%s' "$text"
    fi
}

GOAL_RAW=$(extract_section 'Goal')
PHASE_RAW=$(extract_section 'Current Phase')
log "extracted Goal: ${#GOAL_RAW} chars; Current Phase: ${#PHASE_RAW} chars"

GOAL_BODY=$(cap "$GOAL_RAW" $MAX_GOAL_CHARS "Goal")
PHASE_BODY=$(cap "$PHASE_RAW" $MAX_PHASE_CHARS "Current Phase")

# --- Remaining-in-phase snippet (cheap: count + first unchecked item) -------
# Extracts phase label from "## Current Phase" body, locates "### <Phase N>"
# block in the plan, counts `- [ ]` lines, and captures the first one.
# Output is a single line appended to the nudge — anti-substitution reminder
# without per-call inflation. Caps first-item at 200 chars.
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
        if (first=="") {
          first=$0
          sub(/^- \[ \] */, "", first)
        }
      }
      END { printf "%d\t%s", count, first }
    ' "$PLAN_FILE" 2>/dev/null)
    REMAINING_COUNT=$(printf '%s' "$REMAINING" | cut -f1)
    REMAINING_FIRST=$(printf '%s' "$REMAINING" | cut -f2-)
    if [ ${#REMAINING_FIRST} -gt 200 ]; then
        REMAINING_FIRST="$(printf '%s' "$REMAINING_FIRST" | cut -c 1-200)..."
    fi
    if [ -n "$REMAINING_COUNT" ] && [ "$REMAINING_COUNT" -eq 0 ]; then
        REMAINING_LINE="${PHASE_NUM}: 0 unchecked items in this phase — if all 'Done when' criteria genuinely verified (see anti-substitution rule), mark phase complete."
    elif [ -n "$REMAINING_COUNT" ] && [ "$REMAINING_COUNT" -gt 0 ]; then
        REMAINING_LINE="${PHASE_NUM}: ${REMAINING_COUNT} unchecked item(s). First: ${REMAINING_FIRST}"
    fi
    log "remaining: count=${REMAINING_COUNT:-?} first(${#REMAINING_FIRST} chars)"
fi

PLAN_SUMMARY=""
if [ -n "$GOAL_BODY" ]; then
    PLAN_SUMMARY="## Goal
${GOAL_BODY}"
fi
if [ -n "$PHASE_BODY" ]; then
    if [ -n "$PLAN_SUMMARY" ]; then
        PLAN_SUMMARY="${PLAN_SUMMARY}

## Current Phase
${PHASE_BODY}"
    else
        PLAN_SUMMARY="## Current Phase
${PHASE_BODY}"
    fi
fi

NUDGE="[planning-with-files] Update progress.md with what you just did. If a phase is now complete, update ${PLAN_FILE} status. If you no longer see the planning-with-files SKILL.md rules in your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing."
if [ -n "$REMAINING_LINE" ]; then
    NUDGE="${NUDGE}
${REMAINING_LINE}"
fi

if [ -n "$PLAN_SUMMARY" ]; then
    CONTEXT="=== Current task (Goal + Current Phase from ${PLAN_FILE}) ===
${PLAN_SUMMARY}

${NUDGE}"
else
    CONTEXT="$NUDGE"
fi

log "additionalContext: ${#CONTEXT} chars"
log "--- additionalContext begin ---"
printf '%s\n' "$CONTEXT" >> "$LOG_FILE" 2>/dev/null
log "--- additionalContext end ---"

PYTHON=$(command -v python3 || command -v python)
ESCAPED=$(echo "$CONTEXT" | $PYTHON -c "import sys,json; print(json.dumps(sys.stdin.read(), ensure_ascii=False))" 2>/dev/null || echo "\"\"")

OUTPUT="{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":$ESCAPED}}"
log "stdout: ${#OUTPUT} chars"
echo "$OUTPUT"
exit 0
