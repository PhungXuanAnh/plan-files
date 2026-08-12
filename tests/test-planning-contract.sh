#!/bin/bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE_TOOL="$REPO_ROOT/skills/planning-with-files/scripts/session-state.sh"
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

write_valid_plan
count_phases "$PLAN_DIR/tasks.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/tasks.md")" "" "valid plan"
assert_eq "$(current_phase_pointer "$PLAN_DIR/tasks.md")" "Phase 1" "exact current pointer"
assert_eq "$TOTAL/$IN_PROGRESS/$PENDING" "2/1/1" "phase counts"

sed '/^## Phases$/d' "$PLAN_DIR/tasks.md" > "$PLAN_DIR/bad-layout.md"
count_phases "$PLAN_DIR/bad-layout.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/bad-layout.md")" "SECTION_LAYOUT_INVALID" "missing Phases section"

sed 's/^Phase 1$/Phase 1 extra/' "$PLAN_DIR/tasks.md" > "$PLAN_DIR/bad-current.md"
count_phases "$PLAN_DIR/bad-current.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/bad-current.md")" "CURRENT_PHASE_INVALID" "invalid Current Phase body"

sed 's/^### Phase 1:/### Phase one:/' "$PLAN_DIR/tasks.md" > "$PLAN_DIR/bad-heading.md"
count_phases "$PLAN_DIR/bad-heading.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/bad-heading.md")" "PHASE_HEADING_INVALID" "malformed phase heading"

sed '/\*\*Status:\*\* pending/d' "$PLAN_DIR/tasks.md" > "$PLAN_DIR/missing-status.md"
count_phases "$PLAN_DIR/missing-status.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/missing-status.md")" "PHASE_STATUS_INVALID" "missing phase status"

sed '/\*\*Status:\*\* pending/a\- **Status:** complete' "$PLAN_DIR/tasks.md" > "$PLAN_DIR/duplicate-status.md"
count_phases "$PLAN_DIR/duplicate-status.md"
assert_eq "$(check_task_plan_format "$PLAN_DIR/duplicate-status.md")" "PHASE_STATUS_INVALID" "duplicate phase status"

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

CODEX_PAYLOAD='{"session_id":"codex-contract","hook_event_name":"Stop","stop_hook_active":false}'
CLAUDE_PAYLOAD='{"session_id":"claude-contract","hook_event_name":"Stop","stop_hook_active":false}'
COPILOT_PAYLOAD='{"session_id":"copilot-contract","hook_event_name":"Stop","stop_hook_active":false}'

CODEX_CANDIDATE=$(cd "$PROJECT" && printf '%s\n' '{"session_id":"codex-contract","hook_event_name":"UserPromptSubmit","prompt":"continue contract-fixture"}' | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/user-prompt-submit.sh")
CLAUDE_CANDIDATE=$(cd "$PROJECT" && printf '%s\n' '{"session_id":"claude-contract","hook_event_name":"UserPromptSubmit","prompt":"continue contract-fixture"}' | "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/user-prompt-submit.sh")
COPILOT_CANDIDATE=$(cd "$PROJECT" && printf '%s\n' '{"sessionId":"copilot-contract","transformedPrompt":"continue contract-fixture"}' | "$REPO_ROOT/.github/hooks/scripts/user-prompt-transformed.py")
for OUTPUT in "$CODEX_CANDIDATE" "$CLAUDE_CANDIDATE" "$COPILOT_CANDIDATE"; do
    assert_contains "$OUTPUT" "Task Identity" "candidate identity injection"
done
PWF_PROJECT_ROOT="$PROJECT" PWF_SESSION_ADAPTER=codex PWF_SESSION_ID=codex-contract "$STATE_TOOL" bind test-task >/dev/null
PWF_PROJECT_ROOT="$PROJECT" PWF_SESSION_ADAPTER=claude PWF_SESSION_ID=claude-contract "$STATE_TOOL" bind test-task >/dev/null
PWF_PROJECT_ROOT="$PROJECT" PWF_SESSION_ADAPTER=copilot PWF_SESSION_ID=copilot-contract "$STATE_TOOL" bind test-task >/dev/null

CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_PAYLOAD" | "$REPO_ROOT/.codex/hooks/planning-with-files/scripts/agent-stop.sh")
CLAUDE_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CLAUDE_PAYLOAD" | "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/agent-stop.sh")
GITHUB_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$COPILOT_PAYLOAD" | "$REPO_ROOT/.github/hooks/scripts/agent-stop.sh")
assert_contains "$CODEX_OUTPUT" "Task incomplete" "Codex Stop adapter"
assert_contains "$CLAUDE_OUTPUT" "Task incomplete" "Claude Stop adapter"
assert_contains "$GITHUB_OUTPUT" "Task incomplete" "Copilot Stop adapter"

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
