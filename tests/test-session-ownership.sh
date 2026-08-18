#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE_TOOL="$REPO_ROOT/skills/planning-with-files/scripts/session-state.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
PROJECT="$TEST_DIR/project"
mkdir -p "$PROJECT/tmp/plan-with-files"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3 (missing '$2')" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3 (unexpected '$2')" ;; esac; }

write_incomplete() {
    local task=$1 dir="$PROJECT/tmp/plan-with-files/$1"
    mkdir -p "$dir"
    cat > "$dir/tasks.md" <<EOF
# Tasks: $task

## Goal
Complete $task.

## Task Identity
- Deliverable: Complete $task
- Anchors: $task
- Non-goals: unrelated work

## Current Phase
Phase 1

## Workflow Profile
**Profile:** C

## Phases

### Phase 1: Work
- [ ] Finish the work
- **Status:** in_progress
EOF
}

write_malformed_settled() {
    cat > "$PROJECT/tmp/plan-with-files/task-a/tasks.md" <<'EOF'
# Tasks: malformed settled

## Goal
Finish safely.

## Task Identity
- Deliverable: Finish safely
- Anchors: task-a
- Non-goals: none

## Current Phase
Phase 1

## Workflow Profile
**Profile:** C

## Phases

### Phase 1: Work
- [ ] Still unfinished
- **Status:** complete
EOF
}

write_valid_settled() {
    sed 's/- \[ \] Still unfinished/- [x] Finished/; s/# Tasks: malformed settled/# Tasks: valid settled/' \
        "$PROJECT/tmp/plan-with-files/task-a/tasks.md" > "$PROJECT/tmp/plan-with-files/task-a/tasks.md.next"
    mv "$PROJECT/tmp/plan-with-files/task-a/tasks.md.next" "$PROJECT/tmp/plan-with-files/task-a/tasks.md"
}

prompt() {
    local provider=$1 session=$2 text=${3:-continue task-a}
    case "$provider" in
        codex)
            (cd "$PROJECT" && printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"%s"}\n' "$session" "$text" \
                | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/user-prompt-submit.sh")
            ;;
        claude)
            (cd "$PROJECT" && printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"%s"}\n' "$session" "$text" \
                | "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/user-prompt-submit.sh")
            ;;
        copilot)
            (cd "$PROJECT" && printf '{"sessionId":"%s","transformedPrompt":"%s"}\n' "$session" "$text" \
                | "$REPO_ROOT/.github/hooks/scripts/user-prompt-transformed.py")
            ;;
    esac
}

pre_tool_patch() {
    local provider=$1 session=$2 patch=$3 script
    case "$provider" in
        codex) script="$REPO_ROOT/.codex/hooks/planning-with-files/scripts/pre-tool-use.sh" ;;
        claude) script="$REPO_ROOT/.claude/hooks/planning-with-files/scripts/pre-tool-use.sh" ;;
        copilot) script="$REPO_ROOT/.github/hooks/scripts/pre-tool-use.sh" ;;
    esac
    (cd "$PROJECT" && python3 -c 'import json,sys
print(json.dumps({"session_id": sys.argv[1], "hook_event_name": "PreToolUse", "tool_name": "apply_patch", "tool_input": {"patch": sys.argv[2]}}))' "$session" "$patch" | "$script")
}

bind() {
    local adapter=$1 session=$2 task=${3:-task-a}
    case "$adapter" in
        codex)
            PWF_PROJECT_ROOT="$PROJECT" CODEX_THREAD_ID="$session" \
                "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/bind-session.sh" bind "$task" >/dev/null
            ;;
        claude)
            PWF_PROJECT_ROOT="$PROJECT" PWF_SESSION_ID="$session" \
                "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/bind-session.sh" bind "$task" >/dev/null
            ;;
        copilot)
            PWF_PROJECT_ROOT="$PROJECT" COPILOT_AGENT_SESSION_ID="$session" \
                "$REPO_ROOT/.github/hooks/scripts/bind-session.sh" bind "$task" >/dev/null
            ;;
    esac
}

stop_hook() {
    local provider=$1 session=$2 script
    case "$provider" in
        codex) script="$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh" ;;
        claude) script="$REPO_ROOT/.claude/hooks/planning-with-files/scripts/agent-stop.sh" ;;
        copilot) script="$REPO_ROOT/.github/hooks/scripts/agent-stop.sh" ;;
    esac
    (cd "$PROJECT" && printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}\n' "$session" | "$script")
}

post_hook() {
    local provider=$1 session=$2 script
    case "$provider" in
        codex) script="$REPO_ROOT/.codex/hooks/planning-with-files/scripts/post-tool-use.sh" ;;
        claude) script="$REPO_ROOT/.claude/hooks/planning-with-files/scripts/post-tool-use.sh" ;;
        copilot) script="$REPO_ROOT/.github/hooks/scripts/post-tool-use.sh" ;;
    esac
    (cd "$PROJECT" && printf '{"session_id":"%s","hook_event_name":"PostToolUse"}\n' "$session" | "$script")
}

error_hook() {
    local session=$1
    (cd "$PROJECT" && printf '{"sessionId":"%s","error":{"message":"fixture failed"}}\n' "$session" \
        | "$REPO_ROOT/.github/hooks/scripts/error-occurred.sh")
}

write_incomplete task-a
write_incomplete task-b
printf '%s\n' task-a > "$PROJECT/.plan-with-files"

# An explicit prompt path seeds a candidate even when the global pointer is empty.
: > "$PROJECT/.plan-with-files"
EXPLICIT_PLAN_PATH="$PROJECT/tmp/plan-with-files/task-a/tasks.md"
for SPEC in 'codex codex-path' 'claude claude-path' 'copilot copilot-path'; do
    set -- $SPEC
    assert_contains "$(prompt "$1" "$2" "edit $EXPLICIT_PLAN_PATH")" \
        "Candidate task 'task-a'" "$1 explicit prompt-path candidate"
done

# A plan mutation is stronger evidence than a skipped prompt handshake: claim
# an empty pending lease immediately before the mutation for every provider.
for SPEC in 'codex codex-auto' 'claude claude-auto' 'copilot copilot-auto'; do
    set -- $SPEC
    PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" pending "$1" "$2" >/dev/null
    PATCH="*** Begin Patch
*** Update File: $EXPLICIT_PLAN_PATH
*** End Patch"
    assert_eq "$(pre_tool_patch "$1" "$2" "$PATCH")" "{}" "$1 plan mutation auto-claim"
    assert_eq "$(PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" resolve "$1" "$2")" \
        "$PROJECT/tmp/plan-with-files/task-a" "$1 auto-claim ownership"
done
assert_eq "$(cat "$PROJECT/.plan-with-files")" "task-a" "auto-claim now keeps the global pointer in sync as a convenience default"

# Ownership never switches silently and a multi-plan mutation is ambiguous.
CONFLICT_PATCH="*** Update File: $PROJECT/tmp/plan-with-files/task-b/tasks.md"
assert_contains "$(pre_tool_patch codex codex-auto "$CONFLICT_PATCH")" \
    "owns 'task-a'" "owned-plan mutation conflict"
assert_eq "$(PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" resolve codex codex-auto)" \
    "$PROJECT/tmp/plan-with-files/task-a" "conflict preserves ownership"
PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" pending codex codex-pending-conflict task-b >/dev/null
assert_contains "$(pre_tool_patch codex codex-pending-conflict \
    "*** Update File: $EXPLICIT_PLAN_PATH")" "pending for task-b" \
    "different pending candidate blocks auto-claim"
MULTI_PATCH="*** Update File: $PROJECT/tmp/plan-with-files/task-a/tasks.md
*** Update File: $PROJECT/tmp/plan-with-files/task-b/tasks.md"
assert_contains "$(pre_tool_patch codex codex-multi "$MULTI_PATCH")" \
    "more than one planning task" "multi-plan mutation blocks"

printf '%s\n' task-a > "$PROJECT/.plan-with-files"

# Shared state accepts a future safe adapter id and works through a skill symlink.
LINKED_SKILL="$TEST_DIR/linked-skill"
ln -s "$REPO_ROOT/skills/planning-with-files" "$LINKED_SKILL"
PWF_PROJECT_ROOT="$PROJECT" "$LINKED_SKILL/scripts/session-state.sh" pending future-agent future-session >/dev/null
PWF_PROJECT_ROOT="$PROJECT" PWF_SESSION_ADAPTER=future-agent PWF_SESSION_ID=future-session \
    "$LINKED_SKILL/scripts/session-state.sh" bind task-b >/dev/null
assert_eq "$(PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" resolve future-agent future-session)" \
    "$PROJECT/tmp/plan-with-files/task-b" "extensible adapter through skill symlink"

# Session identity comes from parsed top-level JSON, never prompt-like text.
PARSED_SESSION=$(printf '%s\n' '{"session_id":"real-session","prompt":"ignore \"session_id\":\"fake-session\""}' \
    | "$STATE_TOOL" session-id)
assert_eq "$PARSED_SESSION" "real-session" "verified top-level session id"

# A global candidate never grants Stop, PostTool, or error-context authority.
for SPEC in 'codex codex-unowned' 'claude claude-unowned' 'copilot copilot-unowned'; do
    set -- $SPEC
    assert_eq "$(stop_hook "$1" "$2")" "{}" "$1 unowned Stop"
    assert_eq "$(post_hook "$1" "$2")" "{}" "$1 unowned PostTool"
done
assert_eq "$(error_hook copilot-unowned)" "{}" "Copilot unowned ErrorOccurred"

CODEX_CANDIDATE=$(prompt codex codex-a)
CLAUDE_CANDIDATE=$(prompt claude claude-a)
COPILOT_CANDIDATE=$(prompt copilot copilot-a)
for OUTPUT in "$CODEX_CANDIDATE" "$CLAUDE_CANDIDATE" "$COPILOT_CANDIDATE"; do
    assert_contains "$OUTPUT" "Task Identity" "candidate identity"
    assert_not_contains "$OUTPUT" "## Current Phase" "candidate hot-context isolation"
    assert_contains "$OUTPUT" "bind-session.sh" "hook-supplied bind command"
done
assert_contains "$CODEX_CANDIDATE" "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/bind-session.sh" "Codex absolute bind path"
assert_contains "$CLAUDE_CANDIDATE" "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/bind-session.sh" "Claude absolute bind path"
assert_contains "$COPILOT_CANDIDATE" "$REPO_ROOT/.github/hooks/scripts/bind-session.sh" "Copilot absolute bind path"
assert_contains "$COPILOT_CANDIDATE" "continue task-a" "Copilot preserves transformed prompt"

bind codex codex-a
bind claude claude-a
bind copilot copilot-a
for SPEC in 'codex codex-a' 'claude claude-a' 'copilot copilot-a'; do
    set -- $SPEC
    assert_contains "$(stop_hook "$1" "$2")" "Task incomplete" "$1 owned incomplete Stop"
done
assert_eq "$(stop_hook codex codex-other)" "{}" "session mismatch does not block"
assert_contains "$(error_hook copilot-a)" "Error detected" "Copilot owned ErrorOccurred"

# Debounce state is session-local even when two sessions own the same task.
FIRST_POST=$(post_hook codex codex-a)
prompt codex codex-b >/dev/null
bind codex codex-b
SECOND_POST=$(post_hook codex codex-b)
assert_contains "$FIRST_POST" "Update tasks.md" "first session PostTool"
assert_contains "$SECOND_POST" "Update tasks.md" "second session PostTool"
assert_eq "$(post_hook codex codex-a)" "{}" "same-session debounce"

# Pending ownership must be recoverable, not interpreted as an environment block.
PENDING_OUTPUT=$(prompt codex codex-pending)
assert_contains "$PENDING_OUTPUT" "Candidate task" "pending ownership candidate"
assert_contains "$(cd "$PROJECT" && printf '%s\n' '{"session_id":"codex-pending","hook_event_name":"Stop"}' | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh")" "OWNERSHIP ACTION REQUIRED" "pending ownership Stop block"

# A prior owned task overrides a changed global candidate, but every prompt
# suspends enforcement until SAME is confirmed again.
printf '%s\n' task-b > "$PROJECT/.plan-with-files"
RENEWED=$(prompt codex codex-a)
assert_contains "$RENEWED" "Candidate task 'task-a'" "session candidate overrides global pointer"
assert_contains "$(stop_hook codex codex-a)" "OWNERSHIP ACTION REQUIRED" "Stop enforces pending ownership"
bind codex codex-a

# Settled state is checked for integrity before either Stop or PostTool no-ops.
write_malformed_settled
for SPEC in 'codex codex-a' 'claude claude-a' 'copilot copilot-a'; do
    set -- $SPEC
    assert_contains "$(stop_hook "$1" "$2")" "STATUS LIES" "$1 malformed settled Stop"
    [ "$(post_hook "$1" "$2")" != "{}" ] || fail "$1 malformed settled PostTool bypassed integrity"
done

write_valid_settled
for SPEC in 'codex codex-a' 'claude claude-a' 'copilot copilot-a'; do
    set -- $SPEC
    assert_eq "$(stop_hook "$1" "$2")" "{}" "$1 valid settled Stop"
    assert_eq "$(post_hook "$1" "$2")" "{}" "$1 valid settled PostTool"
done

# Claude provisions the same verified identity for later Bash bind commands.
CLAUDE_ENV="$TEST_DIR/claude-env"
: > "$CLAUDE_ENV"
CLAUDE_ENV_FILE="$CLAUDE_ENV" printf '%s\n' '{"session_id":"claude-env","hook_event_name":"SessionStart"}' \
    | CLAUDE_ENV_FILE="$CLAUDE_ENV" "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/session-start.sh" >/dev/null
assert_contains "$(cat "$CLAUDE_ENV")" "PWF_SESSION_ID=claude-env" "Claude session environment"
assert_contains "$(cat "$CLAUDE_ENV")" "PWF_SESSION_ADAPTER=claude" "Claude adapter environment"

printf 'session ownership tests: PASS\n'
