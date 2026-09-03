#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STATE_TOOL="$REPO_ROOT/skills/plan-files/scripts/session-state.sh"
GROK_SCRIPTS="$REPO_ROOT/.grok/hooks/plan-files/scripts"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
PROJECT="$TEST_DIR/project"
GROK_HOME_ONE="$TEST_DIR/grok-home"
mkdir -p "$PROJECT/tmp/plan-files" "$GROK_HOME_ONE/hooks"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3 (missing '$2')" ;; esac; }
assert_empty() { [ -z "$1" ] || fail "$2 (got '$1')"; }

json_value() {
    python3 -c 'import json,sys; value=json.load(sys.stdin); print(value'"$1"')'
}

write_plan() {
    local task=$1 status=$2 dir="$PROJECT/tmp/plan-files/$1" active mark evidence
    mkdir -p "$dir"
    if [ "$status" = complete ]; then
        active=""
        mark=x
        evidence="verified fixture"
    else
        active=P1.1
        mark=" "
        evidence=pending
    fi
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
- **Status:** $status

## Verification
- fixture: current
EOF
}

hook() {
    local script=$1 session=$2 payload=$3
    (cd "$PROJECT" && printf '%s' "$payload" \
        | GROK_SESSION_ID="$session" GROK_WORKSPACE_ROOT="$PROJECT" "$GROK_SCRIPTS/$script")
}

prompt() {
    local session=$1
    hook user-prompt-submit.sh "$session" \
        "{\"hookEventName\":\"user_prompt_submit\",\"sessionId\":\"$session\",\"prompt\":\"continue\"}"
}

pre_command() {
    local session=$1 command=$2
    PAYLOAD=$(COMMAND="$command" SESSION="$session" python3 -c 'import json,os
print(json.dumps({"hookEventName":"pre_tool_use","sessionId":os.environ["SESSION"],"toolName":"run_terminal_cmd","toolInput":{"command":os.environ["COMMAND"]}}))')
    hook pre-tool-use.sh "$session" "$PAYLOAD"
}

post_patch() {
    local session=$1 patch=$2
    PAYLOAD=$(PATCH_TEXT="$patch" SESSION="$session" python3 -c 'import json,os
print(json.dumps({"hookEventName":"post_tool_use","sessionId":os.environ["SESSION"],"toolName":"apply_patch","toolInput":{"patch":os.environ["PATCH_TEXT"]},"toolResult":{}}))')
    hook post-tool-use.sh "$session" "$PAYLOAD"
}

stop_hook() {
    local session=$1 reason=$2 active=${3:-false}
    hook agent-stop.sh "$session" \
        "{\"hookEventName\":\"stop\",\"sessionId\":\"$session\",\"reason\":\"$reason\",\"stopHookActive\":$active}"
}

state() { PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" "$@"; }

# The explicit-home installer is atomic/idempotent, leaves sibling JSON alone,
# and refuses an unrelated pre-existing plan-files.json.
printf '{"hooks":{}}\n' > "$GROK_HOME_ONE/hooks/unrelated.json"
UNRELATED_SUM=$(sha256sum "$GROK_HOME_ONE/hooks/unrelated.json" | cut -d' ' -f1)
GROK_HOME="$GROK_HOME_ONE" make -s -C "$REPO_ROOT" install-hook-grok >/dev/null
DEST="$GROK_HOME_ONE/hooks/plan-files.json"
FIRST_SUM=$(sha256sum "$DEST" | cut -d' ' -f1)
GROK_HOME="$GROK_HOME_ONE" make -s -C "$REPO_ROOT" install-hook-grok >/dev/null
assert_eq "$(sha256sum "$DEST" | cut -d' ' -f1)" "$FIRST_SUM" "repeat install is byte-idempotent"
assert_eq "$(sha256sum "$GROK_HOME_ONE/hooks/unrelated.json" | cut -d' ' -f1)" "$UNRELATED_SUM" "sibling hook is preserved"
[ -z "$(find "$GROK_HOME_ONE/hooks" -maxdepth 1 -name '.plan-files.json.*' -print -quit)" ] \
    || fail "atomic installer left a temporary file"
python3 - "$DEST" "$REPO_ROOT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["_planFilesHook"]["managedBy"] == "plan-files-grok-installer"
for event in ("UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"):
    command = data["hooks"][event][0]["hooks"][0]["command"]
    assert sys.argv[2] in command, command
    assert ".grok/hooks/plan-files/scripts/" in command, command
PY
UNRELATED_HOME="$TEST_DIR/unrelated-home"
mkdir -p "$UNRELATED_HOME/hooks"
printf '{"hooks":{"Stop":[]}}\n' > "$UNRELATED_HOME/hooks/plan-files.json"
if python3 "$REPO_ROOT/scripts/install-grok-hooks.py" \
    "$REPO_ROOT/.grok/hooks/plan-files.json.sample" \
    "$UNRELATED_HOME/hooks/plan-files.json" >/dev/null 2>&1; then
    fail "installer overwrote an unrelated plan-files.json"
fi
assert_eq "$(cat "$UNRELATED_HOME/hooks/plan-files.json")" '{"hooks":{"Stop":[]}}' "refusal preserves unrelated destination"
[ -z "$(find "$REPO_ROOT/.grok/hooks" -maxdepth 1 -name '*.json' -print -quit)" ] \
    || fail "repository sample accidentally became an active project hook"

write_plan task-a in_progress
write_plan task-b in_progress
printf 'task-a\n' > "$PROJECT/.plan-files"
state claim grok grok-one task-a >/dev/null

# UserPromptSubmit changes only the grok lease to pending. PreToolUse then
# supplies bounded identity plus executable actions and renders Grok's deny.
assert_eq "$(prompt grok-one)" '{}' "allowing prompt hook stays output-passive"
assert_eq "$(state pending-candidate grok grok-one)" task-a "prompt marks owned Grok lease pending"
assert_empty "$(state resolve grok grok-one 2>/dev/null || true)" "pending lease is not owned"
DENIAL=$(pre_command grok-one 'git status --short')
assert_eq "$(printf '%s' "$DENIAL" | json_value '["decision"]')" deny "Grok PreToolUse translates block to deny"
REASON=$(printf '%s' "$DENIAL" | json_value '["reason"]')
assert_contains "$REASON" '## Task Identity' "pending denial includes Task Identity"
assert_contains "$REASON" '## Goal' "pending denial includes Goal"
assert_contains "$REASON" 'SAME: run' "pending denial includes SAME command"
assert_contains "$REASON" 'DIFFERENT: first run' "pending denial includes DIFFERENT command"

printf -v ROOT_ARG '%q' "$PROJECT"
printf -v BIND_ARG '%q' "$GROK_SCRIPTS/bind-session.sh"
EXPECTED_BIND="PWF_PROJECT_ROOT=$ROOT_ARG bash $BIND_ARG bind task-a"
EXPECTED_RELEASE="PWF_PROJECT_ROOT=$ROOT_ARG bash $BIND_ARG release task-a"
assert_eq "$(pre_command grok-one "$EXPECTED_BIND" | json_value '["decision"]')" allow "camelCase exact bind is allowed"
(cd "$PROJECT" && GROK_SESSION_ID=grok-one bash -c "$EXPECTED_BIND") >/dev/null
assert_eq "$(state resolve grok grok-one)" "$PROJECT/tmp/plan-files/task-a" "bind uses the Grok namespace"

prompt grok-one >/dev/null
assert_eq "$(pre_command grok-one "$EXPECTED_RELEASE" | json_value '["decision"]')" allow "camelCase exact release is allowed"
(cd "$PROJECT" && GROK_SESSION_ID=grok-one bash -c "$EXPECTED_RELEASE") >/dev/null
assert_empty "$(state resolve grok grok-one 2>/dev/null || true)" "release clears the Grok lease"

# Session ids remain isolated, and Grok never writes Claude ownership state.
state claim grok grok-a task-a >/dev/null
state claim grok grok-b task-b >/dev/null
assert_eq "$(state resolve grok grok-a)" "$PROJECT/tmp/plan-files/task-a" "first Grok session scope"
assert_eq "$(state resolve grok grok-b)" "$PROJECT/tmp/plan-files/task-b" "second Grok session scope"
[ ! -d "$PROJECT/tmp/plan-files/.sessions/claude" ] || fail "Grok created Claude session state"

# Both current Grok terminal aliases share shell read/mutation classification.
for TOOL in run_terminal_cmd run_terminal_command; do
    READ_CLASS=$(printf '{"toolName":"%s","toolInput":{"command":"git status --short"}}' "$TOOL" \
        | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" \
            tool-class "$PROJECT/tmp/plan-files/task-a" | json_value '["class"]')
    WRITE_CLASS=$(printf '{"toolName":"%s","toolInput":{"command":"touch generated.txt"}}' "$TOOL" \
        | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" \
            tool-class "$PROJECT/tmp/plan-files/task-a" | json_value '["class"]')
    assert_eq "$READ_CLASS" read_only_exploration "$TOOL read classification"
    assert_eq "$WRITE_CLASS" operational_mutation "$TOOL mutation classification"
done

# PostToolUse first-write auto-claim is a side effect, independent of whether
# this Grok release delivers its stdout to the model.
NEW_TASK=post-auto-claim
NEW_PATCH="*** Add File: $PROJECT/tmp/plan-files/$NEW_TASK/tasks.md"
assert_eq "$(pre_command grok-new 'printf create-plan')" '{"decision":"allow"}' "unowned ordinary call is allowed"
write_plan "$NEW_TASK" in_progress
post_patch grok-new "$NEW_PATCH" >/dev/null
assert_eq "$(state resolve grok grok-new)" "$PROJECT/tmp/plan-files/$NEW_TASK" "PostToolUse auto-claims new plan"

# Stop gates genuine end_turn only, keeps pending recovery self-contained,
# allows a complete plan, and does nothing on shutdown/channel-close.
INCOMPLETE_STOP=$(stop_hook grok-a end_turn false)
assert_eq "$(printf '%s' "$INCOMPLETE_STOP" | json_value '["decision"]')" block "incomplete end_turn is blocked"
assert_contains "$INCOMPLETE_STOP" 'Task incomplete' "incomplete Stop explains continuation"
assert_eq "$(stop_hook grok-a shutdown true)" '{}' "shutdown Stop is a no-op"
assert_eq "$(state resolve grok grok-a)" "$PROJECT/tmp/plan-files/task-a" "shutdown preserves lease"
printf 'task-a\n' > "$PROJECT/.plan-files"
state pending grok grok-pending task-a >/dev/null
PENDING_STOP=$(stop_hook grok-pending end_turn false)
assert_contains "$PENDING_STOP" '## Task Identity' "pending Stop repeats candidate identity"
assert_contains "$PENDING_STOP" "$EXPECTED_BIND" "pending Stop includes executable bind command"

write_plan task-complete complete
state claim grok grok-complete task-complete >/dev/null
assert_eq "$(stop_hook grok-complete end_turn true)" '{}' "complete end_turn is allowed"
assert_empty "$(state resolve grok grok-complete 2>/dev/null || true)" "complete Stop finishes lease"

# Missing/malformed identities, explicit disable, and project skip never inject
# plan context or mutate ownership. The bind adapter itself fails closed.
INVALID=$(cd "$PROJECT" && printf '%s' '{"sessionId":"spoofed"}' \
    | GROK_SESSION_ID=different "$GROK_SCRIPTS/pre-tool-use.sh")
assert_eq "$INVALID" '{"decision":"allow"}' "mismatched identity fails open without injection"
assert_empty "$(state pending-candidate grok spoofed 2>/dev/null || true)" "mismatched identity does not mutate"
if (cd "$PROJECT" && env -u GROK_SESSION_ID "$GROK_SCRIPTS/bind-session.sh" bind task-a >/dev/null 2>&1); then
    fail "bind adapter accepted a missing GROK_SESSION_ID"
fi
DISABLED_PAYLOAD='{"hookEventName":"pre_tool_use","sessionId":"grok-disabled","toolName":"run_terminal_cmd","toolInput":{"command":"touch x"}}'
assert_eq "$(cd "$PROJECT" && printf '%s' "$DISABLED_PAYLOAD" \
    | PLANNING_DISABLED=1 GROK_SESSION_ID=grok-disabled "$GROK_SCRIPTS/pre-tool-use.sh")" \
    '{"decision":"allow"}' "PLANNING_DISABLED is a no-op"
touch "$PROJECT/.plan-files-skip"
assert_eq "$(hook pre-tool-use.sh grok-skipped "${DISABLED_PAYLOAD//grok-disabled/grok-skipped}")" \
    '{"decision":"allow"}' ".plan-files-skip is a no-op"
assert_eq "$(prompt grok-skipped)" '{}' "skipped prompt is a no-op"
rm "$PROJECT/.plan-files-skip"

printf 'grok global hook tests: PASS\n'
