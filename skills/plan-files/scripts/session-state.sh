#!/usr/bin/env bash
# Session-owned routing for plan-files hooks and agents.

set -u
set -o pipefail 2>/dev/null || true

# `git rev-parse --show-toplevel` alone is not enough to name a workspace
# root: it returns a submodule's own working tree when cwd is inside one, and
# has no notion of "root" at all for a plain (non-git) folder that merely
# contains several independent git checkouts. Delegate to the shared resolver,
# which prefers an existing `.plan-files` (outermost match wins) and only
# falls back to git-toplevel/superproject detection when none exists anywhere.
_SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(bash "$_SCRIPT_DIR/resolve-project-root.sh" "${PWF_PROJECT_ROOT:-$PWD}")

# Pre-rename layout. Plans created before the plan-files rename still live in
# tmp/plan-with-files/ with a .plan-with-files pointer, and silently ignoring
# them would strand real, resumable work. New state is always written under the
# current names; the legacy path is only adopted when it is the only one there.
LEGACY_DIR_NAME="plan-with-files"
PLAN_ROOT="$PROJECT_ROOT/tmp/plan-files"
if [ ! -d "$PLAN_ROOT" ] && [ -d "$PROJECT_ROOT/tmp/$LEGACY_DIR_NAME" ]; then
    PLAN_ROOT="$PROJECT_ROOT/tmp/$LEGACY_DIR_NAME"
fi
POINTER_FILE="$PROJECT_ROOT/.plan-files"
if [ ! -e "$POINTER_FILE" ] && [ -e "$PROJECT_ROOT/.$LEGACY_DIR_NAME" ]; then
    POINTER_FILE="$PROJECT_ROOT/.$LEGACY_DIR_NAME"
fi
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
    local pointer="$POINTER_FILE" task_id
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
    } > "$tmp" && mv "$tmp" "$file" || return 1
    # A feedback exception never carries across a prompt/ownership transition.
    python3 "$_SCRIPT_DIR/feedback_transport.py" clear "$file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# write_pointer TASK_ID
# Updates the human-facing `.plan-files` default-candidate pointer to
# TASK_ID whenever a session becomes the confirmed owner of it (claim_task,
# bind_current). This assumes at most one agent works in a project at a
# time — the pointer stays a convenience default, never the source of truth
# hooks gate on (that remains the per-session lease file), but it now
# reliably names "what's currently active" instead of depending on the agent
# remembering to update it by hand. Best-effort: never fails the caller.
# ---------------------------------------------------------------------------
write_pointer() {
    local task_id=$1
    printf '%s\n' "$task_id" > "$POINTER_FILE" 2>/dev/null || true
}

mark_pending() {
    local adapter_id=$1 session_id=$2 preferred=${3:-} file status candidate=""
    file=$(route_file "$adapter_id" "$session_id") || return 1
    if [ -f "$file" ]; then
        status=$(read_value "$file" status)
        case "$status" in
            owned|discussing) candidate=$(read_value "$file" task) ;;
            pending|waiting) candidate=$(read_value "$file" candidate) ;;
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
    if [ "${PLANNING_DISABLED:-0}" = "1" ] || [ -e "$PROJECT_ROOT/.plan-files-skip" ] || [ -e "$PROJECT_ROOT/.plan-with-files-skip" ]; then
        printf 'plan-files is disabled for this project or session\n' >&2
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
        [ "$result" -eq 0 ] && write_pointer "$task_id"
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
    { [ "$status" = "owned" ] || [ "$status" = "discussing" ]; } || return 1
    task=$(read_value "$file" task)
    task_exists "$task" || return 1
    printf '%s/%s' "$PLAN_ROOT" "$task"
}

pending_candidate() {
    local adapter_id=$1 session_id=$2 file status candidate
    file=$(route_file "$adapter_id" "$session_id") || return 1
    [ -f "$file" ] || return 1
    status=$(read_value "$file" status)
    { [ "$status" = "pending" ] || [ "$status" = "waiting" ]; } || return 1
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
    if [ "${PLANNING_DISABLED:-0}" = "1" ] || [ -e "$PROJECT_ROOT/.plan-files-skip" ] || [ -e "$PROJECT_ROOT/.plan-with-files-skip" ]; then
        printf 'plan-files is disabled for this project or session\n' >&2
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
        printf 'no pending planning lease; submit a new prompt before binding. If you just created this task'"'"'s tasks.md, ownership is auto-claimed once the write completes -- run "resolve" to check, do not hand-edit .plan-files.\n' >&2
        return 1
    }
    status=$(read_value "$file" status)
    { [ "$status" = "pending" ] || [ "$status" = "waiting" ]; } || {
        printf 'planning lease is not awaiting a scope decision -- it is likely already owned (auto-claimed when this task'"'"'s plan file was created/edited) or settled; this bind call is unnecessary. Run "resolve" to confirm ownership instead of hand-editing .plan-files.\n' >&2
        return 1
    }
    write_route "$file" owned "$task_id" "" || return 1
    write_pointer "$task_id"
    printf 'planning task bound for this prompt: %s\n' "$task_id"
}

# An explicit clarification yields the prompt without rejecting its candidate.
# Waiting is deliberately not claimable: only an explicit bind can resume it.
clarify_current() {
    local task_id=$1 identity adapter_id session_id file candidate
    [ "${PLANNING_DISABLED:-0}" != "1" ] && [ ! -e "$PROJECT_ROOT/.plan-files-skip" ] || return 1
    identity=$(current_identity) || return 1
    adapter_id=${identity%%$'\t'*}
    session_id=${identity#*$'\t'}
    candidate=$(pending_candidate "$adapter_id" "$session_id") || return 1
    [ "$candidate" = "$task_id" ] || return 1
    file=$(route_file "$adapter_id" "$session_id") || return 1
    write_route "$file" waiting "" "$candidate" || return 1
    printf 'planning candidate preserved: %s; ask the user now, then wait for their answer.\n' "$candidate"
}

# A user-requested discussion turn retains the task while gating execution.
# A fresh prompt must scope-check again before implementation can resume.
discuss_current() {
    local task_id=$1 identity adapter_id session_id file owned
    [ "${PLANNING_DISABLED:-0}" != "1" ] && [ ! -e "$PROJECT_ROOT/.plan-files-skip" ] || return 1
    identity=$(current_identity) || return 1
    adapter_id=${identity%%$'\t'*}
    session_id=${identity#*$'\t'}
    owned=$(resolve_owned "$adapter_id" "$session_id") || return 1
    [ "$(basename "$owned")" = "$task_id" ] || return 1
    file=$(route_file "$adapter_id" "$session_id") || return 1
    write_route "$file" discussing "$task_id" "" || return 1
    printf 'planning discussion only: %s; execution is gated until a new prompt is bound.\n' "$task_id"
}

route_status() {
    local file
    file=$(route_file "$1" "$2") || return 1
    read_value "$file" status
}

feedback_file() {
    local file
    file=$(route_file "$1" "$2") || return 1
    python3 "$_SCRIPT_DIR/feedback_transport.py" path "$file"
}

finish_task() {
    # Stand down a lease the session genuinely owns, after every phase completed.
    # release_current only accepts a *pending* candidate (the interactive prompt
    # state); at Stop time the lease is `owned`, so finishing needs its own verb.
    # Deliberately quiet and idempotent: it runs from a Stop hook, where noise or
    # a non-zero exit would be worse than leaving the lease in place.
    local adapter_id=$1 session_id=$2 task_id=$3 file status owner
    valid_task_id "$task_id" || return 1
    file=$(route_file "$adapter_id" "$session_id") || return 1
    [ -f "$file" ] || return 0
    status=$(read_value "$file" status)
    owner=$(read_value "$file" task)
    [ "$status" = "owned" ] || return 0
    [ "$owner" = "$task_id" ] || return 0
    # Only the lease is stood down. The pointer stays whatever the agent left
    # it: --deactivate-pointer already clears it deliberately on the final
    # complete call, and clearing it here too would erase BOTH signals, leaving
    # a finished plan the user cannot refer back to in their next message.
    rm -f "$file" "${file%.state}.hook-state" "${file%.state}.hook-state.lock"
    python3 "$_SCRIPT_DIR/feedback_transport.py" clear "$file" 2>/dev/null || true
    return 0
}

release_current() {
    local task_id=$1 identity adapter_id session_id file candidate pointer_id=""
    if [ "${PLANNING_DISABLED:-0}" = "1" ] || [ -e "$PROJECT_ROOT/.plan-files-skip" ] || [ -e "$PROJECT_ROOT/.plan-with-files-skip" ]; then
        printf 'plan-files is disabled for this project or session\n' >&2
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

    if [ -f "$POINTER_FILE" ]; then
        pointer_id=$(head -n 1 "$POINTER_FILE" 2>/dev/null \
            | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi

    rm -f "$file" "${file%.state}.hook-state" "${file%.state}.hook-state.lock"
    python3 "$_SCRIPT_DIR/feedback_transport.py" clear "$file" 2>/dev/null || true
    if [ "$pointer_id" = "$task_id" ]; then
        : > "$POINTER_FILE"
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
    printf -v project_root_arg '%q' "$PROJECT_ROOT"
    printf -v bind_tool_arg '%q' "$bind_tool"
    printf -v task_arg '%q' "$task_id"
    printf '%s\n' "[plan-files] OWNERSHIP ACTION REQUIRED for this prompt. Continue/implement this plan = SAME, even after research. Resolve ownership before other tools; this is not an external blocker."
    printf '%s\n' "- SAME: run \`PWF_PROJECT_ROOT=$project_root_arg bash $bind_tool_arg bind $task_arg\`."
    printf '%s\n' "- DIFFERENT: first run \`PWF_PROJECT_ROOT=$project_root_arg bash $bind_tool_arg release $task_arg\` only for a separate goal. This may clear the candidate pointer."
    printf '%s\n' "- AMBIGUOUS: run \`PWF_PROJECT_ROOT=$project_root_arg bash $bind_tool_arg clarify $task_arg\`, then ask and wait. This keeps the candidate and blocks work; do not release it."
    printf '%s\n' "After bind: overview, restore-check, then targeted reads; reconcile user-authorized scope changes before implementation. After release: continue separately. Never release merely to bypass a gate."
    printf '\n%s\n' "Candidate task '$task_id' is not owned for this prompt. A previous prompt's bind does not carry forward. Non-goals still apply unless the user supersedes them."
    if [ -n "$identity" ]; then
        printf '\n## Task Identity\n%s\n' "$identity"
    fi
    if [ -n "$goal" ]; then
        printf '\n## Goal\n%s\n' "$goal"
    fi
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
    finish)
        [ "$#" -eq 4 ] || { printf 'usage: %s finish ADAPTER_ID SESSION_ID TASK_ID\n' "$0" >&2; exit 2; }
        finish_task "$2" "$3" "$4"
        ;;
    release)
        [ "$#" -eq 2 ] || exit 2
        release_current "$2"
        ;;
    discuss)
        [ "$#" -eq 2 ] || exit 2
        discuss_current "$2"
        ;;
    clarify)
        [ "$#" -eq 2 ] || exit 2
        clarify_current "$2"
        ;;
    route-status)
        [ "$#" -eq 3 ] || exit 2
        route_status "$2" "$3"
        ;;
    feedback-file)
        [ "$#" -eq 3 ] || exit 2
        feedback_file "$2" "$3"
        ;;
    candidate-context)
        [ "$#" -eq 3 ] || exit 2
        candidate_context "$2" "$3"
        ;;
    *)
        printf 'usage: %s {bind TASK_ID|release TASK_ID|clarify TASK_ID|discuss TASK_ID|route-status ADAPTER_ID SESSION_ID|finish ADAPTER_ID SESSION_ID TASK_ID|pending ADAPTER_ID SESSION_ID [PREFERRED_TASK_ID]|claim ADAPTER_ID SESSION_ID TASK_ID|pending-candidate ADAPTER_ID SESSION_ID|resolve ADAPTER_ID SESSION_ID|cache ADAPTER_ID SESSION_ID|session-id|candidate-context TASK_ID BIND_TOOL}\n' "$0" >&2
        exit 2
        ;;
esac
