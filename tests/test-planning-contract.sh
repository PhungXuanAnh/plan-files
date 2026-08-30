#!/bin/bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE_TOOL="$REPO_ROOT/skills/plan-files/scripts/session-state.sh"
CHECKPOINT_TOOL="$REPO_ROOT/skills/plan-files/scripts/plan_checkpoint.py"
EDIT_TOOL="$REPO_ROOT/skills/plan-files/scripts/plan_edit.py"
# shellcheck source=../.codex/hooks/plan-files/scripts/common.sh
source "$REPO_ROOT/.codex/hooks/plan-files/scripts/common.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
PROJECT="$TEST_DIR/project"
PLAN_DIR="$PROJECT/tmp/plan-files/test-task"
mkdir -p "$PLAN_DIR"
printf '%s\n' test-task > "$PROJECT/.plan-files"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3 (missing '$2')" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3 (unexpected '$2')" ;; esac; }
file_sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

post_hook() {
    local provider=$1 session=$2 tool_name=${3:-Read} command=${4:-} script
    case "$provider" in
        codex) script="$REPO_ROOT/.codex/hooks/plan-files/scripts/post-tool-use.sh" ;;
        claude) script="$REPO_ROOT/.claude/hooks/plan-files/scripts/post-tool-use.sh" ;;
        copilot) script="$REPO_ROOT/.github/hooks/scripts/post-tool-use.sh" ;;
    esac
    (cd "$PROJECT" && python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"hook_event_name":"PostToolUse","tool_name":sys.argv[2],"tool_input":{"command":sys.argv[3]} if sys.argv[3] else {"file_path":"README.md"}}))' "$session" "$tool_name" "$command" | "$script")
}

pre_hook() {
    local provider=$1 session=$2 command=$3 script
    case "$provider" in
        codex) script="$REPO_ROOT/.codex/hooks/plan-files/scripts/pre-tool-use.sh" ;;
        claude) script="$REPO_ROOT/.claude/hooks/plan-files/scripts/pre-tool-use.sh" ;;
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
    printf '# Findings\n\n## Current Summary\n- fixture\n\n## Discoveries\n- original\n' > "$PLAN_DIR/findings.md"
    cat > "$PLAN_DIR/decisions.md" <<'EOF'
# Decisions

## Active Decisions
| ID | Decision | Rationale | Date |
|----|----------|-----------|------|
| D1 | Old | initial | 2026-08-28 |
| D2 | New | updated | 2026-08-28 |

## Superseded Decisions
| ID | Old Decision | Replaced By | Reason |
|----|--------------|-------------|--------|

## Open Decision Questions
- None.
EOF
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

## Verification
- `make test`: pending
EOF
}

write_rollover_plan() {
    rm -f "$PLAN_DIR/history.md"
    cat > "$PLAN_DIR/tasks.md" <<'EOF'
# Tasks: Rollover Fixture

## Goal
Verify the rolling hot phase window.

## Task Identity
- Deliverable: Verify rollover
- Anchors: rollover-fixture
- Non-goals: unrelated behavior

## Current Phase
Phase 12

## Workflow Profile
**Profile:** C

## Resume Checkpoint
- **Next action:** Continue Phase 12.
- **Blocker:** none
- **Details:** none

## Phases
EOF
    for N in $(seq 1 11); do
        printf '\n### Phase %s: Completed %s [complete]\n' "$N" "$N" >> "$PLAN_DIR/tasks.md"
    done
    cat >> "$PLAN_DIR/tasks.md" <<'EOF'

### Phase 12: Current
- [ ] Current work
- **Status:** in_progress
EOF
}

write_evidenced_archive_plan() {
    rm -f "$PLAN_DIR/history.md" "$PLAN_DIR/.plan-edit-transaction.json"
    cat > "$PLAN_DIR/tasks.md" <<'EOF'
# Tasks: Evidenced Archive Fixture

## Goal
Preserve evidence through interrupted archival.

## Task Identity
- Deliverable: recovered archive fixture
- Anchors: recovery-fixture
- Non-goals: unrelated state

## Current Phase
Phase 2

## Active Item
P2.1

## Workflow Profile
**Profile:** C

## Resume Checkpoint
- **Next action:** Complete P2.1: continue current work
- **Blocker:** none
- **Details:** none

## Phases

### Phase 1: Evidenced completion
- [x] [P1.1] The durable artifact exists.
  - Evidence: artifact sha abc123
- **Status:** complete

### Phase 2: Current
- [ ] [P2.1] Current work remains active.
  - Evidence: pending
- **Status:** in_progress

## Verification
- `test -f artifact`: PASS
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
assert_contains "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" restore-check "$PLAN_DIR/tasks.md")" '"ok":true' "restore check accepts complete hot state"
python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" complete P1.1 --evidence "implementation exists" >/dev/null
assert_contains "$(planning_item_context "$PLAN_DIR/tasks.md")" '"active_item":"V1.1"' "checkpoint selects phase acceptance"
assert_contains "$(cat "$PLAN_DIR/tasks.md")" 'Next action:** Complete V1.1:' "checkpoint synchronizes exact next action"
python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" complete V1.1 --evidence "focused check passed" >/dev/null
assert_contains "$(planning_item_context "$PLAN_DIR/tasks.md")" '"active_item":"P2.1"' "checkpoint advances phase"
assert_contains "$(current_phase_pointer "$PLAN_DIR/tasks.md")" "Phase 2" "checkpoint advances Current Phase"
python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" complete P2.1 --evidence "regression check passed" >/dev/null
python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" complete V2.1 --evidence "final review passed" --deactivate-pointer >/dev/null
assert_eq "$(planning_assert_finalizable "$PLAN_DIR/tasks.md" "$PROJECT")" "FINALIZABLE" "final checkpoint settles and deactivates plan"
assert_eq "$(cat "$PROJECT/.plan-files")" "" "final checkpoint clears owned pointer"
printf '%s\n' test-task > "$PROJECT/.plan-files"

# Restore validation diagnoses every context-bearing field with a targeted
# repair instead of allowing placeholders to masquerade as resumable state.
write_contracted_plan
sed -i \
    -e 's/^Verify outcome-item transitions\.$/[one sentence goal]/' \
    -e 's/^- Deliverable:.*/- Deliverable: [specific result]/' \
    -e 's/^- Anchors:.*/- Anchors: [stable identifier]/' \
    -e 's/^- Non-goals:.*/- Non-goals: [scope boundary]/' \
    -e 's/^- \*\*Next action:\*\*.*/- **Next action:** [exact action]/' \
    -e 's/^- \*\*Blocker:\*\*.*/- **Blocker:** [blocker]/' \
    -e '/^## Active Item$/{n;/^P1\.1$/d;}' \
    -e 's/^- `make test`:.*/- <exact command or check>/' \
    "$PLAN_DIR/tasks.md"
printf '# Decisions\n\n## Active Decisions\n| ID | Decision | Rationale | Date |\n|----|----------|-----------|------|\n' > "$PLAN_DIR/decisions.md"
printf '# Findings\n\n## Current Summary\n-\n' > "$PLAN_DIR/findings.md"
if RESTORE_BROKEN=$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" restore-check "$PLAN_DIR/tasks.md"); then
    fail "restore check rejects placeholder hot state"
fi
for CODE in RESTORE_GOAL_MISSING RESTORE_IDENTITY_DELIVERABLE_MISSING RESTORE_IDENTITY_ANCHORS_MISSING \
    RESTORE_IDENTITY_NON_GOALS_MISSING RESTORE_NEXT_ACTION_MISSING RESTORE_BLOCKER_MISSING \
    RESTORE_ACTIVE_ITEM_MISSING RESTORE_VERIFICATION_MISSING RESTORE_ACTIVE_DECISIONS_MISSING \
    RESTORE_FINDINGS_MISSING; do
    assert_contains "$RESTORE_BROKEN" "$CODE" "restore check reports $CODE"
done
write_valid_plan

# Bounded reads and one consolidated edit/lifecycle flow cover the main plan
# operations without requiring a caller to load or patch the full files.
write_contracted_plan
OVERVIEW_OUTPUT=$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" overview "$PLAN_DIR/tasks.md")
assert_contains "$OVERVIEW_OUTPUT" '"findings_summary":"- fixture"' "bounded overview"
assert_contains "$OVERVIEW_OUTPUT" '"schema_version":2' "overview schema version"
assert_contains "$OVERVIEW_OUTPUT" '"restore":{"ok":true' "bounded overview reports restore readiness"
[ "${#OVERVIEW_OUTPUT}" -le 4096 ] || fail "overview obeys total character cap"
assert_eq "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" resume-pack "$PLAN_DIR/tasks.md")" \
    "$OVERVIEW_OUTPUT" "resume-pack aliases overview"
assert_contains "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" phase "$PLAN_DIR/tasks.md" 1)" '"phase":1' "bounded phase"
assert_contains "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" item "$PLAN_DIR/tasks.md" P1.1)" '"item":"P1.1"' "bounded item"
assert_contains "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" budgets "$PLAN_DIR/tasks.md")" \
    "\"fingerprint\":\"$(file_sha "$PLAN_DIR/tasks.md")\"" "budget read returns plan fingerprint"

# Oversized resume content is never silently cut: the whole JSON stays within
# its default cap and names the exact targeted read that restores the source.
printf '# Findings\n\n## Current Summary\n- ' > "$PLAN_DIR/findings.md"
head -c 8000 /dev/zero | tr '\0' x >> "$PLAN_DIR/findings.md"
printf '\n\n## Discoveries\n- fixture\n' >> "$PLAN_DIR/findings.md"
OVERSIZED_OVERVIEW=$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" overview "$PLAN_DIR/tasks.md")
[ "${#OVERSIZED_OVERVIEW}" -le 4096 ] || fail "oversized overview obeys total character cap"
printf '%s' "$OVERSIZED_OVERVIEW" | python3 -c '
import json, sys
p = json.load(sys.stdin)
meta = p["view_meta"]
entry = meta["truncated_sections"].get("findings_summary")
target = meta["next_read"]["targets"].get("findings_summary")
assert entry and entry["chars"] > entry["returned_chars"]
assert target == ["findings.md", "Current Summary"]
' || fail "oversized overview exposes restorable truncation metadata"
write_contracted_plan

ORIGINAL_SHA=$(file_sha "$PLAN_DIR/tasks.md")
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$ORIGINAL_SHA" --dry-run \
    item-update P2.1 --text "dry-run text" >/dev/null
assert_eq "$(file_sha "$PLAN_DIR/tasks.md")" "$ORIGINAL_SHA" "dry-run is immutable"

OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    phase-add --title "Temporary" --after 2)
assert_contains "$OUTPUT" '"phase":3' "phase add allocates next id"
OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    item-add --phase 3 --kind V --text "Temporary acceptance")
assert_contains "$OUTPUT" '"item":"V3.1"' "acceptance item add allocates a V id"
assert_contains "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" phase "$PLAN_DIR/tasks.md" 3)" \
    '**Done when:**\n- [ ] [V3.1] Temporary acceptance\n  - Evidence: pending\n- **Status:** pending' \
    "acceptance item stays before phase status"
OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    item-add --phase 2 --text "Temporary item")
assert_contains "$OUTPUT" '"item":"P2.2"' "item add allocates next id"
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    item-update P2.2 --text "Updated temporary item" >/dev/null
OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    item-move P2.2 --phase 3)
assert_contains "$OUTPUT" '"old_item":"P2.2"' "cross-phase move reports mapping"
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    item-remove P3.1 >/dev/null
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    item-remove V3.1 >/dev/null
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    phase-remove 3 >/dev/null
OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    phase-add --title "Stable replacement" --after 2)
assert_contains "$OUTPUT" '"phase":4' "retired phase id is not reused"
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    phase-move 4 --before 2 >/dev/null
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    phase-remove 4 >/dev/null
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$ORIGINAL_SHA" \
    item-update P2.1 --text "stale write" >/dev/null; then
    fail "structural edit rejects stale fingerprint"
fi
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    item-remove P1.1 >/dev/null; then
    fail "structural edit rejects active item removal"
fi

FINDINGS_SHA=$(file_sha "$PLAN_DIR/findings.md")
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$FINDINGS_SHA" \
    entry-append --file findings.md --heading Discoveries --entry '- added' >/dev/null
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/findings.md")" \
    entry-replace --file findings.md --heading Discoveries --entry '- added' --replacement '- replaced' >/dev/null
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/findings.md")" \
    entry-remove --file findings.md --heading Discoveries --entry '- replaced' >/dev/null
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/findings.md")" \
    section-replace --file findings.md --heading Discoveries \
    --content "$(printf '%s\n' '- safe' '## Escaped Section')" >/dev/null; then
    fail "section replacement rejects a nested level-2 heading"
fi
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/decisions.md")" \
    decision-supersede D1 --replacement D2 --reason "changed" >/dev/null
assert_contains "$(cat "$PLAN_DIR/decisions.md")" '| D1 | Old | D2 | changed |' "decision supersession"

python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" complete P1.1 --evidence "implementation exists" >/dev/null
python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" complete V1.1 --evidence "focused check passed" >/dev/null
OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    archive-phase 1 --expected-history-fingerprint missing)
assert_contains "$OUTPUT" '"transaction_id":"' "phase archive reports its transaction"
[ ! -e "$PLAN_DIR/.plan-edit-transaction.json" ] || fail "successful phase archive clears its journal"
assert_not_contains "$(cat "$PLAN_DIR/tasks.md")" '### Phase 1:' "archive evicts completed phase from hot window"
assert_contains "$(cat "$PLAN_DIR/tasks.md")" '<!-- Phase ID high-water: 4 -->' "archive preserves previously allocated phase ids"
assert_contains "$(cat "$PLAN_DIR/history.md")" 'Archived Phase 1' "archive writes history first"
OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    archive-entry --source-section Verification --entry '- `make test`: pending' \
    --archive-entry '- `make test`: passed in fixture' --expected-history-fingerprint "$(file_sha "$PLAN_DIR/history.md")")
assert_contains "$OUTPUT" '"transaction_id":"' "entry archive reports its transaction"
[ ! -e "$PLAN_DIR/.plan-edit-transaction.json" ] || fail "successful entry archive clears its journal"
assert_contains "$(cat "$PLAN_DIR/history.md")" '`make test`: passed in fixture' "entry archive commits history"

HANDOFF_WITHOUT_FRESHNESS=$(printf '# Handoff\n\n## Resume Checkpoint\n- current\n\n## Working State\n- state\n\n## Verification\n- pending\n\n## Safety\n- preserve')
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint missing \
    handoff-write --content "$HANDOFF_WITHOUT_FRESHNESS" >/dev/null; then
    fail "handoff write requires freshness metadata"
fi
HANDOFF_CONTENT=$(printf '# Handoff\n\nUpdated: 2030-01-01T00:00:00+00:00\nReverify after: 2030-01-01T01:00:00+00:00\n\n## Resume Checkpoint\n- current\n\n## Working State\n- state\n\n## Verification\n- pending\n\n## Safety\n- preserve')
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint missing \
    handoff-write --content "$HANDOFF_CONTENT" >/dev/null
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/handoff.md")" \
    handoff-clear >/dev/null
[ ! -e "$PLAN_DIR/handoff.md" ] || fail "handoff clear removes obsolete snapshot"
assert_eq "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" validate "$PLAN_DIR/tasks.md")" "" "edited plan remains valid"

# pause settles a phase and stages its handoff in one ordered transaction. The
# order is the point: a handoff written before tasks.md is stale on arrival.
PAUSE_BEFORE=$(file_sha "$PLAN_DIR/tasks.md")
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$PAUSE_BEFORE" \
    pause --phase 2 --reason "   " >/dev/null 2>&1; then
    fail "pause requires a non-empty reason"
fi
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$PAUSE_BEFORE" \
    pause --phase 2 --all-remaining --reason quota >/dev/null 2>&1; then
    fail "pause rejects --phase together with --all-remaining"
fi
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$PAUSE_BEFORE" \
    pause --phase 2 --reason quota --handoff-content '# Handoff' >/dev/null 2>&1; then
    fail "pause rejects an invalid handoff body"
fi
assert_eq "$(file_sha "$PLAN_DIR/tasks.md")" "$PAUSE_BEFORE" "rejected pause leaves tasks.md untouched"
[ ! -e "$PLAN_DIR/handoff.md" ] || fail "rejected pause writes no handoff"
PAUSE_HANDOFF=$(printf '# Handoff\n\nUpdated: 2030-01-01T00:00:00+00:00\nReverify after: 2030-01-01T01:00:00+00:00\n\n## Resume Checkpoint\n- current\n\n## Working State\n- state\n\n## Verification\n- pending\n\n## Safety\n- preserve')
PAUSE_OUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$PAUSE_BEFORE" \
    pause --all-remaining --reason "user paused for quota" --handoff-content "$PAUSE_HANDOFF")
assert_contains "$PAUSE_OUT" '"handoff_written":true' "pause writes the staged handoff"
assert_contains "$PAUSE_OUT" '"still_actionable":[]' "pause --all-remaining leaves nothing actionable"
assert_contains "$(cat "$PLAN_DIR/tasks.md")" '- **Status:** deferred (user paused for quota)' "pause writes the exact status grammar"
assert_eq "$(sed -n '/^## Active Item$/,/^## /p' "$PLAN_DIR/tasks.md" | sed '1d;$d' | tr -d '[:space:]')" "" "pause clears Active Item once nothing is actionable"
assert_contains "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" restore-check "$PLAN_DIR/tasks.md" || true)" \
    '"newer_files":[]' "pause leaves the handoff fresh, not dependency-stale"
python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" assert-finalizable >/dev/null \
    || fail "pause produces a finalizable plan"
rm -f "$PLAN_DIR/handoff.md"

# phase-add keeps a rolling 12-heading hot window by archiving the oldest
# eligible complete phase before allocating each monotonic phase ID.
write_rollover_plan
ROLLOVER_SHA=$(file_sha "$PLAN_DIR/tasks.md")
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$ROLLOVER_SHA" \
    phase-add --title "Thirteenth" --after 12 >/dev/null; then
    fail "phase rollover requires a history fingerprint"
fi
assert_eq "$(file_sha "$PLAN_DIR/tasks.md")" "$ROLLOVER_SHA" "missing history fingerprint leaves tasks unchanged"
cat > "$PLAN_DIR/history.md" <<'EOF'
# History

## Completed Phases

## Verification History

## Resolved Errors
EOF
HISTORY_SHA=$(file_sha "$PLAN_DIR/history.md")
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$ROLLOVER_SHA" \
    phase-add --title "Stale history" --after 12 --expected-history-fingerprint missing >/dev/null; then
    fail "phase rollover rejects a stale history fingerprint"
fi
assert_eq "$(file_sha "$PLAN_DIR/tasks.md")" "$ROLLOVER_SHA" "stale history leaves tasks unchanged"
assert_eq "$(file_sha "$PLAN_DIR/history.md")" "$HISTORY_SHA" "stale history leaves history unchanged"
rm -f "$PLAN_DIR/history.md"
OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$ROLLOVER_SHA" \
    phase-add --title "Thirteenth" --after 12 --expected-history-fingerprint missing)
assert_contains "$OUTPUT" '"phase":13' "rollover allocates Phase 13"
assert_contains "$OUTPUT" '"archived_phase":1' "rollover archives oldest complete phase"
assert_not_contains "$(cat "$PLAN_DIR/tasks.md")" '### Phase 1:' "archived phase leaves the hot window"
assert_contains "$(cat "$PLAN_DIR/history.md")" '### Phase 1: Completed 1 [complete]' "rollover writes full phase history"
assert_contains "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" budgets "$PLAN_DIR/tasks.md")" '"phases":12' "rollover retains twelve hot phase headings"
OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    phase-add --title "Fourteenth" --after 13 --expected-history-fingerprint "$(file_sha "$PLAN_DIR/history.md")")
assert_contains "$OUTPUT" '"phase":14' "next rollover allocates Phase 14"
assert_contains "$OUTPUT" '"archived_phase":2' "next rollover archives the next oldest phase"
assert_contains "$(cat "$PLAN_DIR/tasks.md")" '<!-- Phase ID high-water: 14 -->' "phase high-water remains monotonic"

write_rollover_plan
OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
    compact-oldest --expected-history-fingerprint missing)
assert_contains "$OUTPUT" '"phase":1' "explicit compaction selects oldest complete phase"
assert_not_contains "$(cat "$PLAN_DIR/tasks.md")" '### Phase 1:' "explicit compaction evicts the selected phase"
assert_contains "$(cat "$PLAN_DIR/history.md")" '### Phase 1: Completed 1 [complete]' "explicit compaction preserves phase history"
assert_contains "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" budgets "$PLAN_DIR/tasks.md")" '"phases":11' "explicit compaction shrinks hot phase count"

# A journal left after any durable-write boundary is reconciled on the next
# plan_edit invocation. Repeating recovery is a no-op and never duplicates
# the archive marker.
for BOUNDARY in journal history tasks; do
    write_evidenced_archive_plan
    OLD_TASKS_SHA=$(file_sha "$PLAN_DIR/tasks.md")
    if PWF_PLAN_EDIT_FAIL_AFTER="$BOUNDARY" python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" \
        --expected-fingerprint "$OLD_TASKS_SHA" archive-phase 1 \
        --expected-history-fingerprint missing >/dev/null; then
        fail "failure injection stops archive-phase after $BOUNDARY"
    fi
    JOURNAL="$PLAN_DIR/.plan-edit-transaction.json"
    [ -f "$JOURNAL" ] || fail "$BOUNDARY interruption preserves transaction journal"
    TARGET_TASKS_SHA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks_fingerprint"])' "$JOURNAL")
    case "$BOUNDARY" in
        journal)
            assert_eq "$(file_sha "$PLAN_DIR/tasks.md")" "$OLD_TASKS_SHA" "journal boundary leaves tasks old"
            [ ! -e "$PLAN_DIR/history.md" ] || fail "journal boundary leaves history old"
            ;;
        history)
            assert_eq "$(file_sha "$PLAN_DIR/tasks.md")" "$OLD_TASKS_SHA" "history boundary leaves tasks old"
            [ -f "$PLAN_DIR/history.md" ] || fail "history boundary commits history first"
            ;;
        tasks)
            assert_eq "$(file_sha "$PLAN_DIR/tasks.md")" "$TARGET_TASKS_SHA" "tasks boundary commits both target files"
            [ -f "$PLAN_DIR/history.md" ] || fail "tasks boundary retains history target"
            ;;
    esac
    python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$TARGET_TASKS_SHA" --dry-run \
        phase-update 2 --title Current >/dev/null
    [ ! -e "$JOURNAL" ] || fail "$BOUNDARY recovery clears transaction journal"
    assert_eq "$(file_sha "$PLAN_DIR/tasks.md")" "$TARGET_TASKS_SHA" "$BOUNDARY recovery commits tasks target"
    assert_eq "$(grep -c 'Archived Phase 1:' "$PLAN_DIR/history.md")" "1" "$BOUNDARY recovery writes one history marker"
    assert_eq "$(grep -c 'artifact sha abc123' "$PLAN_DIR/history.md")" "1" "$BOUNDARY recovery preserves evidence exactly once"
    assert_not_contains "$(cat "$PLAN_DIR/tasks.md")" '### Phase 1:' "$BOUNDARY recovery evicts archived hot detail"
    assert_contains "$(cat "$PLAN_DIR/tasks.md")" '<!-- Phase ID high-water: 2 -->' "$BOUNDARY recovery preserves phase identity high-water"
    RECOVERED_TASKS_SHA=$(file_sha "$PLAN_DIR/tasks.md")
    RECOVERED_HISTORY_SHA=$(file_sha "$PLAN_DIR/history.md")
    python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$RECOVERED_TASKS_SHA" --dry-run \
        phase-update 2 --title Current >/dev/null
    assert_eq "$(file_sha "$PLAN_DIR/tasks.md")/$(file_sha "$PLAN_DIR/history.md")" \
        "$RECOVERED_TASKS_SHA/$RECOVERED_HISTORY_SHA" "$BOUNDARY recovery is idempotent"
    OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$RECOVERED_TASKS_SHA" \
        phase-add --title "Post-recovery" --after 2)
    assert_contains "$OUTPUT" '"phase":3' "$BOUNDARY recovery keeps phase IDs monotonic"
    OUTPUT=$(python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$(file_sha "$PLAN_DIR/tasks.md")" \
        item-add --phase 3 --text "Post-recovery item")
    assert_contains "$OUTPUT" '"item":"P3.1"' "$BOUNDARY recovery allocates phase-matching item IDs"
done

# The plan-directory lock serializes competing editors: exactly one writer
# can consume a fingerprint, so phase IDs are not allocated twice and
# unrelated ledgers remain byte-identical.
write_valid_plan
write_contracted_plan
CONCURRENT_SHA=$(file_sha "$PLAN_DIR/tasks.md")
CONCURRENT_FINDINGS_SHA=$(file_sha "$PLAN_DIR/findings.md")
set +e
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$CONCURRENT_SHA" \
    phase-add --title "Concurrent A" --after 2 > "$TEST_DIR/concurrent-a.json" &
PID_A=$!
python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$CONCURRENT_SHA" \
    phase-add --title "Concurrent B" --after 2 > "$TEST_DIR/concurrent-b.json" &
PID_B=$!
wait "$PID_A"; STATUS_A=$?
wait "$PID_B"; STATUS_B=$?
set -e
assert_eq "$((STATUS_A + STATUS_B))" "2" "one concurrent editor succeeds and one rejects stale state"
assert_eq "$(grep -Ec '^### Phase 3: Concurrent [AB]$' "$PLAN_DIR/tasks.md")" "1" "concurrent phase allocation writes one Phase 3"
assert_not_contains "$(cat "$PLAN_DIR/tasks.md")" '### Phase 4: Concurrent' "concurrent allocation never skips/reuses into Phase 4"
assert_eq "$(file_sha "$PLAN_DIR/findings.md")" "$CONCURRENT_FINDINGS_SHA" "concurrent structural edits preserve unrelated findings"

# If state outside the journal changes, recovery fails closed and preserves
# both the conflicting file and the still-unapplied target.
write_rollover_plan
CONFLICT_TASKS_SHA=$(file_sha "$PLAN_DIR/tasks.md")
if PWF_PLAN_EDIT_FAIL_AFTER=history python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" \
    --expected-fingerprint "$CONFLICT_TASKS_SHA" compact-oldest \
    --expected-history-fingerprint missing >/dev/null; then
    fail "history conflict fixture stops after history"
fi
CONFLICT_JOURNAL="$PLAN_DIR/.plan-edit-transaction.json"
CONFLICT_TARGET_SHA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks_fingerprint"])' "$CONFLICT_JOURNAL")
printf '\nUnrelated concurrent history note.\n' >> "$PLAN_DIR/history.md"
CONFLICT_HISTORY_SHA=$(file_sha "$PLAN_DIR/history.md")
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$CONFLICT_TARGET_SHA" --dry-run \
    phase-update 12 --title Current >/dev/null; then
    fail "recovery rejects concurrently changed history"
fi
assert_eq "$(file_sha "$PLAN_DIR/tasks.md")" "$CONFLICT_TASKS_SHA" "history conflict leaves hot state unapplied"
assert_eq "$(file_sha "$PLAN_DIR/history.md")" "$CONFLICT_HISTORY_SHA" "history conflict preserves unrelated state"
[ -f "$CONFLICT_JOURNAL" ] || fail "history conflict retains journal for explicit diagnosis"
rm -f "$CONFLICT_JOURNAL"

write_rollover_plan
sed -i 's/\[complete\]/[pending]/g' "$PLAN_DIR/tasks.md"
ROLLOVER_SHA=$(file_sha "$PLAN_DIR/tasks.md")
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$ROLLOVER_SHA" \
    phase-add --title "No eligible archive" --after 12 --expected-history-fingerprint missing >/dev/null; then
    fail "phase rollover rejects twelve unfinished hot phases"
fi
assert_eq "$(file_sha "$PLAN_DIR/tasks.md")" "$ROLLOVER_SHA" "failed rollover leaves tasks unchanged"
if python3 "$EDIT_TOOL" --plan "$PLAN_DIR/tasks.md" --expected-fingerprint "$ROLLOVER_SHA" \
    compact-oldest --expected-history-fingerprint missing >/dev/null; then
    fail "explicit compaction rejects a plan with no complete phase"
fi
assert_eq "$(file_sha "$PLAN_DIR/tasks.md")" "$ROLLOVER_SHA" "failed compaction leaves tasks unchanged"
assert_eq "$(planning_file_budget_warning "$PLAN_DIR")" "" "twelve unfinished phases remain within the hot limit"

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

# The raised tasks.md limit admits useful plans beyond the old 150-line cap.
write_valid_plan
for N in $(seq 1 120); do printf '%s\n' "- compact planning note $N" >> "$PLAN_DIR/tasks.md"; done
assert_eq "$(planning_file_budget_warning "$PLAN_DIR")" "" "tasks plan between 150 and 300 lines remains within budget"

# Item limits are maintenance warnings even when the file byte/line budgets fit.
write_valid_plan
for N in $(seq 1 101); do
    printf '%s\n' "- [ ] bulk item $N"
done > "$TEST_DIR/bulk-items.md"
sed "/^- \[ \] Make the change$/r $TEST_DIR/bulk-items.md" "$PLAN_DIR/tasks.md" > "$PLAN_DIR/tasks-with-bulk.md"
mv "$PLAN_DIR/tasks-with-bulk.md" "$PLAN_DIR/tasks.md"
WARNING=$(planning_file_budget_warning "$PLAN_DIR")
assert_contains "$WARNING" "103/100 item entries" "total item budget"
assert_contains "$WARNING" "102/15 current-phase items" "current-phase item budget"

write_valid_plan
printf '# Handoff\n' > "$PLAN_DIR/handoff.md"
touch -t 202601010000 "$PLAN_DIR/handoff.md"
touch -t 202601010001 "$PLAN_DIR/tasks.md"
assert_contains "$(planning_handoff_warning "$PLAN_DIR")" "STALE HANDOFF" "stale handoff"
touch -t 203001010000 "$PLAN_DIR/handoff.md"
assert_eq "$(planning_handoff_warning "$PLAN_DIR")" "" "fresh handoff"

# Volatile external evidence and handoff snapshots carry explicit freshness;
# restore-check requires re-verification once their window closes.
write_valid_plan
write_contracted_plan
sed -i 's#^- `make test`: pending#- [external-state observed=2020-01-01T00:00:00Z reverify-after=2020-01-01T00:05:00Z] staging smoke: PASS#' "$PLAN_DIR/tasks.md"
if STALE_EXTERNAL=$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" restore-check "$PLAN_DIR/tasks.md"); then
    fail "restore check rejects stale external evidence"
fi
assert_contains "$STALE_EXTERNAL" "EXTERNAL_EVIDENCE_STALE" "stale external evidence requests re-verification"
sed -i 's#observed=2020-01-01T00:00:00Z reverify-after=2020-01-01T00:05:00Z#observed=2030-01-01T00:00:00Z reverify-after=2030-01-01T00:05:00Z#' "$PLAN_DIR/tasks.md"
rm -f "$PLAN_DIR/handoff.md"
assert_contains "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" restore-check "$PLAN_DIR/tasks.md")" '"ok":true' "future external freshness window remains usable"
printf '# Handoff\n\nUpdated: 2020-01-01T00:00:00Z\nReverify after: 2020-01-01T00:05:00Z\n\n## Resume Checkpoint\n- current\n\n## Working State\n- state\n\n## Verification\n- pending\n\n## Safety\n- preserve\n' > "$PLAN_DIR/handoff.md"
touch -t 203001010000 "$PLAN_DIR/handoff.md"
if STALE_HANDOFF=$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" restore-check "$PLAN_DIR/tasks.md"); then
    fail "restore check rejects expired handoff"
fi
assert_contains "$STALE_HANDOFF" "HANDOFF_EXPIRED" "expired handoff requests re-verification"

cmp "$REPO_ROOT/.codex/hooks/plan-files/scripts/common.sh" "$REPO_ROOT/.claude/hooks/plan-files/scripts/common.sh"
cmp "$REPO_ROOT/.codex/hooks/plan-files/scripts/common.sh" "$REPO_ROOT/.github/hooks/scripts/common.sh"
bash -n "$REPO_ROOT"/.codex/hooks/plan-files/scripts/*.sh \
    "$REPO_ROOT"/.claude/hooks/plan-files/scripts/*.sh \
    "$REPO_ROOT"/.github/hooks/scripts/*.sh

# Compaction gate: observations stay possible, mutations stay in planning scope.
printf '%s' '{"tool_name":"rg","tool_input":{"command":"rg Phase ."}}' | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows read search"
printf '%s' '{"tool_name":"mcp__serena__search_for_pattern","tool_input":{"substring_pattern":"Phase","relative_path":"src"}}' | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows Serena read search"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status --short"}}' | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows read-only git status"
if printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git checkout -- src/main.py"}}' | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR"; then
    fail "compaction blocks mutating git command"
fi
if printf '%s' '{"tool_name":"apply_patch","tool_input":{"patch":"*** Update File: src/main.py"}}' | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR"; then
    fail "compaction blocks source mutation"
fi
printf '%s' "{\"tool_name\":\"apply_patch\",\"tool_input\":{\"patch\":\"*** Update File: $PLAN_DIR/tasks.md\"}}" | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows plan mutation"
printf '%s' "{\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: $PLAN_DIR/history.md\\n*** End Patch\"}}" | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows bridge apply_patch command payload"
printf '%s' "{\"tool_name\":\"codex_apply_patch\",\"tool_input\":{\"opaque\":\"write $PLAN_DIR/history.md\"}}" | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows unknown mutation tool with exact owned plan reference"
if printf '%s' '{"tool_name":"codex_apply_patch","tool_input":{"opaque":"write history.md"}}' | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR"; then
    fail "compaction does not trust plan basenames without owned plan path"
fi
if printf '%s' "{\"tool_name\":\"apply_patch\",\"tool_input\":{\"patch\":\"*** Update File: $PLAN_DIR/tasks.md\\n*** Update File: src/main.py\"}}" | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR"; then
    fail "compaction requires every patch target inside plan"
fi
printf '%s' "{\"tool_name\":\"mcp__serena__replace_content\",\"tool_input\":{\"relative_path\":\"$PLAN_DIR/findings.md\",\"needle\":\"old\",\"repl\":\"new\"}}" | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR" || fail "compaction allows Serena plan mutation"
if printf '%s' '{"tool_name":"mcp__serena__replace_content","tool_input":{"relative_path":"src/main.py","needle":"old","repl":"new"}}' | python3 "$REPO_ROOT/skills/plan-files/scripts/maintenance-tool-allowed.py" "$PLAN_DIR"; then
    fail "compaction blocks Serena source mutation"
fi

# The actual blocked PreToolUse response tells the model what remains allowed.
write_valid_plan
head -c 33000 /dev/zero | tr '\0' x > "$PLAN_DIR/findings.md"
PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" pending codex codex-compaction >/dev/null
PWF_PROJECT_ROOT="$PROJECT" PWF_SESSION_ADAPTER=codex PWF_SESSION_ID=codex-compaction "$STATE_TOOL" bind test-task >/dev/null
COMPACTION_BLOCK=$(cd "$PROJECT" && printf '%s\n' '{"session_id":"codex-compaction","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}' | "$REPO_ROOT/.codex/hooks/plan-files/scripts/pre-tool-use.sh")
assert_contains "$COMPACTION_BLOCK" "demonstrably read-only" "compaction block explains project reads"
assert_contains "$COMPACTION_BLOCK" "does not require a specific mutation tool name" "compaction block explains schema-independent plan mutations"
assert_contains "$COMPACTION_BLOCK" "$PLAN_DIR" "compaction block names owned plan directory"
COMPACTION_LOG=$(cat "$PROJECT/tmp/hook-logs/plan-files/pre-tool-use.log")
assert_contains "$COMPACTION_LOG" "tool_call tool_name=Bash" "pre-tool log records full tool name"
assert_contains "$COMPACTION_LOG" 'tool_input={"command":"npm test"}' "pre-tool log records full tool parameters"
assert_contains "$COMPACTION_LOG" "decision=block-compaction tool=Bash" "pre-tool log correlates blocked decision"
CHECKPOINT_PAYLOAD=$(printf '{"session_id":"codex-compaction","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"python3 %s --plan %s progress P1.1 --evidence checkpoint"}}\n' "$CHECKPOINT_TOOL" "$PLAN_DIR/tasks.md")
assert_eq "$(cd "$PROJECT" && printf '%s\n' "$CHECKPOINT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/plan-files/scripts/pre-tool-use.sh")" "{}" "pre-tool gate permits owned structured checkpoint"

CODEX_PAYLOAD='{"session_id":"codex-contract","hook_event_name":"Stop","stop_hook_active":false}'
CLAUDE_PAYLOAD='{"session_id":"claude-contract","hook_event_name":"Stop","stop_hook_active":false}'
COPILOT_PAYLOAD='{"session_id":"copilot-contract","hook_event_name":"Stop","stop_hook_active":false}'
CODEX_REPEAT_PAYLOAD='{"session_id":"codex-contract","hook_event_name":"Stop","stop_hook_active":true}'
CLAUDE_REPEAT_PAYLOAD='{"session_id":"claude-contract","hook_event_name":"Stop","stop_hook_active":true}'
COPILOT_REPEAT_PAYLOAD='{"session_id":"copilot-contract","hook_event_name":"Stop","stop_hook_active":true}'

CODEX_CANDIDATE=$(cd "$PROJECT" && printf '%s\n' '{"session_id":"codex-contract","hook_event_name":"UserPromptSubmit","prompt":"continue contract-fixture"}' | "$REPO_ROOT/.codex/hooks/plan-files/scripts/user-prompt-submit.sh")
CLAUDE_CANDIDATE=$(cd "$PROJECT" && printf '%s\n' '{"session_id":"claude-contract","hook_event_name":"UserPromptSubmit","prompt":"continue contract-fixture"}' | "$REPO_ROOT/.claude/hooks/plan-files/scripts/user-prompt-submit.sh")
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
write_valid_plan
write_contracted_plan
sed -i 's#^- `make test`: pending#- [external-state observed=2020-01-01T00:00:00Z reverify-after=2020-01-01T00:05:00Z] staging smoke: PASS#' "$PLAN_DIR/tasks.md"
for SPEC in 'codex codex-contract' 'claude claude-contract' 'copilot copilot-contract'; do
    set -- $SPEC
    RESTORE_BLOCK=$(pre_hook "$1" "$2" "npm test")
    assert_contains "$RESTORE_BLOCK" "RESTORE STATE ACTION REQUIRED" "$1 PreTool blocks operational work with stale restore evidence"
    assert_contains "$RESTORE_BLOCK" "EXTERNAL_EVIDENCE_STALE" "$1 PreTool names stale evidence code"
    assert_contains "$RESTORE_BLOCK" "re-run the external check" "$1 PreTool gives targeted restore repair"
    assert_eq "$(pre_hook "$1" "$2" "rg Phase .")" "{}" "$1 PreTool allows bounded restore diagnosis"
    RESTORE_SESSION="$2-restore"
    PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" pending "$1" "$RESTORE_SESSION" >/dev/null
    PWF_PROJECT_ROOT="$PROJECT" PWF_SESSION_ADAPTER="$1" PWF_SESSION_ID="$RESTORE_SESSION" "$STATE_TOOL" bind test-task >/dev/null
    assert_contains "$(post_hook "$1" "$RESTORE_SESSION" Read)" "RESTORE STATE ACTION REQUIRED" "$1 PostTool injects bounded restore repair"
done
assert_contains "$(python3 "$REPO_ROOT/skills/plan-files/scripts/plan_state.py" overview "$PLAN_DIR/tasks.md")" \
    '"code":"EXTERNAL_EVIDENCE_STALE"' "bounded overview carries targeted restore issue"
write_valid_plan
write_contracted_plan
for SPEC in 'codex codex-contract' 'claude claude-contract' 'copilot copilot-contract'; do
    set -- $SPEC
    assert_contains "$(post_hook "$1" "$2" Read)" "Active Item P1.1" "$1 PostTool initial item context"
    assert_eq "$(post_hook "$1" "$2" Read)" "{}" "$1 PostTool suppresses read-only reminder noise"
    assert_contains "$(post_hook "$1" "$2" Bash "pytest -q")" "structured checkpoint before any unrelated tool" "$1 PostTool checkpoint barrier after likely evidence"
    POST_STATE=$(PWF_PROJECT_ROOT="$PROJECT" "$STATE_TOOL" cache "$1" "$2")
    sed -i 's/^unchanged_risk_score=.*/unchanged_risk_score=2/; s/^last_item_nudge_ts=.*/last_item_nudge_ts=0/; s/^last_stale_ts=.*/last_stale_ts=0/; s/^item_nudge_streak=.*/item_nudge_streak=0/' "$POST_STATE"
    STALE_FIRST=$(post_hook "$1" "$2" Bash "pytest -q")
    assert_contains "$STALE_FIRST" "STALE ITEM STATE: no plan change for" "$1 PostTool risk-aware stale item detection"
    assert_contains "$STALE_FIRST" "plan_checkpoint.py progress P1.1" "$1 PostTool stale line offers a partial-evidence path"
    # The line must not restate itself on every later call: repeating a growing
    # counter is what drowned real signal during long browser/E2E journeys.
    sed -i 's/^last_item_nudge_ts=.*/last_item_nudge_ts=0/' "$POST_STATE"
    assert_not_contains "$(post_hook "$1" "$2" Bash "pytest -q")" "STALE ITEM STATE" "$1 PostTool stale line stays re-armed, not repeated"
    # Read-only exploration must not accrue semantic risk at all.
    assert_eq "$(post_hook "$1" "$2" Bash "cd /tmp && grep -n foo bar.py")" "{}" "$1 PostTool ignores prefixed read-only shell exploration"
done
grep -q '^- \[ \] \[P1.1\]' "$PLAN_DIR/tasks.md" || fail "PostTool never auto-completes an item"
POST_LOG=$(cat "$PROJECT/tmp/hook-logs/plan-files/post-tool-use.log")
assert_contains "$POST_LOG" "item_state fingerprint=" "PostTool log exposes fingerprint"
assert_contains "$POST_LOG" "active_item=P1.1" "PostTool log exposes Active Item"
assert_contains "$POST_LOG" "checkpoint_lag=" "PostTool log exposes checkpoint lag"
assert_contains "$POST_LOG" "stale=true" "PostTool log exposes stale state"
assert_contains "$POST_LOG" "scope provider=codex task=test-task session=" "PostTool telemetry has scoped privacy-safe identity"
assert_contains "$POST_LOG" "injection emitted=" "PostTool telemetry records injection decisions"
assert_contains "$POST_LOG" "bytes=" "PostTool telemetry records exact injection bytes"
assert_not_contains "$POST_LOG" "codex-contract" "PostTool telemetry does not log raw session identity"

CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_PAYLOAD" | "$REPO_ROOT/.codex/hooks/plan-files/scripts/agent-stop.sh")
CLAUDE_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CLAUDE_PAYLOAD" | "$REPO_ROOT/.claude/hooks/plan-files/scripts/agent-stop.sh")
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
CODEX_REPEAT_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_REPEAT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/plan-files/scripts/agent-stop.sh")
CLAUDE_REPEAT_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CLAUDE_REPEAT_PAYLOAD" | "$REPO_ROOT/.claude/hooks/plan-files/scripts/agent-stop.sh")
COPILOT_REPEAT_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$COPILOT_REPEAT_PAYLOAD" | "$REPO_ROOT/.github/hooks/scripts/agent-stop.sh")
for OUTPUT in "$CODEX_REPEAT_OUTPUT" "$CLAUDE_REPEAT_OUTPUT" "$COPILOT_REPEAT_OUTPUT"; do
    assert_contains "$OUTPUT" "Task incomplete" "active Stop remains blocked"
    assert_contains "$OUTPUT" "No structured plan progress" "repeated Stop reports no progress"
    assert_contains "$OUTPUT" "Do not answer this hook with another summary" "repeated Stop demands operational recovery"
done
STOP_LOG=$(cat "$PROJECT/tmp/hook-logs/plan-files/agent-stop.log")
assert_contains "$STOP_LOG" "progress fingerprint=" "Stop log exposes fingerprint"
assert_contains "$STOP_LOG" "no_progress_count=1" "Stop log exposes repeated no-progress count"
assert_contains "$STOP_LOG" "active_item=P1.1" "Stop log exposes Active Item"
assert_contains "$STOP_LOG" "scope provider=codex task=test-task session=" "Stop telemetry has scoped privacy-safe identity"
assert_contains "$STOP_LOG" "stop continuation=true" "Stop telemetry records continuation"
assert_not_contains "$STOP_LOG" "codex-contract" "Stop telemetry does not log raw session identity"
assert_not_contains "$CODEX_REPEAT_OUTPUT" "Monitor" "background/async nudge does not fire on only the first no-progress repeat"

# A second consecutive no-progress Stop (still no plan change) nudges toward
# a streaming/monitor tool instead of manually ending the turn to re-poll a
# background process -- this is the pattern that caused a real repeated-Stop
# loop while an agent tailed a still-running e2e test log.
CODEX_REPEAT2_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_REPEAT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/plan-files/scripts/agent-stop.sh")
assert_contains "$CODEX_REPEAT2_OUTPUT" "background/async process" "second consecutive no-progress Stop names the likely cause"
assert_contains "$CODEX_REPEAT2_OUTPUT" "Monitor" "second consecutive no-progress Stop points at a streaming/monitor tool"
assert_contains "$CODEX_REPEAT2_OUTPUT" "blocked (reason)" "second consecutive no-progress Stop also offers blocked as a fallback"

python3 "$CHECKPOINT_TOOL" --plan "$PLAN_DIR/tasks.md" progress P1.1 --evidence "implementation now exists" >/dev/null
CODEX_PROGRESS_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_REPEAT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/plan-files/scripts/agent-stop.sh")
assert_contains "$CODEX_PROGRESS_OUTPUT" "Structured plan progress occurred" "item progress resets Stop recovery state"

write_valid_plan
sed -i 's/in_progress/blocked (external dependency unavailable)/; s/pending/deferred (user postponed validation)/' "$PLAN_DIR/tasks.md"
CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_REPEAT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/plan-files/scripts/agent-stop.sh")
CLAUDE_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CLAUDE_REPEAT_PAYLOAD" | "$REPO_ROOT/.claude/hooks/plan-files/scripts/agent-stop.sh")
GITHUB_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$COPILOT_REPEAT_PAYLOAD" | "$REPO_ROOT/.github/hooks/scripts/agent-stop.sh")
assert_eq "$CODEX_OUTPUT" "{}" "Codex repeated Stop allows blocked/deferred phases"
assert_eq "$CLAUDE_OUTPUT" "{}" "Claude repeated Stop allows blocked/deferred phases"
assert_eq "$GITHUB_OUTPUT" "{}" "Copilot repeated Stop allows blocked/deferred phases"

write_valid_plan
sed -i 's/in_progress/blocked (external dependency unavailable)/' "$PLAN_DIR/tasks.md"
CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_REPEAT_PAYLOAD" | "$REPO_ROOT/.codex/hooks/plan-files/scripts/agent-stop.sh")
assert_contains "$CODEX_OUTPUT" "STALE" "blocked current phase advances to later actionable phase"

write_valid_plan

sed -i '/\*\*Status:\*\* pending/d' "$PLAN_DIR/tasks.md"
CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_PAYLOAD" | "$REPO_ROOT/.codex/hooks/plan-files/scripts/agent-stop.sh")
CLAUDE_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CLAUDE_PAYLOAD" | "$REPO_ROOT/.claude/hooks/plan-files/scripts/agent-stop.sh")
GITHUB_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$COPILOT_PAYLOAD" | "$REPO_ROOT/.github/hooks/scripts/agent-stop.sh")
for OUTPUT in "$CODEX_OUTPUT" "$CLAUDE_OUTPUT" "$GITHUB_OUTPUT"; do
    assert_contains "$OUTPUT" "exactly one recognized" "phase-status adapter routing"
done

write_valid_plan
sed -i 's/^Phase 1$//; s/in_progress/pending/' "$PLAN_DIR/tasks.md"
CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_PAYLOAD" | "$REPO_ROOT/.codex/hooks/plan-files/scripts/agent-stop.sh")
assert_eq "$CODEX_OUTPUT" "{}" "Codex discussion mode"

write_valid_plan
sed -i 's/^- \[ \] Make the change/- [x] Make the change/; s/in_progress/complete/' "$PLAN_DIR/tasks.md"
CODEX_OUTPUT=$(cd "$PROJECT" && printf '%s\n' "$CODEX_PAYLOAD" | "$REPO_ROOT/.codex/hooks/plan-files/scripts/agent-stop.sh")
assert_contains "$CODEX_OUTPUT" "STALE" "Codex stale Current Phase"

printf 'planning contract tests: PASS\n'
