#!/usr/bin/env bash
# Session-owned routing for planning-with-files hooks and agents.

set -u
set -o pipefail 2>/dev/null || true

if [ -n "${PWF_PROJECT_ROOT:-}" ]; then
    if PROJECT_ROOT=$(git -C "$PWF_PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null); then
        :
    else
        PROJECT_ROOT=$PWF_PROJECT_ROOT
    fi
elif PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    :
else
    PROJECT_ROOT=$PWD
fi

PLAN_ROOT="$PROJECT_ROOT/tmp/plan-with-files"
SESSION_ROOT="$PLAN_ROOT/.sessions"

valid_task_id() {
    printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9._-]+$' \
        && [ "$1" != "." ] && [ "$1" != ".." ]
}

valid_adapter_id() {
    printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
}

valid_session_id() {
    printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9._:-]{1,240}$'
}

digest() {
    local value=$1
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$value" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s' "$value" | openssl dgst -sha256 | sed 's/^.*= //'
    else
        return 1
    fi
}

route_file() {
    local adapter_id=${1:-} session_id=${2:-} key
    valid_adapter_id "$adapter_id" || return 1
    valid_session_id "$session_id" || return 1
    key=$(digest "$adapter_id:$session_id") || return 1
    printf '%s/%s/%s.state' "$SESSION_ROOT" "$adapter_id" "$key"
}

read_value() {
    local file=$1 key=$2
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file" 2>/dev/null
}

task_exists() {
    local task_id=${1:-}
    valid_task_id "$task_id" && [ -f "$PLAN_ROOT/$task_id/tasks.md" ]
}

pointer_candidate() {
    local pointer="$PROJECT_ROOT/.plan-with-files" task_id
    [ -f "$pointer" ] || return 1
    task_id=$(head -n 1 "$pointer" 2>/dev/null | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    task_exists "$task_id" || return 1
    printf '%s' "$task_id"
}

write_route() {
    local file=$1 status=$2 task=${3:-} candidate=${4:-} tmp
    mkdir -p "$(dirname "$file")" || return 1
    tmp="$file.tmp.$$"
    umask 077
    {
        printf 'status=%s\n' "$status"
        if [ -n "$task" ]; then
            printf 'task=%s\n' "$task"
        fi
        if [ -n "$candidate" ]; then
            printf 'candidate=%s\n' "$candidate"
        fi
    } > "$tmp" && mv "$tmp" "$file"
}

mark_pending() {
    local adapter_id=$1 session_id=$2 preferred=${3:-} file status candidate=""
    file=$(route_file "$adapter_id" "$session_id") || return 1
    if [ -f "$file" ]; then
        status=$(read_value "$file" status)
        case "$status" in
            owned) candidate=$(read_value "$file" task) ;;
            pending) candidate=$(read_value "$file" candidate) ;;
        esac
    fi
    if ! task_exists "$candidate"; then
        if task_exists "$preferred"; then
            candidate=$preferred
        else
            candidate=$(pointer_candidate 2>/dev/null || true)
        fi
    fi
    write_route "$file" pending "" "$candidate" || return 1
    printf '%s' "$candidate"
}

claim_task() {
    local adapter_id=$1 session_id=$2 task_id=$3 file lock status current="" result=0
    if [ "${PLANNING_DISABLED:-0}" = "1" ] || [ -e "$PROJECT_ROOT/.plan-with-files-skip" ]; then
        printf 'planning-with-files is disabled for this project or session\n' >&2
        return 1
    fi
    task_exists "$task_id" || {
        printf 'invalid or missing planning task: %s\n' "$task_id" >&2
        return 1
    }
    file=$(route_file "$adapter_id" "$session_id") || return 1
    mkdir -p "$(dirname "$file")" || return 1
    lock="$file.claim.lock"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$lock"
        if ! flock -n 9; then
            printf 'planning lease claim is already in progress\n' >&2
            exec 9>&-
            return 4
        fi
    fi

    if [ -f "$file" ]; then
        status=$(read_value "$file" status)
        case "$status" in
            owned) current=$(read_value "$file" task) ;;
            pending) current=$(read_value "$file" candidate) ;;
            *)
                printf 'planning lease has an invalid state\n' >&2
                result=3
                ;;
        esac
        if [ -n "$current" ] && [ "$current" != "$task_id" ]; then
            printf 'planning lease conflicts with task: %s\n' "$current" >&2
            result=3
        fi
    fi

    if [ "$result" -eq 0 ]; then
        write_route "$file" owned "$task_id" "" || result=1
    fi
    if command -v flock >/dev/null 2>&1; then
        flock -u 9 2>/dev/null || true
        exec 9>&-
    fi
    [ "$result" -eq 0 ] || return "$result"
    printf '%s/%s' "$PLAN_ROOT" "$task_id"
}

resolve_owned() {
    local adapter_id=$1 session_id=$2 file status task
    file=$(route_file "$adapter_id" "$session_id") || return 1
    [ -f "$file" ] || return 1
    status=$(read_value "$file" status)
    [ "$status" = "owned" ] || return 1
    task=$(read_value "$file" task)
    task_exists "$task" || return 1
    printf '%s/%s' "$PLAN_ROOT" "$task"
}

pending_candidate() {
    local adapter_id=$1 session_id=$2 file status candidate
    file=$(route_file "$adapter_id" "$session_id") || return 1
    [ -f "$file" ] || return 1
    status=$(read_value "$file" status)
    [ "$status" = "pending" ] || return 1
    candidate=$(read_value "$file" candidate)
    task_exists "$candidate" || return 1
    printf '%s' "$candidate"
}

cache_file() {
    local file
    file=$(route_file "$1" "$2") || return 1
    [ "$(read_value "$file" status)" = "owned" ] || return 1
    printf '%s.hook-state' "${file%.state}"
}

current_identity() {
    [ -n "${PWF_SESSION_ADAPTER:-}" ] && [ -n "${PWF_SESSION_ID:-}" ] || return 1
    valid_adapter_id "$PWF_SESSION_ADAPTER" && valid_session_id "$PWF_SESSION_ID" || return 1
    printf '%s\t%s' "$PWF_SESSION_ADAPTER" "$PWF_SESSION_ID"
}

bind_current() {
    local task_id=$1 identity adapter_id session_id file status
    if [ "${PLANNING_DISABLED:-0}" = "1" ] || [ -e "$PROJECT_ROOT/.plan-with-files-skip" ]; then
        printf 'planning-with-files is disabled for this project or session\n' >&2
        return 1
    fi
    task_exists "$task_id" || {
        printf 'invalid or missing planning task: %s\n' "$task_id" >&2
        return 1
    }
    identity=$(current_identity) || {
        printf 'no verified planning session identity is available\n' >&2
        return 1
    }
    adapter_id=${identity%%$'\t'*}
    session_id=${identity#*$'\t'}
    file=$(route_file "$adapter_id" "$session_id") || return 1
    [ -f "$file" ] || {
        printf 'no pending planning lease; submit a new prompt before binding\n' >&2
        return 1
    }
    status=$(read_value "$file" status)
    [ "$status" = "pending" ] || {
        printf 'planning lease is not awaiting a scope decision\n' >&2
        return 1
    }
    write_route "$file" owned "$task_id" "" || return 1
    printf 'planning task bound for this prompt: %s\n' "$task_id"
}

release_current() {
    local task_id=$1 identity adapter_id session_id file candidate pointer_id=""
    if [ "${PLANNING_DISABLED:-0}" = "1" ] || [ -e "$PROJECT_ROOT/.plan-with-files-skip" ]; then
        printf 'planning-with-files is disabled for this project or session\n' >&2
        return 1
    fi
    valid_task_id "$task_id" || {
        printf 'invalid planning task id: %s\n' "$task_id" >&2
        return 1
    }
    identity=$(current_identity) || {
        printf 'no verified planning session identity is available\n' >&2
        return 1
    }
    adapter_id=${identity%%$'\t'*}
    session_id=${identity#*$'\t'}
    file=$(route_file "$adapter_id" "$session_id") || return 1
    candidate=$(pending_candidate "$adapter_id" "$session_id" 2>/dev/null || true)
    [ "$candidate" = "$task_id" ] || {
        printf 'planning lease is not pending for candidate: %s\n' "$task_id" >&2
        return 1
    }

    if [ -f "$PROJECT_ROOT/.plan-with-files" ]; then
        pointer_id=$(head -n 1 "$PROJECT_ROOT/.plan-with-files" 2>/dev/null \
            | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi

    rm -f "$file" "${file%.state}.hook-state" "${file%.state}.hook-state.lock"
    if [ "$pointer_id" = "$task_id" ]; then
        : > "$PROJECT_ROOT/.plan-with-files"
        printf 'planning candidate released and pointer cleared: %s\n' "$task_id"
    else
        printf 'planning candidate released; pointer left unchanged: %s\n' "$task_id"
    fi
}

extract_section() {
    local file=$1 name=$2 max_chars=$3 text
    text=$(awk -v name="$name" '
      $0 ~ "^## " name "[[:space:]]*$" { capture=1; next }
      /^## / { capture=0 }
      capture { print }
    ' "$file" 2>/dev/null \
        | awk 'BEGIN{comment=0} /<!--/{comment=1} comment==0{print} /-->/{comment=0}' \
        | sed -e '/./,$!d' \
        | awk 'NF { last=NR } { lines[NR]=$0 } END { for (i=1;i<=last;i++) print lines[i] }')
    if [ ${#text} -gt "$max_chars" ]; then
        printf '%s\n[truncated; read the section after binding]' "$(printf '%s' "$text" | cut -c 1-"$max_chars")"
    else
        printf '%s' "$text"
    fi
}

candidate_context() {
    local task_id=$1 bind_tool=$2 file identity goal project_root_arg bind_tool_arg task_arg
    task_exists "$task_id" || return 1
    file="$PLAN_ROOT/$task_id/tasks.md"
    identity=$(extract_section "$file" 'Task Identity' 700)
    goal=$(extract_section "$file" 'Goal' 700)
    [ -n "$identity$goal" ] || return 1
    printf '%s\n' "[planning-with-files] Candidate task '$task_id' is not owned for this prompt. Scope-check it before loading any other planning file."
    if [ -n "$identity" ]; then
        printf '\n## Task Identity\n%s\n' "$identity"
    fi
    if [ -n "$goal" ]; then
        printf '\n## Goal\n%s\n' "$goal"
    fi
    printf -v project_root_arg '%q' "$PROJECT_ROOT"
    printf -v bind_tool_arg '%q' "$bind_tool"
    printf -v task_arg '%q' "$task_id"
    printf '\n%s\n' "Classify the latest request using deterministic identity evidence first, then semantics: SAME, DIFFERENT, or AMBIGUOUS. A pending candidate MUST be resolved before any tool use: bind it for SAME, or release it when you will not continue it."
    printf '%s\n' "- SAME: run \`PWF_PROJECT_ROOT=$project_root_arg bash $bind_tool_arg bind $task_arg\` before reading tasks.md, decisions.md, findings.md, or handoff.md."
    printf '%s\n' "- DIFFERENT: first run \`PWF_PROJECT_ROOT=$project_root_arg bash $bind_tool_arg release $task_arg\`; this clears .plan-with-files only if it still points to this candidate. Then continue separately, creating/binding a new plan only if needed."
    printf '%s\n' "- AMBIGUOUS: ask the user before mutating or switching a plan. If you must stop while waiting, release this candidate first so no unresolved pointer survives the turn."
}

extract_session_id() {
    local value
    if command -v jq >/dev/null 2>&1; then
        value=$(jq -jer '
          if type == "object" then (.session_id // .sessionId // empty) else empty end
          | select(type == "string")
        ' 2>/dev/null) || return 1
    elif command -v python3 >/dev/null 2>&1; then
        value=$(python3 -c '
import json
import sys

payload = json.load(sys.stdin)
value = None
if isinstance(payload, dict):
    value = payload.get("session_id") or payload.get("sessionId")
if isinstance(value, str):
    sys.stdout.write(value)
' 2>/dev/null) || return 1
    elif command -v node >/dev/null 2>&1; then
        value=$(node -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const payload = JSON.parse(input);
  const value = payload && typeof payload === "object"
    ? (payload.session_id || payload.sessionId)
    : null;
  if (typeof value === "string") process.stdout.write(value);
});
' 2>/dev/null) || return 1
    else
        return 1
    fi
    valid_session_id "$value" || return 1
    printf '%s' "$value"
}

command=${1:-}
case "$command" in
    session-id)
        extract_session_id
        ;;
    pending)
        { [ "$#" -eq 3 ] || [ "$#" -eq 4 ]; } || exit 2
        mark_pending "$2" "$3" "${4:-}"
        ;;
    claim)
        [ "$#" -eq 4 ] || exit 2
        claim_task "$2" "$3" "$4"
        ;;
    resolve)
        [ "$#" -eq 3 ] || exit 2
        resolve_owned "$2" "$3"
        ;;
    pending-candidate)
        [ "$#" -eq 3 ] || exit 2
        pending_candidate "$2" "$3"
        ;;
    cache)
        [ "$#" -eq 3 ] || exit 2
        cache_file "$2" "$3"
        ;;
    bind)
        [ "$#" -eq 2 ] || exit 2
        bind_current "$2"
        ;;
    release)
        [ "$#" -eq 2 ] || exit 2
        release_current "$2"
        ;;
    candidate-context)
        [ "$#" -eq 3 ] || exit 2
        candidate_context "$2" "$3"
        ;;
    *)
        printf 'usage: %s {bind TASK_ID|release TASK_ID|pending ADAPTER_ID SESSION_ID [PREFERRED_TASK_ID]|claim ADAPTER_ID SESSION_ID TASK_ID|pending-candidate ADAPTER_ID SESSION_ID|resolve ADAPTER_ID SESSION_ID|cache ADAPTER_ID SESSION_ID|session-id|candidate-context TASK_ID BIND_TOOL}\n' "$0" >&2
        exit 2
        ;;
esac
