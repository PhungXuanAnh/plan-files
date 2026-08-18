#!/bin/bash
# planning-with-files: Post-tool-use hook for GitHub Copilot
# Runs AFTER every tool call. Anchors goals (re-injecting Goal + Current Phase
# from tasks.md, size-bounded per section) and nudges progress logging.
# No-op when tasks.md does not exist - zero pollution on non-planning sessions.
# Always exits 0 - outputs JSON to stdout. Debug log written to
#   tmp/hook-logs/plan-with-files/post-tool-use.log
#
# Bash 4+ hook; session JSON uses jq, Python 3, or Node and otherwise fails closed.

set -u
set -o pipefail 2>/dev/null || true

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

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
LOG_FILE="$LOG_DIR/post-tool-use.log"
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

log "=== post-tool-use ==="
log "cwd: $(pwd)"
log "plan source: $PLAN_SOURCE -> $PLAN_FILE"
INPUT_PREVIEW=$(printf '%s' "$INPUT" | tr '\n' ' ' | cut -c 1-300)
log "stdin (first 300 chars, ${#INPUT} total): $INPUT_PREVIEW"

if [ ! -f "$PLAN_FILE" ]; then
    log "${PLAN_FILE:-tasks.md}: ABSENT -> emitting {} (no-op, zero pollution)"
    echo '{}'
    exit 0
fi
PLAN_BYTES=$(wc -c < "$PLAN_FILE" | tr -d ' ')
log "${PLAN_FILE}: present (${PLAN_BYTES} bytes)"

# --- Phase counting (delegated to common.sh:count_phases) ------------------
count_phases "$PLAN_FILE"
log "phases: total=$TOTAL complete=$COMPLETE in_progress=$IN_PROGRESS pending=$PENDING blocked=$BLOCKED deferred=$DEFERRED"

SETTLED_ISSUE=""
if [ "$TOTAL" -gt 0 ] && [ $((COMPLETE + BLOCKED + DEFERRED)) -ge "$TOTAL" ]; then
    SETTLED_ISSUE=$(planning_settled_integrity_issue "$PLAN_FILE")
    if [ -z "$SETTLED_ISSUE" ]; then
        log "decision: valid owned plan is settled -> emitting {}"
        echo '{}'
        exit 0
    fi
    log "settled plan remains active because integrity check found: $SETTLED_ISSUE"
fi

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
PHASE_RAW=$(current_phase_pointer "$PLAN_FILE")
log "extracted Goal: ${#GOAL_RAW} chars; Current Phase: ${#PHASE_RAW} chars"

GOAL_BODY=$(cap "$GOAL_RAW" $MAX_GOAL_CHARS "Goal")
PHASE_BODY=$(cap "$PHASE_RAW" $MAX_PHASE_CHARS "Current Phase")

# --- Remaining-in-phase snippet (cheap: count + first unchecked item) -------
# Extracts phase label from "## Current Phase" body, locates "### <Phase N>"
# block in the plan, counts `- [ ]` lines, and captures the first one.
# Output is a single line appended to the nudge — anti-substitution reminder
# without per-call inflation. Caps first-item at 200 chars.
PHASE_NUM=$(printf '%s' "$PHASE_RAW" | grep -oE 'Phase [0-9]+' | head -1 || true)
REMAINING_LINE=""
REMAINING_COUNT=""
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
    if [ -n "${REMAINING_COUNT:-}" ] && [ "$REMAINING_COUNT" -eq 0 ]; then
        REMAINING_LINE="${PHASE_NUM}: 0 unchecked items in this phase — if all 'Done when' criteria genuinely verified (see anti-substitution rule), mark phase complete."
    elif [ -n "${REMAINING_COUNT:-}" ] && [ "$REMAINING_COUNT" -gt 0 ]; then
        REMAINING_LINE="${PHASE_NUM}: ${REMAINING_COUNT} unchecked item(s). First: ${REMAINING_FIRST}"
    fi
    log "remaining: count=${REMAINING_COUNT:-?} first(${#REMAINING_FIRST} chars)"
fi

# --- Contracted item context ------------------------------------------------
PLAN_FINGERPRINT=$(planning_progress_fingerprint "$PLAN_FILE" 2>/dev/null || true)
ITEM_CONTEXT=$(planning_item_context "$PLAN_FILE" 2>/dev/null || true)
ITEM_FIELDS=""
if [ -n "$ITEM_CONTEXT" ] && command -v python3 >/dev/null 2>&1; then
    ITEM_FIELDS=$(printf '%s' "$ITEM_CONTEXT" | python3 -c '
import json, sys
p=json.load(sys.stdin)
def clean(value): return " ".join(str(value or "").split()).replace("\t", " ")
print("\t".join(("true" if p.get("contracted") else "false", clean(p.get("active_item")), clean(p.get("active_text")), clean(p.get("active_evidence")))))
' 2>/dev/null || true)
fi
CONTRACTED=false ACTIVE_ITEM="" ACTIVE_TEXT="" ACTIVE_EVIDENCE=""
IFS=$'\t' read -r CONTRACTED ACTIVE_ITEM ACTIVE_TEXT ACTIVE_EVIDENCE <<< "$ITEM_FIELDS"

# --- Semantic delta + item-aware stale detection ---------------------------
# Contracted plans receive one immediate reminder after the first unchanged
# tool result and then at most one per interval. Parallel bursts share the same
# flock-protected counter/timestamp and collapse into the same window.
NUDGE_DEBOUNCE_SECS=60
ITEM_NUDGE_DEBOUNCE_SECS=30
STALE_TOOL_THRESHOLD=3
STATE_FILE=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" cache "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)
[ -n "$STATE_FILE" ] || { echo '{}'; exit 0; }
STATE_LOCK="$STATE_FILE.lock"
LAST_PHASE_NUM=""
LAST_REMAINING_COUNT=""
LAST_GOAL_LEN=""
LAST_PHASE_LEN=""
LAST_NUDGE_TS=0
LAST_PLAN_FINGERPRINT=""
UNCHANGED_TOOL_COUNT=0
LAST_CHECKPOINT_TS=0
LAST_ITEM_NUDGE_TS=0
if [ -f "$STATE_FILE" ]; then
    LAST_PHASE_NUM=$(grep -E '^last_phase_num='        "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    LAST_REMAINING_COUNT=$(grep -E '^last_remaining_count=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    LAST_GOAL_LEN=$(grep -E '^last_goal_len='         "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    LAST_PHASE_LEN=$(grep -E '^last_phase_len='        "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    LAST_NUDGE_TS=$(grep -E '^last_nudge_ts='         "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo 0)
    LAST_PLAN_FINGERPRINT=$(grep -E '^last_plan_fingerprint=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    UNCHANGED_TOOL_COUNT=$(grep -E '^unchanged_tool_count=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo 0)
    LAST_CHECKPOINT_TS=$(grep -E '^last_checkpoint_ts=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo 0)
    LAST_ITEM_NUDGE_TS=$(grep -E '^last_item_nudge_ts=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo 0)
fi
LAST_NUDGE_TS=${LAST_NUDGE_TS:-0}
UNCHANGED_TOOL_COUNT=${UNCHANGED_TOOL_COUNT:-0}
LAST_CHECKPOINT_TS=${LAST_CHECKPOINT_TS:-0}
LAST_ITEM_NUDGE_TS=${LAST_ITEM_NUDGE_TS:-0}

CUR_GOAL_LEN=${#GOAL_BODY}
CUR_PHASE_LEN=${#PHASE_BODY}
NOW_TS=$(date +%s)
log "delta (pre-lock): fingerprint='${PLAN_FINGERPRINT:-}' (was '${LAST_PLAN_FINGERPRINT:-}') active_item='${ACTIVE_ITEM:-}' unchanged_tools=$UNCHANGED_TOOL_COUNT checkpoint_age=$((LAST_CHECKPOINT_TS > 0 ? NOW_TS - LAST_CHECKPOINT_TS : 0))s"

# Flock-protected decision + state update.
# Re-read state under lock to avoid TOCTOU with parallel hook processes.
EMIT_NUDGE=false
INJECT_FULL=false
PLAN_CHANGED=false
STALE_CHECKPOINT=false
CHECKPOINT_LAG_SECS=0
{
    flock -x 8 || true
    _st_phase=$(grep -E '^last_phase_num='        "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    _st_remaining=$(grep -E '^last_remaining_count=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    _st_goal=$(grep -E '^last_goal_len='         "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    _st_phase_len=$(grep -E '^last_phase_len='   "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    _st_nudge_ts=$(grep -E '^last_nudge_ts='     "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo 0)
    _st_fingerprint=$(grep -E '^last_plan_fingerprint=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    _st_unchanged=$(grep -E '^unchanged_tool_count=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo 0)
    _st_checkpoint_ts=$(grep -E '^last_checkpoint_ts=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo 0)
    _st_item_nudge_ts=$(grep -E '^last_item_nudge_ts=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo 0)
    _st_nudge_ts=${_st_nudge_ts:-0}
    _st_unchanged=${_st_unchanged:-0}
    _st_checkpoint_ts=${_st_checkpoint_ts:-0}
    _st_item_nudge_ts=${_st_item_nudge_ts:-0}
    _time_since=$(( NOW_TS - _st_nudge_ts ))

    _delta=false
    if [ -n "$PLAN_FINGERPRINT" ] && [ "$PLAN_FINGERPRINT" != "${_st_fingerprint:-}" ]; then
        _delta=true
    elif [ "${PHASE_NUM:-}"       != "${_st_phase:-}" ] \
    || [ "${REMAINING_COUNT:-}" != "${_st_remaining:-}" ] \
    || [ "$CUR_GOAL_LEN"        != "${_st_goal:-}" ] \
    || [ "$CUR_PHASE_LEN"       != "${_st_phase_len:-}" ]; then
        _delta=true
    fi

    if [ "$_delta" = "true" ]; then
        PLAN_CHANGED=true
        EMIT_NUDGE=true
        INJECT_FULL=true
        _st_unchanged=0
        _st_checkpoint_ts=$NOW_TS
        _st_item_nudge_ts=0
    else
        _st_unchanged=$((_st_unchanged + 1))
        if [ "$CONTRACTED" = "true" ] && [ -n "$ACTIVE_ITEM" ]; then
            CHECKPOINT_LAG_SECS=$(( _st_checkpoint_ts > 0 ? NOW_TS - _st_checkpoint_ts : 0 ))
            [ "$_st_unchanged" -ge "$STALE_TOOL_THRESHOLD" ] && STALE_CHECKPOINT=true
            if [ "$_st_item_nudge_ts" -eq 0 ] || [ $((NOW_TS - _st_item_nudge_ts)) -ge "$ITEM_NUDGE_DEBOUNCE_SECS" ]; then
                EMIT_NUDGE=true
                _st_item_nudge_ts=$NOW_TS
            fi
        elif [ "$_time_since" -ge "$NUDGE_DEBOUNCE_SECS" ]; then
            EMIT_NUDGE=true
        fi
    fi

    UNCHANGED_TOOL_COUNT=$_st_unchanged
    LAST_CHECKPOINT_TS=$_st_checkpoint_ts
    LAST_ITEM_NUDGE_TS=$_st_item_nudge_ts
    [ "$EMIT_NUDGE" = "true" ] && LAST_NUDGE_TS=$NOW_TS
    {
        printf 'last_phase_num=%s\n'       "${PHASE_NUM:-}"
        printf 'last_remaining_count=%s\n' "${REMAINING_COUNT:-}"
        printf 'last_goal_len=%s\n'        "$CUR_GOAL_LEN"
        printf 'last_phase_len=%s\n'       "$CUR_PHASE_LEN"
        printf 'last_nudge_ts=%s\n'        "$LAST_NUDGE_TS"
        printf 'last_plan_fingerprint=%s\n' "$PLAN_FINGERPRINT"
        printf 'unchanged_tool_count=%s\n' "$UNCHANGED_TOOL_COUNT"
        printf 'last_checkpoint_ts=%s\n'   "$LAST_CHECKPOINT_TS"
        printf 'last_item_nudge_ts=%s\n'   "$LAST_ITEM_NUDGE_TS"
    } > "$STATE_FILE.tmp" 2>/dev/null \
        && mv "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null || true
} 8>>"$STATE_LOCK" 2>/dev/null || true

log "item_state fingerprint=${PLAN_FINGERPRINT:-unavailable} active_item=${ACTIVE_ITEM:-none} plan_changed=$PLAN_CHANGED unchanged_tools=$UNCHANGED_TOOL_COUNT checkpoint_lag=${CHECKPOINT_LAG_SECS}s stale=$STALE_CHECKPOINT emit_nudge=$EMIT_NUDGE inject_full=$INJECT_FULL"

if [ -n "$SETTLED_ISSUE" ]; then
    EMIT_NUDGE=true
    INJECT_FULL=true
fi

if [ "$EMIT_NUDGE" = "false" ]; then
    log "debounce active -> {} (silent)"
    echo '{}'
    exit 0
fi

PLAN_SUMMARY=""
if [ "$INJECT_FULL" = "true" ]; then
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
fi

if [ "$CONTRACTED" = "true" ] && [ -n "$ACTIVE_ITEM" ]; then
    NUDGE="[planning-with-files] Active Item ${ACTIVE_ITEM}: ${ACTIVE_TEXT} Evidence: ${ACTIVE_EVIDENCE:-pending}
[planning-with-files] If this tool result satisfies the outcome, your next workflow operation must be the structured checkpoint before any unrelated tool. Otherwise continue the same item and record material partial/error evidence; arbitrary tool success is not semantic completion."
    if [ "$STALE_CHECKPOINT" = "true" ]; then
        NUDGE="${NUDGE}
[planning-with-files] STALE ITEM STATE: ${UNCHANGED_TOOL_COUNT} tool result(s) without a semantic plan checkpoint (${CHECKPOINT_LAG_SECS}s since the last detected plan change). Checkpoint now if the evidence predicate is true; otherwise keep working ${ACTIVE_ITEM}, not a different item."
    fi
else
    NUDGE="[planning-with-files] Update tasks.md with what you just did. If a phase is now complete, update ${PLAN_FILE} status. If you no longer see the planning-with-files SKILL.md rules in your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing."
fi
if [ -n "$SETTLED_ISSUE" ]; then
    NUDGE="${NUDGE}
[planning-with-files] Settled markers failed integrity check (${SETTLED_ISSUE}); keep this owned plan active and fix it before stopping."
fi
COMPACTION_WARN=$(planning_file_budget_warning "$PLAN_DIR")
if [ -n "$COMPACTION_WARN" ]; then
    NUDGE="${NUDGE}
${COMPACTION_WARN}"
    log "compaction warn injected (${#COMPACTION_WARN} chars)"
fi
HANDOFF_WARN=$(planning_handoff_warning "$PLAN_DIR")
if [ -n "$HANDOFF_WARN" ]; then
    NUDGE="${NUDGE}
${HANDOFF_WARN}"
    log "stale handoff warn injected (${#HANDOFF_WARN} chars)"
fi
# Only attach REMAINING_LINE on the call where the count actually changed,
# OR on the first injection in a session (LAST_REMAINING_COUNT empty).
if [ "$INJECT_FULL" = "true" ] && [ -n "$REMAINING_LINE" ]; then
    NUDGE="${NUDGE}
${REMAINING_LINE}"
fi

# --- Format / Workflow-Profile reminder (delegated to common.sh)
# Re-check when the plan changes; structural validation remains active throughout.
if [ "$INJECT_FULL" = "true" ]; then
    FORMAT_ISSUE=$(check_task_plan_format "$PLAN_FILE")
    FORMAT_WARN=$(task_plan_format_message "$FORMAT_ISSUE" "$PLAN_FILE" "$TOTAL")
    if [ -n "$FORMAT_WARN" ]; then
        NUDGE="${NUDGE}
[planning-with-files] ${FORMAT_WARN}"
        log "format warn injected (${#FORMAT_WARN} chars)"
    fi
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
{
    flock -x 9 || true
    printf '%s\n' "$CONTEXT" >> "$LOG_FILE"
} 9>>"$LOG_LOCK" 2>/dev/null || true
log "--- additionalContext end ---"

ESCAPED=$(json_escape "$CONTEXT")
OUTPUT="{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":$ESCAPED}}"
log "stdout: ${#OUTPUT} chars"
echo "$OUTPUT"
exit 0
