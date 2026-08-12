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

## Workflow Profile
**Profile:** A

## Resume Checkpoint
- **Next action:** Patch the missing `await` in `src/auth/login.ts`.
- **Blocker:** none
- **Details:** none

## Phases

### Phase 1: Reproduce and Locate [complete]

### Phase 2: Implement Fix
- [ ] Await the user lookup
- [ ] Run `pytest tests/auth/test_login.py`
- **Status:** in_progress

**Done when:** `pytest tests/auth/test_login.py` passes.

### Phase 3: Verify Regression
- [ ] Run `pytest tests/auth`
- **Status:** pending

**Done when:** `pytest tests/auth` passes.
```

Only current/incomplete work stays detailed. The old phase is one line because its evidence has moved to history.

On a new prompt, ownership hooks expose only the Task Identity and Goal above. A request to continue `AUTH-421` is `SAME`, so the agent runs the supplied bind command; a report-performance request is `DIFFERENT` even if it touches the same auth module; only unclear wording requires a question.

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

## Optional handoff

Create this only when a short Resume Checkpoint cannot capture volatile state:

```markdown
# Handoff

Updated: 2026-08-09 18:30 Asia/Ho_Chi_Minh

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
- **State captured at:** 2026-08-09 18:30; reverify before acting
```

Overwrite the file at the next pause. Ignore it when a required planning file is newer.

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
