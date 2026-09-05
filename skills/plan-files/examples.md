# Compact Examples

## Active task

```markdown
# Tasks: Fix Login Bug

## Goal
Fix the failed login flow without changing unrelated authentication behavior.

## Task Identity
- Deliverable: Restore successful login after a valid credential check
- Anchors: AUTH-421
- Non-goals: session storage refactors, signup validation

## Current Phase
Phase 2

## Active Item
P2.1

## Workflow Profile
**Profile:** A

## Resume Checkpoint
- **Next action:** Complete P2.1: patch the missing `await` in `src/auth/login.ts`.
- **Blocker:** none
- **Details:** none

## Phases

### Phase 1: Reproduce and Locate [complete]

### Phase 2: Implement Fix
- [ ] [P2.1] The user lookup is awaited before the login decision.
  - Evidence: pending
- [ ] [P2.2] The focused login regression passes.
  - Evidence: pending

**Done when:**
- [ ] [V2.1] `pytest tests/auth/test_login.py` passes.
  - Evidence: pending
- **Status:** in_progress

### Phase 3: Verify Regression
- [ ] [P3.1] The authentication regression suite passes.
  - Evidence: pending
- **Status:** pending

**Done when:**
- [ ] [V3.1] `pytest tests/auth` passes.
  - Evidence: pending
```

Only current/incomplete work stays detailed. The old phase is one line because its evidence has moved to history.

On a new prompt, ownership hooks expose only the Task Identity and Goal above. A request to continue `AUTH-421` is `SAME`, so the agent runs the supplied bind command; a report-performance request is `DIFFERENT` even if it touches the same auth module; only unclear wording requires a question.

If that task began as research with “production implementation” under Non-goals, “Here are the lead's answers; implement this plan” is also SAME. Bind, record the authorization and answers, revise the outdated scope/profile and pending phases, then implement. Keep unrelated restrictions. By contrast, “Use AUTH-421 as an example while reviewing the planning hooks” names the task as background and does not ask to continue its implementation.

For “continue that work” with unclear task identity, run the hook's `clarify` command, ask which task, and wait. The next prompt retains the candidate; no `release` is needed just to ask. For “explain why the hook blocked this plan; do not implement yet”, bind the named plan, then run the same command with `discuss` instead of `bind`. Read-only diagnosis and questions remain available even with an oversized handoff; outside writes stay gated and the answer does not complete any phase.

## Archive during compaction

Before:

```markdown
## Verification
- Phase 1 reproduction output ...
- Phase 1 focused test output ...
- Phase 1 rerun output ...
- Phase 2 required check: `pytest tests/auth/test_login.py`
```

After `tasks.md`:

```markdown
## Verification
- `pytest tests/auth/test_login.py`: required for current phase.
- History: `history.md#completed-phases`
```

After `history.md`:

```markdown
## Completed Phases
- Phase 1 — reproduced missing `await`; evidence: `tests/auth/reproduction.md`.

## Verification History
- Phase 1 — `pytest tests/auth/test_reproduction.py` passed.
```

Recurring failures belong in `findings.md` as symptom/root cause/workaround; resolved audit detail belongs in `history.md`.

For a larger plan, resume without loading every file:

```bash
python3 <skill-dir>/scripts/plan_state.py overview <task-dir>/tasks.md
python3 <skill-dir>/scripts/plan_state.py restore-check <task-dir>/tasks.md
python3 <skill-dir>/scripts/plan_state.py phase <task-dir>/tasks.md 2
python3 <skill-dir>/scripts/plan_state.py section <task-dir>/findings.md "Current Summary"
```

Use the returned file fingerprint for a routine edit:

```bash
python3 <skill-dir>/scripts/plan_edit.py --plan <task-dir>/tasks.md \
  --expected-fingerprint <sha256> entry-append --file tasks.md \
  --heading "Files Touched" --entry '- src/auth/login.ts: await fix'
```

Read `references/plan-operations.md` for structural, archival, decision, and handoff commands. Directly read or patch the Markdown when the intended repair is too unusual for those safe primitives.

When the hot window already has 12 phase headings, add the next phase with both current fingerprints. The editor archives and evicts the oldest eligible complete phase before writing the new monotonic ID:

```bash
python3 <skill-dir>/scripts/plan_edit.py --plan <task-dir>/tasks.md \
  --expected-fingerprint <tasks-sha> phase-add --title "Follow-up verification" \
  --expected-history-fingerprint <history-sha-or-missing>
```

For explicit phase compaction, run `compact-oldest` with the same two fingerprints and repeat only while the budget warning remains. Rollover and archive operations create a bounded transaction journal, commit history before hot state under a lock, and automatically recover that journal on the next `plan_edit.py` call.

## Optional handoff

Create this only when a short Resume Checkpoint cannot capture volatile state:

```markdown
# Handoff

Updated: 2026-08-09T18:30:00+07:00
Reverify after: 2026-08-09T19:00:00+07:00

## Resume Checkpoint
- **Current phase:** Phase 2
- **Why paused:** waiting for the test database
- **Exact next action:** run `pytest tests/auth/test_login.py`
- **Expected result:** login regression passes
- **Blocker or user input:** test database availability

## Working State
- **Branch / revision:** `fix-login` / `abc1234`
- **Modified or untracked files:** `src/auth/login.ts`
- **Running processes or volatile state:** none
- **State captured at:** 2026-08-09T18:30:00+07:00; reverify before acting
```

Overwrite the file at the next pause. Ignore and re-verify it after `Reverify after` or when a required planning file is newer. For a volatile result kept in `tasks.md`, use `- [external-state observed=2026-08-09T18:30:00+07:00 reverify-after=2026-08-09T19:00:00+07:00] staging smoke: PASS`.

## Changed user decision

```markdown
## Active Decisions
| ID | Decision | Rationale | Date |
|----|----------|-----------|------|
| D2 | Use JSON storage | User prioritized portability | 2026-08-09 |

## Superseded Decisions
| ID | Old Decision | Replaced By | Reason |
|----|--------------|-------------|--------|
| D1 | Use SQLite | D2 | User changed the portability requirement |
```

Read the ledger before editing it; never silently delete the earlier choice.

## Repair before execution

If a plan has `Phase 99` as Current Phase without such a phase, a missing status, and `**Profile:** [A | B | C]`, the next PreTool blocks operational work. Read the owned plan and fix all three fields; reads and owned-plan edits still pass. PostTool repeats the unresolved diagnosis even when the plan has not changed. Once repaired, that diagnosis disappears; a compact Stop warning remains while work is actionable.

Every hook message names the absolute path of what it asks for, so copy the command as printed: `Run: python3 /abs/skill-dir/scripts/plan_state.py restore-check /abs/project/tmp/plan-files/<task>/tasks.md`. Do not re-derive the location; a background `find` across the home directory is never the recovery. If the host already returns a task id, wait/get that result before dependent work instead of launching the same command again.

## Answering a question without owning the plan

The user asks why the last run behaved a certain way, and the prompt hook reports a pending candidate. This is neither SAME, DIFFERENT, nor AMBIGUOUS: nothing is being implemented and nothing needs clarifying. Run the `discuss` command the message offers, answer, and stop. Execution stays gated and the candidate pointer survives for the next prompt.

## First operational call in a session

Read the absolute `SKILL.md` path the ownership message names before anything else, including before bind: that read is allowed in every routing state and counts once the plan is bound. Read it even when the rules already appear in context — the gate observes tool calls, not context. Skip it and the first operational call answers `SKILL NOT LOADED` with the same path; diagnosis reads and owned-plan repair still work while it blocks, so there is never a reason to release the plan or report an environment blocker.
