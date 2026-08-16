#!/bin/bash
# planning-with-files: Agent stop hook for Codex
# Checks if all phases in tasks.md are complete.
# Injects continuation context if phases are incomplete.
# Always exits 0 — outputs JSON to stdout. Debug log written to
#   tmp/hook-logs/plan-with-files/agent-stop.log
#
# Bash 4+ hook; session JSON uses jq, Python 3, or Node and otherwise fails closed.

set -u
set -o pipefail 2>/dev/null || true

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INPUT=$(cat)
PROVIDER=codex
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
STATE_TOOL="$REPO_ROOT/skills/planning-with-files/scripts/session-state.sh"

json_escape() {
    local s=${1:-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '"%s"' "$s"
}

# Ownership enforcement happens at UserPromptSubmit + PreToolUse. Stop only
# checks completion state for an owned session.
if [ "${PLANNING_DISABLED:-0}" = "1" ] || [ -e .plan-with-files-skip ]; then
    printf '{}'
    exit 0
fi
SESSION_ID=$(printf '%s' "$INPUT" | "$STATE_TOOL" session-id 2>/dev/null || true)
PLAN_DIR=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" resolve "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)
if [ -z "$PLAN_DIR" ]; then
    CANDIDATE=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" pending-candidate "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)
    if [ -n "$CANDIDATE" ]; then
        REASON="[planning-with-files] OWNERSHIP ACTION REQUIRED before stopping. Candidate '$CANDIDATE' is still pending. Do not stop or report a blocker. Run the provided bind or release command from the ownership prompt, then continue."
        ESCAPED_REASON=$(json_escape "$REASON")
        printf '{"decision":"block","reason":%s}' "$ESCAPED_REASON"
        exit 0
    fi
    printf '{}'
    exit 0
fi

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

PLAN_SOURCE="$PROVIDER session lease -> $PLAN_DIR"
PLAN_FILE="$PLAN_DIR/tasks.md"

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

if [ ! -f "$PLAN_FILE" ]; then
    log "${PLAN_FILE:-tasks.md}: ABSENT -> emitting {} (no-op)"
    echo '{}'
    exit 0
fi
log "${PLAN_FILE}: present ($(wc -c < "$PLAN_FILE" | tr -d ' ') bytes)"

# --- Phase counting (delegated to common.sh:count_phases) ------------------
count_phases "$PLAN_FILE"
log "phases: total=$TOTAL complete=$COMPLETE in_progress=$IN_PROGRESS pending=$PENDING deferred=$DEFERRED"

# --- Remaining-in-current-phase snippet (count + first unchecked) ----------
PHASE_RAW=$(current_phase_pointer "$PLAN_FILE")
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

# --- Format / Workflow-Profile checks (delegated to common.sh) -------------
FORMAT_ISSUE=$(check_task_plan_format "$PLAN_FILE")
case "${FORMAT_ISSUE:-}" in
    SECTION_LAYOUT_INVALID|CURRENT_PHASE_INVALID|PHASE_HEADING_INVALID|PHASE_STATUS_INVALID)
        REASON="[planning-with-files] $(task_plan_format_message "$FORMAT_ISSUE" "$PLAN_FILE" "$TOTAL") Fix the plan structure, then continue."
        log "decision: BLOCK ($FORMAT_ISSUE)"
        ESCAPED_REASON=$(json_escape "$REASON")
        OUTPUT="{\"decision\":\"block\",\"reason\":$ESCAPED_REASON}"
        echo "$OUTPUT"
        exit 0
        ;;
    NO_PHASES)
        REASON="[planning-with-files] FORMAT CONTRACT VIOLATION in ${PLAN_FILE}: 0 phases detected. Required heading format is exactly '### Phase N: Title' (level-3, colon, no decorations, no backticks), and each phase MUST end with a line '- **Status:** pending|in_progress|complete'. See skills/planning-with-files/SKILL.md > FORMAT CONTRACT. Fix the plan file headings/status markers, then continue."
        log "decision: BLOCK (FORMAT CONTRACT — TOTAL=0)"
        ESCAPED_REASON=$(json_escape "$REASON")
        OUTPUT="{\"decision\":\"block\",\"reason\":$ESCAPED_REASON}"
        log "stdout: ${#OUTPUT} chars"
        echo "$OUTPUT"
        exit 0
        ;;
    DEFERRED_NO_REASON)
        REASON="[planning-with-files] FORMAT CONTRACT VIOLATION in ${PLAN_FILE}: a phase has '**Status:** deferred' but is missing the REQUIRED parenthesised reason. The only valid form is '- **Status:** deferred (explicit reason)' where the reason names the blocker — e.g. '- **Status:** deferred (blocked by upstream API change)' or '- **Status:** deferred (user asked to split into follow-up PR)'. Bare 'deferred', 'deferred ()', or vague reasons like '(later)' / '(skipped)' are NOT accepted. Do NOT use 'deferred' to silence the stop hook after a transient error — use the 3-strike protocol and escalate to the user instead. See skills/planning-with-files/SKILL.md > FORMAT CONTRACT > Phase status."
        log "decision: BLOCK (DEFERRED_NO_REASON)"
        ESCAPED_REASON=$(json_escape "$REASON")
        OUTPUT="{\"decision\":\"block\",\"reason\":$ESCAPED_REASON}"
        log "stdout: ${#OUTPUT} chars"
        echo "$OUTPUT"
        exit 0
        ;;
    PROFILE_MISSING)
        REASON="[planning-with-files] MISSING SECTION in ${PLAN_FILE}: '## Workflow Profile' not found. This section is REQUIRED before implementation begins. It declares the agent handoff point: Profile A = PR-Handoff (stop after CI green), B = Staging-Verified (stop after staging E2E), C = Research/Document (no code/PR). Add it between '## Current Phase' and '## Phases', with '**Profile:** A' (or B or C) filled in. See skills/planning-with-files/SKILL.md > Workflow Profile."
        log "decision: BLOCK (Workflow Profile section absent, COMPLETE=0)"
        ESCAPED_REASON=$(json_escape "$REASON")
        OUTPUT="{\"decision\":\"block\",\"reason\":$ESCAPED_REASON}"
        log "stdout: ${#OUTPUT} chars"
        echo "$OUTPUT"
        exit 0
        ;;
    PROFILE_UNFILLED)
        REASON="[planning-with-files] UNFILLED SECTION in ${PLAN_FILE}: '## Workflow Profile' found but **Profile:** is not set to A, B, or C (placeholder still present or missing). Replace the '[A | B | C]' placeholder with exactly one letter: A (PR-Handoff — stop after CI green + reviewers), B (Staging-Verified — stop after staging E2E passes), or C (Research/Document — deliverable file complete). See skills/planning-with-files/SKILL.md > Workflow Profile."
        log "decision: BLOCK (Workflow Profile unfilled, COMPLETE=0)"
        ESCAPED_REASON=$(json_escape "$REASON")
        OUTPUT="{\"decision\":\"block\",\"reason\":$ESCAPED_REASON}"
        log "stdout: ${#OUTPUT} chars"
        echo "$OUTPUT"
        exit 0
        ;;
esac

# --- Status-integrity checks (run regardless of COMPLETE count) ------------
# Catches two classes of "the agent stopped too early" bug:
#   (A) A phase marked **Status:** complete still has "- [ ]" items inside it.
#       The phase counter trusts the status marker, so unchecked sub-tasks are
#       invisible to the gate. Block until either the boxes are checked or the
#       remaining work is split into a new ### Phase with status pending.
#       Note: `deferred` phases are EXEMPT — their unchecked items are
#       expected (the whole point of deferred is "we are not doing this now").
#   (B) ## Current Phase points at a phase whose status is already complete
#       (or deferred) while other phases are still pending/in_progress. The
#       hook keeps injecting the wrong phase context and the agent loses
#       track. Block until ## Current Phase is advanced to a non-settled phase.
SUMMARY=$(phase_summary "$PLAN_FILE")
LIE_PHASE=""
LIE_COUNT=0
LIE_FIRST=""
while IFS=$'\t' read -r _num _status _unchecked _first; do
    [ -z "${_num:-}" ] && continue
    if [ "${_status:-}" = "complete" ] && [ "${_unchecked:-0}" -gt 0 ]; then
        LIE_PHASE="Phase ${_num}"
        LIE_COUNT="${_unchecked}"
        LIE_FIRST="${_first}"
        break
    fi
done <<< "$SUMMARY"

if [ -n "$LIE_PHASE" ]; then
    REASON="[planning-with-files] STATUS LIES in ${PLAN_FILE}: ${LIE_PHASE} is marked '**Status:** complete' but still has ${LIE_COUNT} unchecked '- [ ]' item(s). First: ${LIE_FIRST} | Either (a) finish the items and check the boxes, or (b) demote the phase to '**Status:** in_progress' and update '## Current Phase' to ${LIE_PHASE}, or (c) split the remaining items into a new '### Phase N+1: ...' with '**Status:** pending'. Do not stop with unchecked items inside a 'complete' phase."
    log "decision: BLOCK (STATUS LIES — ${LIE_PHASE} complete with ${LIE_COUNT} unchecked)"
    ESCAPED_REASON=$(json_escape "$REASON")
    OUTPUT="{\"decision\":\"block\",\"reason\":$ESCAPED_REASON}"
    log "stdout: ${#OUTPUT} chars"
    echo "$OUTPUT"
    exit 0
fi

# Stale Current Phase: pointer references a phase whose status is settled
# (complete OR deferred), AND there is at least one non-settled phase remaining.
# Only fires if the user actually filled in ## Current Phase (PHASE_NUM non-empty).
if [ -n "${PHASE_NUM:-}" ] && [ $((COMPLETE + DEFERRED)) -lt "$TOTAL" ]; then
    CURRENT_NUM=$(printf '%s' "$PHASE_NUM" | grep -oE '[0-9]+' | head -1)
    CURRENT_STATUS=""
    NEXT_INCOMPLETE=""
    while IFS=$'\t' read -r _num _status _unchecked _first; do
        [ -z "${_num:-}" ] && continue
        if [ "$_num" = "$CURRENT_NUM" ]; then
            CURRENT_STATUS="${_status:-}"
        fi
        if [ -z "$NEXT_INCOMPLETE" ] && [ "${_status:-}" != "complete" ] && [ "${_status:-}" != "deferred" ]; then
            NEXT_INCOMPLETE="Phase ${_num}"
        fi
    done <<< "$SUMMARY"

    if { [ "$CURRENT_STATUS" = "complete" ] || [ "$CURRENT_STATUS" = "deferred" ]; } && [ -n "$NEXT_INCOMPLETE" ]; then
        REASON="[planning-with-files] STALE '## Current Phase' in ${PLAN_FILE}: it points at ${PHASE_NUM} which is already '**Status:** ${CURRENT_STATUS}', but ${NEXT_INCOMPLETE} (and possibly later phases) are not settled. Update the '## Current Phase' section to '${NEXT_INCOMPLETE}' and set its status to 'in_progress' before continuing. The hook injects context based on Current Phase — leaving it on a finished/deferred phase makes the agent work on the wrong target."
        log "decision: BLOCK (STALE Current Phase — points at ${CURRENT_STATUS} ${PHASE_NUM}, next incomplete is ${NEXT_INCOMPLETE})"
        ESCAPED_REASON=$(json_escape "$REASON")
        OUTPUT="{\"decision\":\"block\",\"reason\":$ESCAPED_REASON}"
        log "stdout: ${#OUTPUT} chars"
        echo "$OUTPUT"
        exit 0
    fi
fi

# --- Non-Phase work check (delegated to common.sh:check_non_phase_work) ----
# Catches the bypass pattern where the agent invents `### Step N:` /
# `### Task N:` / `### Stage N:` headings to hide unchecked work from the
# `^### Phase` scanner. Runs regardless of COMPLETE/TOTAL so it also fires
# when Phase 0..N are all marked complete and the remaining work was renamed
# to a non-Phase heading underneath. Heading-only sections (Rollback, Open
# question, etc.) are not flagged — only ones containing `- [ ]` items.
NON_PHASE_HEADING=$(check_non_phase_work "$PLAN_FILE")
if [ -n "$NON_PHASE_HEADING" ]; then
    REASON="[planning-with-files] FORMAT CONTRACT VIOLATION in ${PLAN_FILE}: heading '### ${NON_PHASE_HEADING}' contains unchecked '- [ ]' work items but is NOT a recognized phase heading. The ONLY heading form recognized as work is '### Phase N: Title' (level-3, the literal word 'Phase', a number, a colon). 'Step', 'Task', 'Stage', 'Iteration', 'Milestone', etc. are NOT accepted — they hide work from the gate. Rename the heading to '### Phase N: ...' (pick the next free N) and add '- **Status:** pending|in_progress' on its last line. See skills/planning-with-files/SKILL.md > FORMAT CONTRACT. Do NOT stop until every block of unchecked work lives under a '### Phase N:' heading."
    log "decision: BLOCK (NON-PHASE WORK — '${NON_PHASE_HEADING}' has unchecked items)"
    ESCAPED_REASON=$(json_escape "$REASON")
    OUTPUT="{\"decision\":\"block\",\"reason\":$ESCAPED_REASON}"
    log "stdout: ${#OUTPUT} chars"
    echo "$OUTPUT"
    exit 0
fi

if [ $((COMPLETE + DEFERRED)) -ge "$TOTAL" ]; then
    # All phases settled (complete or deferred-with-reason) -> let the agent stop.
    log "decision: ALL SETTLED (complete=$COMPLETE deferred=$DEFERRED total=$TOTAL) -> emitting {} (allow stop)"
    echo '{}'
    exit 0
fi

# Planning mode: all phases still pending (none in_progress, complete, or deferred).
# The agent is reviewing / discussing the plan with the user, not implementing.
# Allow stop — do not demand continuation.
if [ "$COMPLETE" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ] && [ "$DEFERRED" -eq 0 ]; then
    log "decision: PLANNING MODE (no phases started/complete/deferred, all pending) -> emitting {} (allow stop)"
    echo '{}'
    exit 0
fi

# Discussion mode: ## Current Phase is empty (no valid "Phase N" parsed from it)
# AND nothing is complete or deferred yet. This covers the case where a phase
# is marked in_progress for tracking (e.g. Phase 0 = research/plan phase with
# some items checked) but the agent is still discussing/waiting for user input
# before implementation begins. The placeholder text in ## Current Phase must NOT
# contain "Phase N" patterns — if it does, it will be misread as the current
# phase (see SKILL.md FORMAT CONTRACT). When Current Phase is truly empty,
# we treat the session as still in discussion mode and allow stop.
if [ -z "${PHASE_NUM:-}" ] && [ "$COMPLETE" -eq 0 ] && [ "$DEFERRED" -eq 0 ]; then
    log "decision: DISCUSSION MODE (Current Phase empty, nothing complete/deferred) -> emitting {} (allow stop)"
    echo '{}'
    exit 0
fi

# Task incomplete -> BLOCK the stop and tell the agent why to continue.
# Per Codex docs:
#   Stop continuation uses top-level decision="block" + reason.
#   (additionalContext does NOT apply to Stop hooks).
SETTLED=$((COMPLETE + DEFERRED))
DEFERRED_NOTE=""
[ "$DEFERRED" -gt 0 ] && DEFERRED_NOTE=" (including $DEFERRED deferred)"
REASON="[planning-with-files] Task incomplete ($SETTLED/$TOTAL phases settled${DEFERRED_NOTE}).${REMAINING_LINE} Update the Resume Checkpoint in ${PLAN_FILE}, then continue. If the user explicitly requested a pause or an external blocker prevents progress, refresh optional handoff.md after the required planning files and use '- **Status:** deferred (reason)' only when that rule permits it."
log "decision: BLOCK ($SETTLED/$TOTAL phases settled, deferred=$DEFERRED)"
ESCAPED_REASON=$(json_escape "$REASON")
OUTPUT="{\"decision\":\"block\",\"reason\":$ESCAPED_REASON}"
log "stdout: ${#OUTPUT} chars"
echo "$OUTPUT"
exit 0
