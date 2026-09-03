#!/bin/bash
# plan-files: Canonical Stop hook core.
# Checks if all phases in tasks.md are complete.
# Injects continuation context if phases are incomplete.
# Always exits 0 — outputs JSON to stdout. Debug log written to
#   tmp/hook-logs/plan-files/agent-stop.log
#
# Bash 4+ hook; session JSON uses jq, Python 3, or Node and otherwise fails closed.

set -u
set -o pipefail 2>/dev/null || true

# shellcheck source=hook-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"

INPUT=$(cat)
PROVIDER=${1:-}
REPO_ROOT=${2:-}
PENDING_STOP_GUARD=${3:-0}
STOP_OUTPUT=${4:-top}
BIND_TOOL=${5:-}
[ -n "$PROVIDER" ] && [ -d "$REPO_ROOT/skills/plan-files/scripts" ] || { printf '{}'; exit 0; }
STATE_TOOL="$REPO_ROOT/skills/plan-files/scripts/session-state.sh"

cd "$(bash "$REPO_ROOT/skills/plan-files/scripts/resolve-project-root.sh")" 2>/dev/null || true

json_escape() {
    local s=${1:-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '"%s"' "$s"
}

render_stop_block() {
    local reason=${1:-} escaped
    escaped=$(json_escape "$reason")
    if [ "$STOP_OUTPUT" = "copilot" ]; then
        printf '{"hookSpecificOutput":{"hookEventName":"Stop","decision":"block","reason":%s}}' "$escaped"
    else
        printf '{"decision":"block","reason":%s}' "$escaped"
    fi
}

# Ownership enforcement happens at UserPromptSubmit + PreToolUse. Stop only
# checks completion state for an owned session.
if [ "${PLANNING_DISABLED:-0}" = "1" ] || [ -e .plan-files-skip ]; then
    printf '{}'
    exit 0
fi
SESSION_ID=$(printf '%s' "$INPUT" | "$STATE_TOOL" session-id 2>/dev/null || true)
PLAN_DIR=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" resolve "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)
if [ -z "$PLAN_DIR" ]; then
    CANDIDATE=""
    if [ "$PENDING_STOP_GUARD" = "1" ]; then
        CANDIDATE=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" pending-candidate "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)
    fi
    if [ -n "${CANDIDATE:-}" ]; then
        CANDIDATE_CONTEXT=""
        if [ -x "$BIND_TOOL" ]; then
            CANDIDATE_CONTEXT=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" candidate-context \
                "$CANDIDATE" "$BIND_TOOL" 2>/dev/null || true)
        fi
        if [ -n "$CANDIDATE_CONTEXT" ]; then
            REASON="[plan-files] OWNERSHIP ACTION REQUIRED before stopping.
$CANDIDATE_CONTEXT
[plan-files] Run the exact SAME or DIFFERENT command above, then continue; do not report an external blocker."
        else
            REASON="[plan-files] OWNERSHIP ACTION REQUIRED before stopping. Candidate '$CANDIDATE' is still pending. Do not stop or report a blocker. Run the provided bind or release command from the ownership prompt, then continue."
        fi
        render_stop_block "$REASON"
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
LOG_DIR="tmp/hook-logs/plan-files"
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
log "scope provider=$PROVIDER task=$(basename "$PLAN_DIR") session=$(planning_privacy_key "$PROVIDER:$SESSION_ID")"
log "cwd: $(pwd)"
log "plan source: $PLAN_SOURCE -> $PLAN_FILE"
log "stdin bytes=${#INPUT}"

if [ ! -f "$PLAN_FILE" ]; then
    log "${PLAN_FILE:-tasks.md}: ABSENT -> emitting {} (no-op)"
    echo '{}'
    exit 0
fi
log "${PLAN_FILE}: present ($(wc -c < "$PLAN_FILE" | tr -d ' ') bytes)"

# --- Phase counting (delegated to common.sh:count_phases) ------------------
count_phases "$PLAN_FILE"
log "phases: total=$TOTAL complete=$COMPLETE in_progress=$IN_PROGRESS pending=$PENDING blocked=$BLOCKED deferred=$DEFERRED"

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
        REMAINING_LINE=" ${PHASE_NUM}: ${REMAINING_COUNT} unchecked item(s). First unchecked: ${REMAINING_FIRST}"
    fi
    log "remaining: count=${REMAINING_COUNT:-?}"
fi

# --- Format / Workflow-Profile checks (delegated to common.sh), plus
# status-integrity checks (STATUS LIES / STALE Current Phase / NON-PHASE
# WORK) below — every applicable violation across ALL of these categories is
# accumulated into REASON_PARTS and reported in ONE block, instead of only
# the first one found across repeated block/fix/retry cycles. Catches two
# classes of "the agent stopped too early" bug in the status-integrity part:
#   (A) A phase marked **Status:** complete still has "- [ ]" items inside it.
#       The phase counter trusts the status marker, so unchecked sub-tasks are
#       invisible to the gate. Block until either the boxes are checked or the
#       remaining work is split into a new ### Phase with status pending.
#       Note: `blocked` and `deferred` phases are EXEMPT — their unchecked
#       items are expected because no actionable work remains in this turn.
#   (B) ## Current Phase points at a phase whose status is already complete
#       (or blocked/deferred) while other phases are still pending/in_progress. The
#       hook keeps injecting the wrong phase context and the agent loses
#       track. Block until ## Current Phase is advanced to a non-settled phase.
REASON_PARTS=()

FORMAT_ISSUES=$(check_task_plan_format "$PLAN_FILE")
if [ -n "$FORMAT_ISSUES" ]; then
    while IFS= read -r _fmt_code; do
        [ -n "$_fmt_code" ] || continue
        REASON_PARTS+=("$(task_plan_format_message "$_fmt_code" "$PLAN_FILE" "$TOTAL") Fix the plan structure, then continue.")
    done <<< "$FORMAT_ISSUES"
fi

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
    REASON_PARTS+=("STATUS LIES in ${PLAN_FILE}: ${LIE_PHASE} is marked '**Status:** complete' but still has ${LIE_COUNT} unchecked '- [ ]' item(s). First: ${LIE_FIRST} | Either (a) finish the items and check the boxes, or (b) demote the phase to '**Status:** in_progress' and update '## Current Phase' to ${LIE_PHASE}, or (c) split the remaining items into a new '### Phase N+1: ...' with '**Status:** pending'. Do not stop with unchecked items inside a 'complete' phase.")
    log "found: STATUS LIES — ${LIE_PHASE} complete with ${LIE_COUNT} unchecked"
fi

# Stale Current Phase: pointer references a phase whose status is settled
# (complete, blocked, or deferred), AND a non-settled phase remains.
# Only fires if the user actually filled in ## Current Phase (PHASE_NUM non-empty).
if [ -n "${PHASE_NUM:-}" ] && [ $((COMPLETE + BLOCKED + DEFERRED)) -lt "$TOTAL" ]; then
    CURRENT_NUM=$(printf '%s' "$PHASE_NUM" | grep -oE '[0-9]+' | head -1)
    CURRENT_STATUS=""
    NEXT_INCOMPLETE=""
    while IFS=$'\t' read -r _num _status _unchecked _first; do
        [ -z "${_num:-}" ] && continue
        if [ "$_num" = "$CURRENT_NUM" ]; then
            CURRENT_STATUS="${_status:-}"
        fi
        if [ -z "$NEXT_INCOMPLETE" ] && [ "${_status:-}" != "complete" ] && [ "${_status:-}" != "blocked" ] && [ "${_status:-}" != "deferred" ]; then
            NEXT_INCOMPLETE="Phase ${_num}"
        fi
    done <<< "$SUMMARY"

    if { [ "$CURRENT_STATUS" = "complete" ] || [ "$CURRENT_STATUS" = "blocked" ] || [ "$CURRENT_STATUS" = "deferred" ]; } && [ -n "$NEXT_INCOMPLETE" ]; then
        REASON_PARTS+=("STALE '## Current Phase' in ${PLAN_FILE}: it points at ${PHASE_NUM} which is already '**Status:** ${CURRENT_STATUS}', but ${NEXT_INCOMPLETE} (and possibly later phases) are not settled. Update the '## Current Phase' section to '${NEXT_INCOMPLETE}' and set its status to 'in_progress' before continuing. The hook injects context based on Current Phase — leaving it on a settled phase makes the agent work on the wrong target.")
        log "found: STALE Current Phase — points at ${CURRENT_STATUS} ${PHASE_NUM}, next incomplete is ${NEXT_INCOMPLETE}"
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
    REASON_PARTS+=("FORMAT CONTRACT VIOLATION in ${PLAN_FILE}: heading '### ${NON_PHASE_HEADING}' contains unchecked '- [ ]' work items but is NOT a recognized phase heading. The ONLY heading form recognized as work is '### Phase N: Title' (level-3, the literal word 'Phase', a number, a colon). Rename it to a valid phase and add one recognized status. Do NOT stop until every block of unchecked work lives under a '### Phase N:' heading.")
    log "found: NON-PHASE WORK — '${NON_PHASE_HEADING}' has unchecked items"
fi

if [ "${#REASON_PARTS[@]}" -gt 0 ]; then
    COMBINED=""
    if [ "${#REASON_PARTS[@]}" -gt 1 ]; then
        _idx=0
        for _part in "${REASON_PARTS[@]}"; do
            _idx=$((_idx + 1))
            COMBINED="${COMBINED}(${_idx}/${#REASON_PARTS[@]}) ${_part}
"
        done
    else
        COMBINED="${REASON_PARTS[0]}"
    fi
    REASON="[plan-files] ${COMBINED}"
    log "decision: BLOCK (${#REASON_PARTS[@]} issue(s) found in one pass)"
    OUTPUT=$(render_stop_block "$REASON")
    log "stop continuation=true output_chars=${#OUTPUT}"
    log "stdout: ${#OUTPUT} chars"
    echo "$OUTPUT"
    exit 0
fi

if [ $((COMPLETE + BLOCKED + DEFERRED)) -ge "$TOTAL" ]; then
    # All phases settled (complete, blocked-with-reason, or deferred-with-reason).
    # Only a fully complete plan is genuinely finished, and only then is its
    # LEASE stood down here. --deactivate-pointer clears .plan-files but not
    # the lease, so without this the next prompt still nominates a task with
    # nothing left to do and the agent must run a release command by hand.
    # The pointer is deliberately untouched: it is the candidate signal for the
    # next prompt, and clearing both would make a finished plan unreferenceable.
    # A blocked or deferred plan is PAUSED, not done, so it keeps its lease.
    if [ "$BLOCKED" -eq 0 ] && [ "$DEFERRED" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
        PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" finish "$PROVIDER" "$SESSION_ID" "$(basename "$PLAN_DIR")" 2>/dev/null || true
        log "decision: ALL COMPLETE ($COMPLETE/$TOTAL) -> lease finished, pointer untouched, allow stop"
    else
        log "decision: ALL SETTLED with blocked=$BLOCKED deferred=$DEFERRED -> lease retained for resume, allow stop"
    fi
    log "stop continuation=false output_chars=2"
    echo '{}'
    exit 0
fi

# Planning mode: all phases still pending (none in_progress or settled).
# The agent is reviewing / discussing the plan with the user, not implementing.
# Allow stop — do not demand continuation.
if [ "$COMPLETE" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ] && [ "$BLOCKED" -eq 0 ] && [ "$DEFERRED" -eq 0 ]; then
    log "decision: PLANNING MODE (all phases pending) -> emitting {} (allow stop)"
    log "stop continuation=false output_chars=2"
    echo '{}'
    exit 0
fi

# Discussion mode: ## Current Phase is empty (no valid "Phase N" parsed from it)
# AND no phase is settled yet. This covers the case where a phase
# is marked in_progress for tracking (e.g. Phase 0 = research/plan phase with
# some items checked) but the agent is still discussing/waiting for user input
# before implementation begins. The placeholder text in ## Current Phase must NOT
# contain "Phase N" patterns — if it does, it will be misread as the current
# phase (see SKILL.md FORMAT CONTRACT). When Current Phase is truly empty,
# we treat the session as still in discussion mode and allow stop.
if [ -z "${PHASE_NUM:-}" ] && [ "$COMPLETE" -eq 0 ] && [ "$BLOCKED" -eq 0 ] && [ "$DEFERRED" -eq 0 ]; then
    log "decision: DISCUSSION MODE (Current Phase empty, no settled phase) -> emitting {} (allow stop)"
    log "stop continuation=false output_chars=2"
    echo '{}'
    exit 0
fi

# --- Structured progress fingerprint + repeated-Stop recovery -------------
FINGERPRINT=$(planning_progress_fingerprint "$PLAN_FILE" 2>/dev/null || true)
ITEM_CONTEXT=$(planning_item_context "$PLAN_FILE" 2>/dev/null || true)
ITEM_FIELDS=""
if [ -n "$ITEM_CONTEXT" ] && command -v python3 >/dev/null 2>&1; then
    ITEM_FIELDS=$(printf '%s' "$ITEM_CONTEXT" | python3 -c '
import json, sys
p=json.load(sys.stdin)
def clean(value): return " ".join(str(value or "").split()).replace("\t", " ")
print("\t".join(clean(p.get(key)) for key in ("active_item","active_text","first_unchecked_item","first_unchecked_text")))
' 2>/dev/null || true)
fi
ACTIVE_ITEM="" ACTIVE_TEXT="" FIRST_ITEM="" FIRST_TEXT=""
IFS=$'\t' read -r ACTIVE_ITEM ACTIVE_TEXT FIRST_ITEM FIRST_TEXT <<< "$ITEM_FIELDS"
TARGET_ITEM=${ACTIVE_ITEM:-$FIRST_ITEM}
TARGET_TEXT=${ACTIVE_TEXT:-$FIRST_TEXT}

NO_PROGRESS_COUNT=0
STOP_PROGRESS_STATE=initial
HOOK_STATE=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" cache "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)
if [ -n "$HOOK_STATE" ] && [ -n "$FINGERPRINT" ]; then
    STOP_STATE_FILE="$HOOK_STATE.stop"
    STOP_STATE_LOCK="$STOP_STATE_FILE.lock"
    {
        flock -x 8 || true
        PREVIOUS_FINGERPRINT=$(grep -E '^fingerprint=' "$STOP_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
        PREVIOUS_COUNT=$(grep -E '^no_progress_count=' "$STOP_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo 0)
        PREVIOUS_COUNT=${PREVIOUS_COUNT:-0}
        if [ -n "$PREVIOUS_FINGERPRINT" ] && [ "$PREVIOUS_FINGERPRINT" = "$FINGERPRINT" ]; then
            NO_PROGRESS_COUNT=$((PREVIOUS_COUNT + 1))
            STOP_PROGRESS_STATE=no_progress
        elif [ -n "$PREVIOUS_FINGERPRINT" ]; then
            NO_PROGRESS_COUNT=0
            STOP_PROGRESS_STATE=progress
        fi
        {
            printf 'fingerprint=%s\n' "$FINGERPRINT"
            printf 'no_progress_count=%s\n' "$NO_PROGRESS_COUNT"
            printf 'last_stop_ts=%s\n' "$(date +%s)"
        } > "$STOP_STATE_FILE.tmp" && mv "$STOP_STATE_FILE.tmp" "$STOP_STATE_FILE"
    } 8>>"$STOP_STATE_LOCK" 2>/dev/null || true
fi

TARGET_LINE=""
if [ -n "$TARGET_ITEM" ]; then
    TARGET_LINE=" Active Item ${TARGET_ITEM}: ${TARGET_TEXT}"
fi
if [ "$STOP_PROGRESS_STATE" = "no_progress" ]; then
    RECOVERY_LINE=" No structured plan progress was detected across ${NO_PROGRESS_COUNT} repeated Stop attempt(s). Do not answer this hook with another summary. Resume the named item now: call the next operational tool; if its evidence is already satisfied, run the structured checkpoint immediately. A failed execution path is not a blocker while a materially different path remains."
    if [ "$NO_PROGRESS_COUNT" -ge 2 ]; then
        RECOVERY_LINE="${RECOVERY_LINE} If this is because a background/async process (a running command, external job, test run) simply has not finished yet, stop ending the turn just to re-check it -- that only re-triggers this same Stop block. Use a tool that streams its output back into the same turn without ending it instead (for example Claude Code's Monitor tool), or mark this phase 'blocked (reason)' if the wait will genuinely span many turns."
    fi
elif [ "$STOP_PROGRESS_STATE" = "progress" ]; then
    RECOVERY_LINE=" Structured plan progress occurred since the previous Stop; continue directly from the named item without a progress-only final."
else
    RECOVERY_LINE=" Continue directly from the named item without a progress-only final."
fi
log "progress fingerprint=${FINGERPRINT:-unavailable} state=$STOP_PROGRESS_STATE no_progress_count=$NO_PROGRESS_COUNT active_item=${ACTIVE_ITEM:-none} first_item=${FIRST_ITEM:-none}"

# Task incomplete -> BLOCK the stop and tell the agent why to continue.
# Per Codex docs:
#   Stop continuation uses top-level decision="block" + reason.
#   (additionalContext does NOT apply to Stop hooks).
SETTLED=$((COMPLETE + BLOCKED + DEFERRED))
REASON="[plan-files] Task incomplete ($SETTLED/$TOTAL phases settled: $COMPLETE complete, $BLOCKED blocked, $DEFERRED deferred).${REMAINING_LINE}${TARGET_LINE}${RECOVERY_LINE} Completing one item or checkpoint is progress, not a stopping boundary. Do not emit a final answer while any phase remains actionable. Continue every unchecked item in every non-settled phase, starting with Current Phase; after each phase, advance Current Phase and keep working until every phase is settled. If a genuine external dependency leaves a phase with no actionable path, update its checkpoint and set '- **Status:** blocked (reason)'. Use '- **Status:** deferred (reason)' only when the user explicitly postpones that phase. Then continue any other non-settled phases; stop only when every phase is complete, blocked, or deferred."
log "decision: BLOCK ($SETTLED/$TOTAL phases settled, blocked=$BLOCKED deferred=$DEFERRED progress_state=$STOP_PROGRESS_STATE no_progress_count=$NO_PROGRESS_COUNT)"
OUTPUT=$(render_stop_block "$REASON")
log "stop continuation=true output_chars=${#OUTPUT} progress_state=$STOP_PROGRESS_STATE no_progress_count=$NO_PROGRESS_COUNT"
log "stdout: ${#OUTPUT} chars"
echo "$OUTPUT"
exit 0
