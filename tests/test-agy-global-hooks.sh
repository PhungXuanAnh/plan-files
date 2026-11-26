#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STATE_TOOL="$REPO_ROOT/skills/plan-files/scripts/session-state.sh"
AGY_SCRIPTS="$REPO_ROOT/.agy/hooks/plan-files/scripts"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
PROJECT="$TEST_DIR/project"
mkdir -p "$PROJECT/tmp/plan-files"
unset PWF_SESSION_ADAPTER PWF_SESSION_ID PWF_SESSION_OWNER CLAUDE_PROJECT_DIR

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3 (missing '$2')" ;; esac; }
assert_empty() { [ -z "$1" ] || fail "$2 (got '$1')"; }
json_value() { python3 -c 'import json,sys; value=json.load(sys.stdin); print(value'"$1"')'; }

write_plan() {
    local task=$1 state=$2 dir="$PROJECT/tmp/plan-files/$1" active=P1.1 mark=" " evidence=pending
    mkdir -p "$dir"
    if [ "$state" = complete ]; then active=""; mark=x; evidence="verified fixture"; fi
    cat > "$dir/tasks.md" <<EOF
# Tasks: $task

## Goal
Complete $task safely.

## Task Identity
- Deliverable: $task result
- Anchors: $task
- Non-goals: unrelated work

## Current Phase
Phase 1

## Active Item
$active

## Workflow Profile
**Profile:** C

## Resume Checkpoint
- **Next action:** Complete P1.1: finish $task
- **Blocker:** none
- **Details:** none

## Phases

### Phase 1: Work
- [$mark] [P1.1] Finish $task.
  - Evidence: $evidence
- **Status:** $state

## Verification
- fixture: current
EOF
}

# agy runs hooks from the hooks.json folder, not the project, and exports the conversation id.
hook() {
    local event=$1 session=$2 payload=$3
    (cd "$TEST_DIR" && printf '%s' "$payload" \
        | ANTIGRAVITY_CONVERSATION_ID="$session" python3 "$AGY_SCRIPTS/agy_adapter.py" "$event")
}
invocation() {
    hook PreInvocation "$1" "{\"conversationId\":\"$1\",\"cwd\":\"$PROJECT\",\"invocationNum\":$2,\"lastUserInput\":\"continue\"}"
}
tool() {
    local event=$1 session=$2 id=$3 name=$4 args=$5
    hook "$event" "$session" \
        "{\"conversationId\":\"$session\",\"cwd\":\"$PROJECT\",\"error\":\"\",\"toolCall\":{\"id\":\"$id\",\"name\":\"$name\",\"args\":$args}}"
}
command_args() { python3 -c 'import json,sys; print(json.dumps({"CommandLine": sys.argv[1]}))' "$1"; }
stop_hook() {
    hook Stop "$1" "{\"conversationId\":\"$1\",\"cwd\":\"$PROJECT\",\"terminationReason\":\"$2\",\"executionNum\":0}"
}
state() { PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" "$@"; }

# The installer owns only the plan-files name in agy's shared hooks.json and keeps a symlink a symlink.
mkdir -p "$TEST_DIR/agy-home" "$TEST_DIR/real"
printf '{"stop-slack":{"Stop":[{"type":"command","command":"true"}]}}\n' > "$TEST_DIR/real/hooks.json"
ln -s "$TEST_DIR/real/hooks.json" "$TEST_DIR/agy-home/hooks.json"
AGY_HOME="$TEST_DIR/agy-home" make -s -C "$REPO_ROOT" install-hook-agy >/dev/null
FIRST_SUM=$(sha256sum "$TEST_DIR/real/hooks.json" | cut -d' ' -f1)
AGY_HOME="$TEST_DIR/agy-home" make -s -C "$REPO_ROOT" install-hook-agy >/dev/null
assert_eq "$(sha256sum "$TEST_DIR/real/hooks.json" | cut -d' ' -f1)" "$FIRST_SUM" "repeat install is byte-idempotent"
[ -L "$TEST_DIR/agy-home/hooks.json" ] || fail "installer replaced the hooks.json symlink"
python3 - "$TEST_DIR/real/hooks.json" "$AGY_SCRIPTS/agy_adapter.py" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["stop-slack"]["Stop"][0]["command"] == "true", "other hook names are preserved"
entry = data["plan-files"]
for event in ("PreInvocation", "Stop"):
    assert entry[event][0]["command"] == f'python3 "{sys.argv[2]}" {event}', entry[event]
for event in ("PreToolUse", "PostToolUse"):
    assert entry[event][0]["hooks"][0]["command"] == f'python3 "{sys.argv[2]}" {event}', entry[event]
PY

write_plan task-a in_progress
printf 'task-a\n' > "$PROJECT/.plan-files"
state claim agy agy-one task-a >/dev/null

# The turn's first PreInvocation stands in for prompt submit and injects the candidate routing.
PROMPT=$(invocation agy-one 0)
assert_contains "$(printf '%s' "$PROMPT" | json_value '["injectSteps"][0]["systemMessage"]["systemMessage"]')" \
    "Candidate task 'task-a'" "prompt context is injected as a system message"
assert_eq "$(state pending-candidate agy agy-one)" task-a "prompt marks the owned agy lease pending"
DENIAL=$(tool PreToolUse agy-one t1 run_command "$(command_args 'touch out.txt')")
assert_eq "$(printf '%s' "$DENIAL" | json_value '["decision"]')" deny "PreToolUse renders block as deny"
assert_contains "$DENIAL" '## Task Identity' "denial carries the candidate identity"

printf -v ROOT_ARG '%q' "$PROJECT"
printf -v BIND_ARG '%q' "$AGY_SCRIPTS/bind-session.sh"
BIND="PWF_PROJECT_ROOT=$ROOT_ARG bash $BIND_ARG bind task-a"
assert_empty "$(tool PreToolUse agy-one t2 run_command "$(command_args "$BIND")")" "an allowed call prints nothing, since agy denies {}"
(cd "$PROJECT" && ANTIGRAVITY_CONVERSATION_ID=agy-one bash -c "$BIND") >/dev/null
assert_eq "$(state resolve agy agy-one)" "$PROJECT/tmp/plan-files/task-a" "bind uses the agy namespace"
if (cd "$PROJECT" && env -u ANTIGRAVITY_CONVERSATION_ID "$AGY_SCRIPTS/bind-session.sh" bind task-a >/dev/null 2>&1); then
    fail "bind adapter accepted a missing ANTIGRAVITY_CONVERSATION_ID"
fi

# PostToolUse context waits for the next PreInvocation and is delivered once.
assert_eq "$(tool PostToolUse agy-one t2 run_command "$(command_args "$BIND")")" '{}' "PostToolUse prints agy's empty object"
SKILL_ARGS="{\"Path\":\"$REPO_ROOT/skills/plan-files/SKILL.md\"}"
tool PreToolUse agy-one t3 read_file "$SKILL_ARGS" >/dev/null
tool PostToolUse agy-one t3 read_file "$SKILL_ARGS" >/dev/null
assert_contains "$(invocation agy-one 1)" '=== Current task' "deferred PostToolUse context is injected"
assert_eq "$(invocation agy-one 2)" '{}' "deferred context is delivered once"

# Only a turn the agent ended itself is gated; Stop renders block as continue.
assert_eq "$(stop_hook agy-one NO_TOOL_CALL | json_value '["decision"]')" continue "incomplete Stop continues"
assert_eq "$(stop_hook agy-one USER_CANCELED)" '{}' "a canceled turn is not gated"

# A call agy denied after PreToolUse never gets PostToolUse; the turn's Stop retires it.
write_plan task-b in_progress
printf '# Decisions\n\n## Active Decisions\n- None.\n' > "$PROJECT/tmp/plan-files/task-b/decisions.md"
printf '# Findings\n\n## Current Summary\n- None relevant.\n' > "$PROJECT/tmp/plan-files/task-b/findings.md"
state claim agy agy-b task-b >/dev/null
tool PreToolUse agy-b t4 read_file "$SKILL_ARGS" >/dev/null
assert_empty "$(tool PreToolUse agy-b t5 run_command "$(command_args 'touch out.txt')")" "owned mutation is allowed"
write_plan task-b complete
assert_eq "$(stop_hook agy-b NO_TOOL_CALL)" '{}' "complete Stop is allowed despite the unanswered call"
assert_empty "$(state resolve agy agy-b 2>/dev/null || true)" "complete Stop finishes the lease"

# A payload whose conversation is not the hook's own is a no-op.
SPOOFED=$(cd "$TEST_DIR" && printf '{"conversationId":"agy-one","cwd":"%s","toolCall":{"name":"run_command","args":{"CommandLine":"touch x"}}}' "$PROJECT" \
    | ANTIGRAVITY_CONVERSATION_ID=other python3 "$AGY_SCRIPTS/agy_adapter.py" PreToolUse)
assert_empty "$SPOOFED" "mismatched identity allows without output"
[ ! -d "$PROJECT/tmp/plan-files/.sessions/claude" ] || fail "agy created Claude session state"

printf 'agy global hook tests: PASS\n'
