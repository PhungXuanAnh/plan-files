#!/usr/bin/env bash
# Shared PreToolUse ownership + planning-maintenance gate.

set -u
set -o pipefail 2>/dev/null || true

PROVIDER=${1:-}
BIND_TOOL=${2:-}
LABEL=${3:-$PROVIDER}
INPUT=$(cat)
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
STATE_TOOL="$SCRIPT_DIR/session-state.sh"
LOG_DIR="tmp/hook-logs/plan-with-files"
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
          if (.tool_input | type) == "object" then
            (.tool_input.command // .tool_input.cmd // empty)
          elif (.tool_input | type) == "string" then
            .tool_input
          else empty end
          | select(type == "string")
        ' 2>/dev/null || true)
    elif command -v python3 >/dev/null 2>&1; then
        command=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: p=json.load(sys.stdin)
except Exception: raise SystemExit(0)
v=p.get("tool_input") if isinstance(p,dict) else None
if isinstance(v,dict): v=v.get("command") or v.get("cmd")
if isinstance(v,str): sys.stdout.write(v)' 2>/dev/null || true)
    elif command -v node >/dev/null 2>&1; then
        command=$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.setEncoding("utf8");process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const p=JSON.parse(s);let v=p&&p.tool_input;if(v&&typeof v==="object")v=v.command||v.cmd;if(typeof v==="string")process.stdout.write(v)}catch(_){}})' 2>/dev/null || true)
    fi
    printf '%s' "$command" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

budget_warning() {
    local plan_dir=$1 items="" name path lines bytes line_limit byte_limit phase_count item
    for name in tasks.md findings.md decisions.md handoff.md; do
        path="$plan_dir/$name"
        [ -f "$path" ] || continue
        case "$name" in
            tasks.md) line_limit=150; byte_limit=12288 ;;
            findings.md) line_limit=250; byte_limit=32768 ;;
            decisions.md) line_limit=150; byte_limit=12288 ;;
            handoff.md) line_limit=50; byte_limit=6144 ;;
        esac
        lines=$(wc -l < "$path" 2>/dev/null | tr -d ' ' || echo 0)
        bytes=$(wc -c < "$path" 2>/dev/null | tr -d ' ' || echo 0)
        lines=${lines:-0}; bytes=${bytes:-0}
        if [ "$lines" -gt "$line_limit" ] || [ "$bytes" -gt "$byte_limit" ]; then
            item="${name}=${lines}/${line_limit} lines;${bytes}/${byte_limit} bytes"
            [ -n "$items" ] && items="${items}, ${item}" || items="$item"
        fi
    done
    if [ -f "$plan_dir/tasks.md" ]; then
        phase_count=$(grep -Ec '^### Phase[[:space:]]+[0-9]+:' "$plan_dir/tasks.md" 2>/dev/null || true)
        phase_count=${phase_count:-0}
        if [ "$phase_count" -gt 12 ]; then
            item="tasks.md=${phase_count}/12 phase entries"
            [ -n "$items" ] && items="${items}, ${item}" || items="$item"
        fi
    fi
    [ -z "$items" ] || printf '[planning-with-files] COMPACTION NEEDED (actual/target): %s. Keep hot current state; move older completed phases, completed verification, and resolved-error summaries to history.md; consolidate findings/decisions by lifecycle; overwrite handoff.md instead of appending. Split independent follow-up work into another task. Never raw-truncate.' "$items"
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
    printf '{"decision":"block","reason":%s}' "$(json_escape "$reason")"
    exit 0
}

TOOL_NAME=$(extract_tool_name)
TOOL_INPUT_JSON=$(extract_tool_input_json)
log "event=PreToolUse input_bytes=${#INPUT}"
log "tool_call tool_name=$TOOL_NAME tool_input=$TOOL_INPUT_JSON"
[ -n "$PROVIDER" ] && [ -x "$BIND_TOOL" ] || { log "decision=allow reason=invalid-adapter-config"; printf '{}'; exit 0; }
[ "${PLANNING_DISABLED:-0}" != "1" ] && [ ! -e .plan-with-files-skip ] \
    || { log "decision=allow reason=planning-disabled"; printf '{}'; exit 0; }

SESSION_ID=$(printf '%s' "$INPUT" | "$STATE_TOOL" session-id 2>/dev/null || true)
[ -n "$SESSION_ID" ] || { log "decision=allow reason=no-verified-session"; printf '{}'; exit 0; }

TOOL_COMMAND=$(extract_tool_command)
MUTATION_STATUS=0
MUTATION_PLAN=$(mutation_plan_id 2>/dev/null) || MUTATION_STATUS=$?
if [ "$MUTATION_STATUS" -eq 2 ]; then
    REASON_TEXT="[planning-with-files] PLAN MUTATION BLOCKED. This tool call targets Markdown in more than one planning task. Split it into one plan directory per call so session ownership is deterministic."
    log "session=$SESSION_ID decision=block-ambiguous-plan-mutation tool=$TOOL_NAME"
    block "$REASON_TEXT"
fi

PLAN_DIR=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" resolve "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)

if [ -n "$MUTATION_PLAN" ]; then
    if [ -n "$PLAN_DIR" ]; then
        OWNED_PLAN=$(basename "$PLAN_DIR")
        if [ "$OWNED_PLAN" != "$MUTATION_PLAN" ]; then
            REASON_TEXT="[planning-with-files] PLAN MUTATION BLOCKED. This session owns '$OWNED_PLAN', but the tool call targets plan '$MUTATION_PLAN'. Finish/release the current scope or use the correct session; ownership will not switch silently."
            log "session=$SESSION_ID owned=$OWNED_PLAN target=$MUTATION_PLAN decision=block-plan-conflict tool=$TOOL_NAME"
            block "$REASON_TEXT"
        fi
    else
        CLAIM_STATUS=0
        PLAN_DIR=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" claim \
            "$PROVIDER" "$SESSION_ID" "$MUTATION_PLAN" 2>/dev/null) || CLAIM_STATUS=$?
        if [ "$CLAIM_STATUS" -ne 0 ] || [ -z "$PLAN_DIR" ]; then
            CURRENT_SCOPE=$(PWF_PROJECT_ROOT="$PWD" "$STATE_TOOL" pending-candidate \
                "$PROVIDER" "$SESSION_ID" 2>/dev/null || true)
            [ -n "$CURRENT_SCOPE" ] || CURRENT_SCOPE="another task or concurrent claim"
            REASON_TEXT="[planning-with-files] PLAN MUTATION BLOCKED. The call targets '$MUTATION_PLAN', but this session is pending for $CURRENT_SCOPE. Resolve that ownership first; the hook will not overwrite it."
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
    if [ "$TOOL_COMMAND" = "$EXPECTED_BIND" ]; then
        log "session=$SESSION_ID candidate=$CANDIDATE decision=allow-exact-bind tool=$TOOL_NAME"
        printf '{}'; exit 0
    fi
    if [ "$TOOL_COMMAND" = "$EXPECTED_RELEASE" ]; then
        log "session=$SESSION_ID candidate=$CANDIDATE decision=allow-exact-release tool=$TOOL_NAME"
        printf '{}'; exit 0
    fi
    REASON_TEXT="[planning-with-files] OWNERSHIP ACTION REQUIRED (not a permission failure and not an external blocker). Candidate '$CANDIDATE' is pending for this prompt. Do not stop or report that the environment is blocked. Resolve ownership now by running exactly one action: SAME task -> $EXPECTED_BIND OR DIFFERENT task -> $EXPECTED_RELEASE. After bind/release succeeds, retry the original tool call."
    log "session=$SESSION_ID candidate=$CANDIDATE decision=block-ownership tool=$TOOL_NAME command=$(printf '%s' "$TOOL_COMMAND" | cut -c 1-180)"
    block "$REASON_TEXT"
fi

COMPACTION_WARN=$(budget_warning "$PLAN_DIR")
if [ -z "$COMPACTION_WARN" ]; then
    log "session=$SESSION_ID plan=$(basename "$PLAN_DIR") maintenance=ok decision=allow tool=$TOOL_NAME"
    printf '{}'
    exit 0
fi

if maintenance_tool_allowed "$PLAN_DIR"; then
    log "session=$SESSION_ID plan=$(basename "$PLAN_DIR") maintenance=required decision=allow-maintenance tool=$TOOL_NAME"
    printf '{}'
    exit 0
fi

REASON_TEXT="$COMPACTION_WARN Planning maintenance is mandatory before unrelated work. Allowed while compacting: (1) use any tool that is demonstrably read-only to inspect/search/read anywhere in the current project (for example Read, rg/grep/cat/head/tail, git status/diff/show/log, and Serena find/get/list/search tools); (2) use any mutation tool when its tool_input targets or explicitly references the owned plan directory $PLAN_DIR, including tasks.md, findings.md, decisions.md, handoff.md, and history.md. The gate does not require a specific mutation tool name; when explicit writable targets can be recognized, every target must stay inside that plan directory. Blocked until budgets clear: recognized mutations outside that plan folder and unknown calls that neither prove read-only behavior nor reference the owned plan directory. The gate re-checks budgets on every tool call."
log "session=$SESSION_ID plan=$(basename "$PLAN_DIR") maintenance=required decision=block-compaction tool=$TOOL_NAME command=$(printf '%s' "$TOOL_COMMAND" | cut -c 1-180)"
block "$REASON_TEXT"
