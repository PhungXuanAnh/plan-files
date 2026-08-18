#!/bin/bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE_TOOL="$REPO_ROOT/skills/planning-with-files/scripts/session-state.sh"
CHECKPOINT_TOOL="$REPO_ROOT/skills/planning-with-files/scripts/plan-checkpoint.py"
# shellcheck source=../.codex/hooks/planning-with-files/scripts/common.sh
source "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/common.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
PROJECT="$TEST_DIR/project"
PLAN_DIR="$PROJECT/tmp/plan-with-files/test-task"
mkdir -p "$PLAN_DIR"
printf '%s\n' test-task > "$PROJECT/.plan-with-files"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3 (missing '$2')" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3 (unexpected '$2')" ;; esac; }

post_hook() {
    local provider=$1 session=$2 script
    case "$provider" in
        codex) script="$REPO_ROOT/.codex/hooks/planning-with-files/scripts/post-tool-use.sh" ;;
        claude) script="$REPO_ROOT/.claude/hooks/planning-with-files/scripts/post-tool-use.sh" ;;
        copilot) script="$REPO_ROOT/.github/hooks/scripts/post-tool-use.sh" ;;
    esac
    (cd "$PROJECT" && printf '{"session_id":"%s","hook_event_name":"PostToolUse"}\n' "$session" | "$script")
}

pre_hook() {
    local provider=$1 session=$2 command=$3 script
    case "$provider" in
        codex) script="$REPO_ROOT/.codex/hooks/planning-with-files/scripts/pre-tool-use.sh" ;;
        claude) script="$REPO_ROOT/.claude/hooks/planning-with-files/scripts/pre-tool-use.sh" ;;
        copilot) script="$REPO_ROOT/.github/hooks/scripts/pre-tool-use.sh" ;;
    esac
    (cd "$PROJECT" && python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]}}))' "$session" "$command" | "$script")
}

write_valid_plan() {
    cat > "$PLAN_DIR/tasks.md" <<'EOF'
# Tasks: Contract Fixture

## Goal
Verify the planning contract.

## Task Identity
- Deliverable: Verify the planning contract
- Anchors: contract-fixture
- Non-goals: unrelated hook behavior

## Current Phase
Phase 1

## Workflow Profile
**Profile:** C

## Resume Checkpoint
- **Next action:** Run the fixture.
- **Blocker:** none
- **Details:** none

## Phases

### Phase 1: Implement
- [ ] Make the change
- **Status:** in_progress

### Phase 2: Verify
- [ ] Run the check
- **Status:** pending
EOF
    printf '# Findings\n\n## Current Summary\n- fixture\n' > "$PLAN_DIR/findings.md"
    printf '# Decisions\n\n## Active Decisions\n- fixture\n' > "$PLAN_DIR/decisions.md"
}

write_contracted_plan() {
    cat > "$PLAN_DIR/tasks.md" <<'EOF'
# Tasks: Contracted Fixture

## Goal
Verify outcome-item transitions.

## Task Identity
- Deliverable: Verify outcome-item transitions
- Anchors: contracted-fixture
- Non-goals: unrelated hook behavior

## Current Phase
Phase 1

## Active Item
P1.1

## Workflow Profile
**Profile:** C

## Resume Checkpoint
- **Next action:** Complete P1.1.
- **Blocker:** none
- **Details:** none

## Phases

### Phase 1: Implement
- [ ] [P1.1] The change is present.
  - Evidence: pending
- [ ] [V1.1] The focused check passes.
  - Evidence: pending
- **Status:** in_progress

### Phase 2: Verify
- [ ] [P2.1] The regression check passes.
  - Evidence: pending
- [ ] [V2.1] The task is ready to finalize.
  - Evidence: pending
- **Status:** pending
EOF
}

write_valid_plan
count_phases "$PLAN_DIR/tasks.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/tasks.md")" "" "valid plan"
assert_eq "$(current_phase_pointer "$PLAN_DIR/tasks.md")" "Phase 1" "exact current pointer"
assert_eq "$TOTAL/$IN_PROGRESS/$PENDING/$BLOCKED/$DEFERRED" "2/1/1/0/0" "phase counts"

# Contracted item transitions are atomic and advance item, phase, and pointer state.
write_contracted_plan
count_phases "$PLAN_DIR/tasks.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/tasks.md")" "" "contracted plan"
if python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" complete P1.1 --evidence pending >/dev/null; then
    fail "checkpoint rejects placeholder completion evidence"
fi
python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" progress P1.1 --evidence "implementation exists" >/dev/null
python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" complete P1.1 --evidence "implementation exists" >/dev/null
assert_contains "$(planning_item_context "$PLAN_DIR/tasks.md")" '"active_item":"V1.1"' "checkpoint selects phase acceptance"
python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" complete V1.1 --evidence "focused check passed" >/dev/null
assert_contains "$(planning_item_context "$PLAN_DIR/tasks.md")" '"active_item":"P2.1"' "checkpoint advances phase"
assert_contains "$(current_phase_pointer "$PLAN_DIR/tasks.md")" "Phase 2" "checkpoint advances Current Phase"
python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" complete P2.1 --evidence "regression check passed" >/dev/null
python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" complete V2.1 --evidence "final review passed" --deactivate-pointer >/dev/null
assert_eq "$(planning_assert_finalizable "$PLAN_DIR/tasks.md" "$PROJECT")" "FINALIZABLE" "final checkpoint settles and deactivates plan"
assert_eq "$(cat "$PROJECT/.plan-with-files")" "" "final checkpoint clears owned pointer"
printf '%s\n' test-task > "$PROJECT/.plan-with-files"

write_contracted_plan
sed -i 's/\[V1\.1\]/[P1.1]/' "$PLAN_DIR/tasks.md"
count_phases "$PLAN_DIR/tasks.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/tasks.md")" "ITEM_ID_DUPLICATE" "contract rejects duplicate item IDs"

write_valid_plan
sed '/^## Phases$/d' "$PLAN_DIR/tasks.md" > "$PLAN_DIR/bad-layout.md"
count_phases "$PLAN_DIR/bad-layout.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/bad-layout.md")" "SECTION_LAYOUT_INVALID" "missing Phases section"

sed 's/^Phase 1$/Phase 1 extra/' "$PLAN_DIR/tasks.md" > "$PLAN_DIR/bad-current.md"
count_phases "$PLAN_DIR/bad-current.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/bad-current.md")" "CURRENT_PHASE_INVALID" "invalid Current Phase body"

sed 's/^### Phase 1:/### Phase one:/' "$PLAN_DIR/tasks.md" > "$PLAN_DIR/bad-heading.md"
count_phases "$PLAN_DIR/bad-heading.md"
# Renaming the heading away from "Phase 1" also makes Current Phase (which
# still says "Phase 1") point at a phase that no longer exists — both issues
# are genuinely true at once, and check_task_plan_format now reports both
# instead of only the first (this is the accumulation behavior, not a bug).
assert_eq "$(check_task_plan_format "$PLAN_DIR/bad-heading.md")" "$(printf 'PHASE_HEADING_INVALID\nCURRENT_PHASE_INVALID')" "malformed phase heading also invalidates the now-missing Current Phase target"

sed '/\*\*Status:\*\* pending/d' "$PLAN_DIR/tasks.md" > "$PLAN_DIR/missing-status.md"
count_phases "$PLAN_DIR/missing-status.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/missing-status.md")" "PHASE_STATUS_INVALID" "missing phase status"

sed '/\*\*Status:\*\* pending/a\- **Status:** complete' "$PLAN_DIR/tasks.md" > "$PLAN_DIR/duplicate-status.md"
count_phases "$PLAN_DIR/duplicate-status.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/duplicate-status.md")" "PHASE_STATUS_INVALID" "duplicate phase status"

sed 's/in_progress/blocked/' "$PLAN_DIR/tasks.md" > "$PLAN_DIR/blocked-without-reason.md"
count_phases "$PLAN_DIR/blocked-without-reason.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/blocked-without-reason.md")" "BLOCKED_NO_REASON" "blocked phase requires reason"

head -c 33000 /dev/zero | tr '\0' x > "$PLAN_DIR/findings.md"
assert_contains "$(planning_file_budget_warning "$PLAN_DIR")" "findings.md=" "byte budget"

write_valid_plan
for N in $(seq 3 13); do printf '\n### Phase %s: Archived Candidate [complete]\n' "$N" >> "$PLAN_DIR/tasks.md"; done
assert_contains "$(planning_file_budget_warning "$PLAN_DIR")" "13/12 phase entries" "hot phase-entry budget"

write_valid_plan
printf '# Handoff\n' > "$PLAN_DIR/handoff.md"
touch -t 202601010000 "$PLAN_DIR/handoff.md"
touch -t 202601010001 "$PLAN_DIR/tasks.md"
assert_contains "$(planning_handoff_warning "$PLAN_DIR")" "STALE HANDOFF" "stale handoff"
touch -t 203001010000 "$PLAN_DIR/handoff.md"
assert_eq "$(planning_handoff_warning "$PLAN_DIR")" "" "fresh handoff"

cmp "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/common.sh" "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/common.sh"
cmp "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/common.sh" "$REPO_ROOT/.github/hooks/scripts/common.sh"
bash -n "$REPO_ROOT"/.codex/hooks/planning-with-files/scripts/*.sh \
    "$REPO_ROOT"/.claude/hooks/planning-with-files/scripts/*.sh \
    "$REPO_ROOT"/.github/hooks/scripts/*.sh

# Compaction gate: observations stay possible, mutations stay in planning scope.
printf '%s' '{"tool_name":"rg","tool_input":{"command":"rg Phase ."}}' | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows read search"
printf '%s' '{"tool_name":"mcp__serena__search_for_pattern","tool_input":{"substring_pattern":"Phase","relative_path":"src"}}' | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows Serena read search"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status --short"}}' | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows read-only git status"
if printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git checkout -- src/main.py"}}' | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR"; then
    fail "compaction blocks mutating git command"
fi
if printf '%s' '{"tool_name":"apply_patch","tool_input":{"patch":"*** Update File: src/main.py"}}' | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR"; then
    fail "compaction blocks source mutation"
fi
printf '%s' "{\"tool_name\":\"apply_patch\",\"tool_input\":{\"patch\":\"*** Update File: $PLAN_DIR/tasks.md\"}}" | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows plan mutation"
printf '%s' "{\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: $PLAN_DIR/history.md\\n*** End Patch\"}}" | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows bridge apply_patch command payload"
printf '%s' "{\"tool_name\":\"codex_apply_patch\",\"tool_input\":{\"opaque\":\"write $PLAN_DIR/history.md\"}}" | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows unknown mutation tool with exact owned plan reference"
if printf '%s' '{"tool_name":"codex_apply_patch","tool_input":{"opaque":"write history.md"}}' | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR"; then
    fail "compaction does not trust plan basenames without owned plan path"
fi
if printf '%s' "{\"tool_name\":\"apply_patch\",\"tool_input\":{\"patch\":\"*** Update File: $PLAN_DIR/tasks.md\\n*** Update File: src/main.py\"}}" | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR"; then
    fail "compaction requires every patch target inside plan"
fi
printf '%s' "{\"tool_name\":\"mcp__serena__replace_content\",\"tool_input\":{\"relative_path\":\"$PLAN_DIR/findings.md\",\"needle\":\"old\",\"repl\":\"new\"}}" | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows Serena plan mutation"
if printf '%s' '{"tool_name":"mcp__serena__replace_content","tool_input":{"relative_path":"src/main.py","needle":"old","repl":"new"}}' | python3 "$REPO_ROOT/skills/planning-with-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR"; then
    fail "compaction blocks Serena source mutation"
fi

# The actual blocked PreToolUse response tells the model what remains allowed.
write_valid_plan
head -c 33000 /dev/zero | tr '\0' x > "$PLAN_DIR/findings.md"
PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" pending codex codex-compaction >/dev/null
PWF_PROJECT_ROOT="$PROJECT" PWF_SESSION_ADAPTER=codex PWF_SESSION_ID=codex-compaction "$STATE_TOOL" bind test-task >/dev/null
COMPACTION_BLOCK=$(cd "$PROJECT" && printf '%s\n' '{"session_id":"codex-compaction","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}' | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/pre-tool-use.sh")
assert_contains "$COMPACTION_BLOCK" "demonstrably read-only" "compaction block explains project reads"
assert_contains "$COMPACTION_BLOCK" "does not require a specific mutation tool name" "compaction block explains schema-independent plan mutations"
assert_contains "$COMPACTION_BLOCK" "$PLAN_DIR" "compaction block names owned plan directory"
COMPACTION_LOG=$(cat "$PROJECT/tmp/hook-logs/plan-with-files/pre-tool-use.log")
assert_contains "$COMPACTION_LOG" "tool_call tool_name=Bash" "pre-tool log records full tool name"
assert_contains "$COMPACTION_LOG" 'tool_input={"command":"npm test"}' "pre-tool log records full tool parameters"
assert_contains "$COMPACTION_LOG" "decision=block-compaction tool=Bash" "pre-tool log correlates blocked decision"
CHECKPOINT_PAYLOAD=$(printf '{"session_id":"codex-compaction","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"python3 %s --plan %s progress P1.1 --evidence checkpoint"}}\n' "$CHECKPOINT_TOOL" "$PLAN_DIR/tasks.md")
assert_eq "$(cd "$PROJECT" && printf '%s\n' "$CHECKPOINT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/pre-tool-use.sh")" "{}" "pre-tool gate permits owned structured checkpoint"

CODEX_PAYLOAD='{"session_id":"codex-contract","hook_event_name":"Stop","stop_hook_active":false}'
CLAUDE_PAYLOAD='{"session_id":"claude-contract","hook_event_name":"Stop","stop_hook_active":false}'
COPILOT_PAYLOAD='{"session_id":"copilot-contract","hook_event_name":"Stop","stop_hook_active":false}'
CODEX_REPEAT_PAYLOAD='{"session_id":"codex-contract","hook_event_name":"Stop","stop_hook_active":true}'
CLAUDE_REPEAT_PAYLOAD='{"session_id":"claude-contract","hook_event_name":"Stop","stop_hook_active":true}'
COPILOT_REPEAT_PAYLOAD='{"session_id":"copilot-contract","hook_event_name":"Stop","stop_hook_active":true}'

CODEX_CANDIDATE=$(cd "$PROJECT" && printf '%s\n' '{"session_id":"codex-contract","hook_event_name":"UserPromptSubmit","prompt":"continue contract-fixture"}' | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/user-prompt-submit.sh")
CLAUDE_CANDIDATE=$(cd "$PROJECT" && printf '%s\n' '{"session_id":"claude-contract","hook_event_name":"UserPromptSubmit","prompt":"continue contract-fixture"}' | "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/user-prompt-submit.sh")
COPILOT_CANDIDATE=$(cd "$PROJECT" && printf '%s\n' '{"sessionId":"copilot-contract","transformedPrompt":"continue contract-fixture"}' | "$REPO_ROOT/.github/hooks/scripts/user-prompt-transformed.py")
for OUTPUT in "$CODEX_CANDIDATE" "$CLAUDE_CANDIDATE" "$COPILOT_CANDIDATE"; do
    assert_contains "$OUTPUT" "Task Identity" "candidate identity injection"
done
PWF_PROJECT_ROOT="$PROJECT" PWF_SESSION_ADAPTER=codex PWF_SESSION_ID=codex-contract "$STATE_TOOL" bind test-task >/dev/null
PWF_PROJECT_ROOT="$PROJECT" PWF_SESSION_ADAPTER=claude PWF_SESSION_ID=claude-contract "$STATE_TOOL" bind test-task >/dev/null
PWF_PROJECT_ROOT="$PROJECT" PWF_SESSION_ADAPTER=copilot PWF_SESSION_ID=copilot-contract "$STATE_TOOL" bind test-task >/dev/null

write_contracted_plan
sed -i '/^## Active Item$/{n;/^P1\.1$/d;}' "$PLAN_DIR/tasks.md"
for SPEC in 'codex codex-contract' 'claude claude-contract' 'copilot copilot-contract'; do
    set -- $SPEC
    assert_contains "$(pre_hook "$1" "$2" "npm test")" "ITEM STATE ACTION REQUIRED" "$1 PreTool blocks operation with missing Active Item"
    assert_eq "$(pre_hook "$1" "$2" "rg Phase .")" "{}" "$1 PreTool allows read-only item repair diagnosis"
    assert_eq "$(pre_hook "$1" "$2" "python3 $CHECKPOINT_TOOL --plan $PLAN_DIR/tasks.md start P1.1")" "{}" "$1 PreTool allows structured item repair"
done
write_contracted_plan
for SPEC in 'codex codex-contract' 'claude claude-contract' 'copilot copilot-contract'; do
    set -- $SPEC
    assert_contains "$(post_hook "$1" "$2")" "Active Item P1.1" "$1 PostTool initial item context"
    assert_contains "$(post_hook "$1" "$2")" "structured checkpoint before any unrelated tool" "$1 PostTool checkpoint barrier"
    POST_STATE=$(PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" cache "$1" "$2")
    sed -i 's/^unchanged_tool_count=.*/unchanged_tool_count=2/; s/^last_item_nudge_ts=.*/last_item_nudge_ts=0/' "$POST_STATE"
    assert_contains "$(post_hook "$1" "$2")" "STALE ITEM STATE: 3 tool result" "$1 PostTool stale item detection"
done
grep -q '^- \[ \] \[P1.1\]' "$PLAN_DIR/tasks.md" || fail "PostTool never auto-completes an item"
POST_LOG=$(cat "$PROJECT/tmp/hook-logs/plan-with-files/post-tool-use.log")
assert_contains "$POST_LOG" "item_state fingerprint=" "PostTool log exposes fingerprint"
assert_contains "$POST_LOG" "active_item=P1.1" "PostTool log exposes Active Item"
assert_contains "$POST_LOG" "checkpoint_lag=" "PostTool log exposes checkpoint lag"
assert_contains "$POST_LOG" "stale=true" "PostTool log exposes stale state"

CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_PAYLOAD" | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh")
CLAUDE_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CLAUDE_PAYLOAD" | "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/agent-stop.sh")
GITHUB_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$COPILOT_PAYLOAD" | "$REPO_ROOT/.github/hooks/scripts/agent-stop.sh")
assert_contains "$CODEX_OUTPUT" "Task incomplete" "Codex Stop adapter"
assert_contains "$CLAUDE_OUTPUT" "Task incomplete" "Claude Stop adapter"
assert_contains "$GITHUB_OUTPUT" "Task incomplete" "Copilot Stop adapter"
for OUTPUT in "$CODEX_OUTPUT" "$CLAUDE_OUTPUT" "$GITHUB_OUTPUT"; do
    assert_contains "$OUTPUT" "progress, not a stopping boundary" "phase persistence rejects item-level Stop"
    assert_contains "$OUTPUT" "every unchecked item in every non-settled phase" "phase persistence covers every phase"
    assert_contains "$OUTPUT" "advance Current Phase" "phase persistence advances later phases"
    assert_contains "$OUTPUT" "blocked (reason)" "external blocker has a terminating state"
    assert_contains "$OUTPUT" "deferred (reason)" "user deferral has a terminating state"
    assert_contains "$OUTPUT" "Active Item P1.1" "Stop targets contracted Active Item"
done
CODEX_REPEAT_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_REPEAT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh")
CLAUDE_REPEAT_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CLAUDE_REPEAT_PAYLOAD" | "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/agent-stop.sh")
COPILOT_REPEAT_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$COPILOT_REPEAT_PAYLOAD" | "$REPO_ROOT/.github/hooks/scripts/agent-stop.sh")
for OUTPUT in "$CODEX_REPEAT_OUTPUT" "$CLAUDE_REPEAT_OUTPUT" "$COPILOT_REPEAT_OUTPUT"; do
    assert_contains "$OUTPUT" "Task incomplete" "active Stop remains blocked"
    assert_contains "$OUTPUT" "No structured plan progress" "repeated Stop reports no progress"
    assert_contains "$OUTPUT" "Do not answer this hook with another summary" "repeated Stop demands operational recovery"
done
STOP_LOG=$(cat "$PROJECT/tmp/hook-logs/plan-with-files/agent-stop.log")
assert_contains "$STOP_LOG" "progress fingerprint=" "Stop log exposes fingerprint"
assert_contains "$STOP_LOG" "no_progress_count=1" "Stop log exposes repeated no-progress count"
assert_contains "$STOP_LOG" "active_item=P1.1" "Stop log exposes Active Item"
assert_not_contains "$CODEX_REPEAT_OUTPUT" "Monitor" "background/async nudge does not fire on only the first no-progress repeat"

# A second consecutive no-progress Stop (still no plan change) nudges toward
# a streaming/monitor tool instead of manually ending the turn to re-poll a
# background process -- this is the pattern that caused a real repeated-Stop
# loop while an agent tailed a still-running e2e test log.
CODEX_REPEAT2_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_REPEAT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh")
assert_contains "$CODEX_REPEAT2_OUTPUT" "background/async process" "second consecutive no-progress Stop names the likely cause"
assert_contains "$CODEX_REPEAT2_OUTPUT" "Monitor" "second consecutive no-progress Stop points at a streaming/monitor tool"
assert_contains "$CODEX_REPEAT2_OUTPUT" "blocked (reason)" "second consecutive no-progress Stop also offers blocked as a fallback"

python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" progress P1.1 --evidence "implementation now exists" >/dev/null
CODEX_PROGRESS_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_REPEAT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh")
assert_contains "$CODEX_PROGRESS_OUTPUT" "Structured plan progress occurred" "item progress resets Stop recovery state"

write_valid_plan
sed -i 's/in_progress/blocked (external dependency unavailable)/; s/pending/deferred (user postponed validation)/' "$PLAN_DIR/tasks.md"
CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_REPEAT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh")
CLAUDE_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CLAUDE_REPEAT_PAYLOAD" | "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/agent-stop.sh")
GITHUB_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$COPILOT_REPEAT_PAYLOAD" | "$REPO_ROOT/.github/hooks/scripts/agent-stop.sh")
assert_eq "$CODEX_OUTPUT" "{}" "Codex repeated Stop allows blocked/deferred phases"
assert_eq "$CLAUDE_OUTPUT" "{}" "Claude repeated Stop allows blocked/deferred phases"
assert_eq "$GITHUB_OUTPUT" "{}" "Copilot repeated Stop allows blocked/deferred phases"

write_valid_plan
sed -i 's/in_progress/blocked (external dependency unavailable)/' "$PLAN_DIR/tasks.md"
CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_REPEAT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh")
assert_contains "$CODEX_OUTPUT" "STALE" "blocked current phase advances to later actionable phase"

write_valid_plan

sed -i '/\*\*Status:\*\* pending/d' "$PLAN_DIR/tasks.md"
CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_PAYLOAD" | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh")
CLAUDE_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CLAUDE_PAYLOAD" | "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/agent-stop.sh")
GITHUB_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$COPILOT_PAYLOAD" | "$REPO_ROOT/.github/hooks/scripts/agent-stop.sh")
for OUTPUT in "$CODEX_OUTPUT" "$CLAUDE_OUTPUT" "$GITHUB_OUTPUT"; do
    assert_contains "$OUTPUT" "exactly one recognized" "phase-status adapter routing"
done

write_valid_plan
sed -i 's/^Phase 1$//; s/in_progress/pending/' "$PLAN_DIR/tasks.md"
CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_PAYLOAD" | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh")
assert_eq "$CODEX_OUTPUT" "{}" "Codex discussion mode"

write_valid_plan
sed -i 's/^- \[ \] Make the change/- [x] Make the change/; s/in_progress/complete/' "$PLAN_DIR/tasks.md"
CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_PAYLOAD" | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh")
assert_contains "$CODEX_OUTPUT" "STALE" "Codex stale Current Phase"

printf 'planning contract tests: PASS\n'
