#!/usr/bin/env bash
# Shared PreToolUse ownership, restore-readiness, and maintenance gate.

set -u
set -o pipefail 2>/dev/null || true

PROVIDER=${1:-}
BIND_TOOL=${2:-}
LABEL=${3:-$PROVIDER}
REASON_LIMIT=${4:-0}
INPUT=$(cat)
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
STATE_TOOL="$SCRIPT_DIR/session-state.sh"
PLAN_STATE_TOOL="$SCRIPT_DIR/plan_state.py"

# The caller's cwd is not necessarily the workspace root (a submodule's own
# toplevel isn't, and a plain non-git folder containing several checkouts has
# no git-detectable root at all). cd out to the resolved root first so every
# relative path below (log files, the .plan-files-skip marker, $PWD
# passed on to session-state.sh) resolves against the true project root.
cd "$(bash "$SCRIPT_DIR/resolve-project-root.sh")" 2>/dev/null || true

LOG_DIR="tmp/hook-logs/plan-files"
LOG_FILE="$LOG_DIR/pre-tool-use.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
    printf '[%s] provider=%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$PROVIDER" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

json_escape() {
    local value=${1:-}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    printf '"%s"' "$value"
}

extract_tool_name() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$INPUT" | jq -r '.tool_name // .toolName // empty' 2>/dev/null || true
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$INPUT" | python3 -c 'import json,sys
try: p=json.load(sys.stdin)
except Exception: raise SystemExit(0)
v=(p.get("tool_name") or p.get("toolName") or "") if isinstance(p,dict) else ""
sys.stdout.write(v if isinstance(v,str) else "")' 2>/dev/null || true
    fi
}

extract_tool_input_json() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$INPUT" | jq -c '.tool_input // .toolInput // null' 2>/dev/null || printf 'null'
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$INPUT" | python3 -c 'import json,sys
try: p=json.load(sys.stdin)
except Exception:
    sys.stdout.write("null")
    raise SystemExit(0)
v=(p.get("tool_input") if "tool_input" in p else p.get("toolInput")) if isinstance(p,dict) else None
sys.stdout.write(json.dumps(v, ensure_ascii=False, separators=(",",":")))' 2>/dev/null || printf 'null'
    elif command -v node >/dev/null 2>&1; then
        printf '%s' "$INPUT" | node -e 'let s="";process.stdin.setEncoding("utf8");process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const p=JSON.parse(s);const v=Object.prototype.hasOwnProperty.call(p,"tool_input")?p.tool_input:p.toolInput;process.stdout.write(JSON.stringify(v===undefined?null:v))}catch(_){process.stdout.write("null")}})' 2>/dev/null || printf 'null'
    else
        printf 'null'
    fi
}

extract_tool_command() {
    local command=""
    if command -v jq >/dev/null 2>&1; then
        command=$(printf '%s' "$INPUT" | jq -jr '
          (.tool_input // .toolInput) as $input
          | if ($input | type) == "object" then
            ($input.command // $input.cmd // empty)
          elif ($input | type) == "string" then
            $input
          else empty end
          | select(type == "string")
        ' 2>/dev/null || true)
    elif command -v python3 >/dev/null 2>&1; then
        command=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: p=json.load(sys.stdin)
except Exception: raise SystemExit(0)
v=(p.get("tool_input") if "tool_input" in p else p.get("toolInput")) if isinstance(p,dict) else None
if isinstance(v,dict): v=v.get("command") or v.get("cmd")
if isinstance(v,str): sys.stdout.write(v)' 2>/dev/null || true)
    elif command -v node >/dev/null 2>&1; then
        command=$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.setEncoding("utf8");process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const p=JSON.parse(s);let v=p&&Object.prototype.hasOwnProperty.call(p,"tool_input")?p.tool_input:p&&p.toolInput;if(v&&typeof v==="object")v=v.command||v.cmd;if(typeof v==="string")process.stdout.write(v)}catch(_){}})' 2>/dev/null || true)
    fi
    printf '%s' "$command" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

budget_warning() {
    local plan_dir=$1
    [ -f "$plan_dir/tasks.md" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 "$PLAN_STATE_TOOL" budget-warning "$plan_dir/tasks.md" 2>/dev/null || true
}

restore_warning() {
    local plan_dir=$1 payload
    [ -f "$plan_dir/tasks.md" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    payload=$(python3 "$PLAN_STATE_TOOL" restore-check "$plan_dir/tasks.md" 2>/dev/null) || true
    [ -n "$payload" ] || return 0
    printf '%s' "$payload" | python3 -c 'import json,sys
try: p=json.load(sys.stdin)
except Exception: raise SystemExit(0)
if p.get("discussion_mode"):
    print("[plan-files] DISCUSSION ONLY. Start the user-authorized Active Item with plan_checkpoint.py before operational work.", end="")
    raise SystemExit(0)
if p.get("ok", True): raise SystemExit(0)
issues=p.get("issues", [])
parts=[]
for issue in issues[:3]:
    parts.append("{code} in {source} ## {heading}: {repair}".format(**issue))
more=len(issues)-len(parts)
if more > 0: parts.append(f"{more} more issue(s)")
print("[plan-files] RESTORE STATE ACTION REQUIRED: " + "; ".join(parts) + ". Run plan_state.py restore-check on the owned tasks.md for the bounded complete diagnosis.", end="")' 2>/dev/null || true
}

maintenance_tool_allowed() {
    local plan_dir=$1
    command -v python3 >/dev/null 2>&1 || return 1
    printf '%s' "$INPUT" | python3 "$SCRIPT_DIR/maintenance-tool-allowed.py" "$plan_dir"
}

mutation_plan_id() {
    command -v python3 >/dev/null 2>&1 || return 1
    printf '%s' "$INPUT" \
        | python3 "$SCRIPT_DIR/maintenance-tool-allowed.py" mutation-plan-id "$PWD"
}

block() {
    local reason=$1
    if [ "$REASON_LIMIT" -gt 0 ] && [ -n "${FEEDBACK_FILE:-}" ]; then
        if printf '%s' "$reason" | python3 "$SCRIPT_DIR/feedback_transport.py" render "$FEEDBACK_FILE" "$REASON_LIMIT"; then
            exit 0
        fi
        reason="[plan-files] Could not create the recovery file. Stop to receive recovery guidance; do not release the plan merely to bypass this denial."
    fi
    printf '{"decision":"block","reason":%s}' "$(json_escape "$reason")"
    exit 0
}

TOOL_NAME=$(extract_tool_name)
TOOL_INPUT_JSON=$(extract_tool_input_json)
log "event=PreToolUse input_bytes=${#INPUT}"
log "tool_call tool_name=$TOOL_NAME tool_input=$TOOL_INPUT_JSON"
[ -n "$PROVIDER" ] && [ -x "$BIND_TOOL" ] || { log "decision=allow reason=invalid-adapter-config"; printf '{}'; exit 0; }
[ "${PLANNING_DISABLED:-0}" != "1" ] && [ ! -e .plan-files-skip ] \
    || { log "decision=allow reason=planning-disabled"; printf '{}'; exit 0; }

SESSION_ID=$(printf '%s' "$INPUT" | "$STATE_TOOL" session-id 2>/dev/null || true)
[ -n "$SESSION_ID" ] || { log "decision=allow reason=no-verified-session"; printf '{}'; exit 0; }

FEEDBACK_FILE=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" feedback-file "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)
# Explicitly input-based: any tool carrying this session's generated feedback
# path passes, including unfamiliar tools or calls with additional arguments.
if [ -n "$FEEDBACK_FILE" ] && printf '%s' "$TOOL_INPUT_JSON" \
    | python3 "$SCRIPT_DIR/feedback_transport.py" allows "$FEEDBACK_FILE"; then
    printf '{}'; exit 0
fi

TOOL_COMMAND=$(extract_tool_command)
MUTATION_STATUS=0
MUTATION_PLAN=$(mutation_plan_id 2>/dev/null) || MUTATION_STATUS=$?
if [ "$MUTATION_STATUS" -eq 2 ]; then
    REASON_TEXT="[plan-files] PLAN MUTATION BLOCKED. This tool call targets Markdown in more than one planning task. Split it into one plan directory per call so session ownership is deterministic."
    log "session=$SESSION_ID decision=block-ambiguous-plan-mutation tool=$TOOL_NAME"
    block "$REASON_TEXT"
fi

PLAN_DIR=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" resolve "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)

if [ -n "$MUTATION_PLAN" ]; then
    if [ -n "$PLAN_DIR" ]; then
        OWNED_PLAN=$(basename "$PLAN_DIR")
        if [ "$OWNED_PLAN" != "$MUTATION_PLAN" ]; then
            REASON_TEXT="[plan-files] PLAN MUTATION BLOCKED. This session owns '$OWNED_PLAN', but the tool call targets plan '$MUTATION_PLAN'. There is no command that can switch ownership within this turn: release only works once a new user prompt flips this session's lease to pending, which has not happened yet, and re-claiming '$MUTATION_PLAN' will fail the same way. Do not retry release/claim/bind, and do not inspect internal tmp/plan-files/.sessions state files to work around this. Instead: keep this tool call scoped to '$OWNED_PLAN' for the rest of this turn, or stop and ask the user whether '$MUTATION_PLAN' is genuinely a separate task before touching it — do not decide unilaterally."
            log "session=$SESSION_ID owned=$OWNED_PLAN target=$MUTATION_PLAN decision=block-plan-conflict tool=$TOOL_NAME"
            block "$REASON_TEXT"
        fi
    elif [ ! -f "$PWD/tmp/plan-files/$MUTATION_PLAN/tasks.md" ]; then
        # This call is CREATING tasks.md/findings.md/decisions.md for a
        # brand-new task — PreToolUse fires before the write executes, so
        # the file necessarily doesn't exist on disk yet and claim_task's
        # task_exists guard would always fail here. Nothing to claim or
        # conflict with yet: allow it through. post-tool-use.sh claims
        # ownership once the write succeeds and the file actually exists.
        log "session=$SESSION_ID plan=$MUTATION_PLAN decision=allow-new-plan-creation tool=$TOOL_NAME"
    else
        CLAIM_STATUS=0
        PLAN_DIR=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" claim \
            "$PROVIDER" "$SESSION_ID" "$MUTATION_PLAN" 2>/dev/null) || CLAIM_STATUS=$?
        if [ "$CLAIM_STATUS" -ne 0 ] || [ -z "$PLAN_DIR" ]; then
            CURRENT_SCOPE=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" pending-candidate \
                "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)
            [ -n "$CURRENT_SCOPE" ] || CURRENT_SCOPE="another task or concurrent claim"
            REASON_TEXT="[plan-files] PLAN MUTATION BLOCKED. The call targets '$MUTATION_PLAN', but this session is pending for $CURRENT_SCOPE. Resolve that ownership first; the hook will not overwrite it."
            log "session=$SESSION_ID target=$MUTATION_PLAN current=$CURRENT_SCOPE decision=block-plan-claim tool=$TOOL_NAME status=$CLAIM_STATUS"
            block "$REASON_TEXT"
        fi
        log "session=$SESSION_ID plan=$MUTATION_PLAN decision=auto-claim-plan-mutation tool=$TOOL_NAME"
    fi
fi

if [ -z "$PLAN_DIR" ]; then
    CANDIDATE=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" pending-candidate "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)
    [ -n "$CANDIDATE" ] || { log "session=$SESSION_ID decision=allow reason=no-pending-candidate tool=$TOOL_NAME"; printf '{}'; exit 0; }
    printf -v project_root_arg '%q' "$PWD"
    printf -v bind_tool_arg '%q' "$BIND_TOOL"
    printf -v task_arg '%q' "$CANDIDATE"
    EXPECTED_BIND="PWF_PROJECT_ROOT=$project_root_arg bash $bind_tool_arg bind $task_arg"
    EXPECTED_RELEASE="PWF_PROJECT_ROOT=$project_root_arg bash $bind_tool_arg release $task_arg"
    EXPECTED_CLARIFY="PWF_PROJECT_ROOT=$project_root_arg bash $bind_tool_arg clarify $task_arg"
    if [ "$TOOL_COMMAND" = "$EXPECTED_CLARIFY" ]; then
        printf '{}'; exit 0
    fi
    if [ "$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" route-status "$PROVIDER" "$SESSION_ID")" = "waiting" ] \
        && printf '%s' "$INPUT" | python3 "$SCRIPT_DIR/maintenance-tool-allowed.py" question-tool; then
        printf '{}'; exit 0
    fi
    if [ "$TOOL_COMMAND" = "$EXPECTED_BIND" ]; then
        log "session=$SESSION_ID candidate=$CANDIDATE decision=allow-exact-bind tool=$TOOL_NAME"
        printf '{}'; exit 0
    fi
    if [ "$TOOL_COMMAND" = "$EXPECTED_RELEASE" ]; then
        log "session=$SESSION_ID candidate=$CANDIDATE decision=allow-exact-release tool=$TOOL_NAME"
        printf '{}'; exit 0
    fi
    CANDIDATE_CONTEXT=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" candidate-context \
        "$CANDIDATE" "$BIND_TOOL" 2>/dev/null || true)
    if [ -n "$CANDIDATE_CONTEXT" ]; then
        REASON_TEXT="$CANDIDATE_CONTEXT"
    else
        REASON_TEXT="[plan-files] OWNERSHIP ACTION REQUIRED (not a permission failure and not an external blocker). Candidate '$CANDIDATE' is pending for this prompt. Do not stop or report that the environment is blocked. Resolve ownership now by running exactly one action: SAME task -> $EXPECTED_BIND OR DIFFERENT task -> $EXPECTED_RELEASE. After bind/release succeeds, retry the original tool call."
    fi
    log "session=$SESSION_ID candidate=$CANDIDATE decision=block-ownership tool=$TOOL_NAME command=$(printf '%s' "$TOOL_COMMAND" | cut -c 1-180)"
    block "$REASON_TEXT"
fi

# Discussion is explicit, prompt-scoped, and cannot enable execution.
printf -v project_root_arg '%q' "$PWD"
printf -v bind_tool_arg '%q' "$BIND_TOOL"
printf -v task_arg '%q' "$(basename "$PLAN_DIR")"
EXPECTED_DISCUSS="PWF_PROJECT_ROOT=$project_root_arg bash $bind_tool_arg discuss $task_arg"
printf -v plan_arg '%q' "$PLAN_DIR/tasks.md"
printf -v state_arg '%q' "$PLAN_STATE_TOOL"
MAINTENANCE_ACTION="Run: python3 $state_arg budgets $plan_arg. Then archive/consolidate completed material in the owned plan; preserve unfinished work."
if [ "$TOOL_COMMAND" = "$EXPECTED_DISCUSS" ]; then
    printf '{}'; exit 0
fi
if [ "$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" route-status "$PROVIDER" "$SESSION_ID")" = "discussing" ]; then
    if maintenance_tool_allowed "$PLAN_DIR"; then
        printf '{}'; exit 0
    fi
    block "[plan-files] DISCUSSION ONLY. Reads, questions, and owned-plan maintenance are allowed; execution requires a new user prompt and bind. The candidate and unfinished work are preserved."
fi
DISCUSSION_HINT="If the user requested only discussion of this plan/workflow, run exactly: $EXPECTED_DISCUSS. This permits a discussion Stop while keeping execution gated; do not use it to pause authorized implementation."

# The gate recognizes a repair/checkpoint call from its tool input, never from
# a script or tool name, so a block message must state that condition instead
# of naming a category the agent cannot act on. Without it, a call that is
# morally "plan-local repair" but names nothing -- `plan_edit.py --help`, a
# version probe -- reads as a broken gate rather than as a call the classifier
# simply cannot see.
ALLOWED_HINT="Still allowed, recognized from the tool input rather than from a tool or script name: (1) calls that are demonstrably read-only; (2) calls whose input targets or explicitly names the owned plan directory $PLAN_DIR. So pass --plan $PLAN_DIR/tasks.md on repair/checkpoint commands; a bare --help or a version probe names nothing and is blocked like any other unrecognized call."

# Contracted plans fail closed for operational mutations when item state is
# invalid. Read-only diagnosis and plan-local repair/checkpoint calls remain
# available so the agent can repair the state instead of claiming a blocker.
ITEM_ISSUE=""
if grep -qE '^## Active Item[[:space:]]*$' "$PLAN_DIR/tasks.md" 2>/dev/null; then
    if command -v python3 >/dev/null 2>&1 && [ -f "$PLAN_STATE_TOOL" ]; then
        ITEM_ISSUE=$(python3 "$PLAN_STATE_TOOL" validate "$PLAN_DIR/tasks.md" 2>/dev/null || true)
    else
        ITEM_ISSUE=ITEM_STATE_TOOL_UNAVAILABLE
    fi
fi
if [ -n "$ITEM_ISSUE" ]; then
    if [ -n "$MUTATION_PLAN" ] || maintenance_tool_allowed "$PLAN_DIR"; then
        log "session=$SESSION_ID plan=$(basename "$PLAN_DIR") item_issue=$ITEM_ISSUE decision=allow-item-repair tool=$TOOL_NAME"
        printf '{}'
        exit 0
    fi
    REASON_TEXT="[plan-files] ITEM STATE ACTION REQUIRED ($ITEM_ISSUE). Operational mutation is blocked until the owned plan has one valid unchecked Active Item in Current Phase with phase-matching unique P/V IDs and Evidence lines. $ALLOWED_HINT Repair/start the item, then retry this tool; do not report an external blocker."
    log "session=$SESSION_ID plan=$(basename "$PLAN_DIR") item_issue=$ITEM_ISSUE decision=block-item-state tool=$TOOL_NAME"
    block "$REASON_TEXT"
fi

COMPACTION_WARN=$(budget_warning "$PLAN_DIR")
if [ -n "$COMPACTION_WARN" ]; then
    if maintenance_tool_allowed "$PLAN_DIR"; then
        log "session=$SESSION_ID plan=$(basename "$PLAN_DIR") maintenance=required decision=allow-maintenance tool=$TOOL_NAME"
        printf '{}'
        exit 0
    fi
    REASON_TEXT="[plan-files] MAINTENANCE ACTION REQUIRED. $MAINTENANCE_ACTION Allowed: read-only diagnosis, questions, and owned-plan maintenance. Blocked: outside writes and unknown calls. Include the owned plan path in repair commands; every recognized write target must remain inside it. Budgets are rechecked each call. $COMPACTION_WARN $DISCUSSION_HINT"
    log "session=$SESSION_ID plan=$(basename "$PLAN_DIR") maintenance=required decision=block-compaction tool=$TOOL_NAME command=$(printf '%s' "$TOOL_COMMAND" | cut -c 1-180)"
    block "$REASON_TEXT"
fi

RESTORE_WARN=$(restore_warning "$PLAN_DIR")
if [ -n "$RESTORE_WARN" ]; then
    if [ -n "$MUTATION_PLAN" ] || maintenance_tool_allowed "$PLAN_DIR"; then
        log "session=$SESSION_ID plan=$(basename "$PLAN_DIR") restore=required decision=allow-restore-repair tool=$TOOL_NAME"
        printf '{}'
        exit 0
    fi
    REASON_TEXT="$RESTORE_WARN Operational mutation waits until restore-check passes. $ALLOWED_HINT"
    log "session=$SESSION_ID plan=$(basename "$PLAN_DIR") restore=required decision=block-restore-state tool=$TOOL_NAME"
    block "$REASON_TEXT"
fi

log "session=$SESSION_ID plan=$(basename "$PLAN_DIR") maintenance=ok restore=ok decision=allow tool=$TOOL_NAME"
printf '{}'
