# Tasks: [Brief Description]
<!-- Trusted hot state. Keep under 150 lines AND 12 KiB; move cold history out instead of truncating. -->

## Goal
<!-- One or two short sentences. Hooks may inject this, so keep it concise. -->
[One sentence describing the end state]

## Task Identity
<!-- Keep this deterministic and concise; session-owned hooks expose it before binding. -->
- Deliverable: [specific result this task owns]
- Anchors: [ticket, PR, task id, or other stable identifiers; `none` if absent]
- Non-goals: [nearby work that must not be mistaken for this task]

## Current Phase
<!-- Keep empty while planning/discussing. Otherwise the entire body must be exactly "Phase N". -->

## Workflow Profile
<!-- Pick exactly one before implementation: A, B, or C. -->
**Profile:** [A | B | C]

- **A - PR-Handoff:** stop after PR opened, CI green, reviewers requested.
- **B - Staging-Verified:** stop after staging deploy and staging E2E pass.
- **C - Research/Document:** stop after deliverable file/report is complete.

## Resume Checkpoint
- **Next action:** [exact next command or edit]
- **Blocker:** none
- **Details:** none <!-- Link handoff.md only when a short checkpoint is insufficient. -->

## Phases
<!--
Required phase format:
### Phase N: Title
- [ ] Task item
- **Status:** pending | in_progress | complete | deferred (reason)

Use `deferred (reason)` only for explicit blockers or user-requested follow-up.
-->

### Phase 1: Requirements & Discovery
- [ ] Understand user intent
- [ ] Identify constraints, non-goals, and verification needs
- [ ] Record discoveries in `findings.md`
- [ ] Record confirmed user choices in `decisions.md`
- **Status:** in_progress

**Done when:**
- [ ] `findings.md` answers the key questions below
- [ ] `decisions.md` contains current user decisions that affect implementation
- [ ] Workflow Profile is A, B, or C

### Phase 2: Planning
- [ ] Define approach
- [ ] Update `decisions.md` for non-obvious or user-confirmed choices
- [ ] Name exact verification commands or checks
- **Status:** pending

**Done when:**
- [ ] Every non-obvious choice is captured in `decisions.md`
- [ ] No open question blocks implementation
- [ ] Verification commands/checks are listed below

### Phase 3: Implementation
- [ ] Make the planned changes
- [ ] Keep concise progress notes in `## Progress Notes`
- [ ] Log errors in `## Errors Encountered`
- **Status:** pending

**Done when:**
- [ ] Intended files are changed
- [ ] No unrelated worktree changes are modified
- [ ] Relevant verification has run or the reason it could not run is recorded

### Phase 4: Verification & Delivery
- [ ] Run the exact checks listed in `## Verification`
- [ ] Fix failures and re-run failing checks
- [ ] Summarize outcome for the user
- **Status:** pending

**Done when:**
- [ ] All required checks pass, or blockers are explicit
- [ ] Remaining work, if any, is listed
- [ ] Final user-facing summary is ready

## Key Questions
1. [Question to answer]
2. [Question to answer]

## Verification
<!-- Keep exact checks still required plus the latest relevant baseline. Move completed detail to history.md. -->
- `<exact command or check>`:

## Progress Notes
<!-- Keep only current/recent work. -->
- [YYYY-MM-DD] Created plan.

## Errors Encountered
<!-- Log immediately. Keep unresolved/current errors; move recurring gotchas to findings.md and resolved audit history to history.md. -->
| Error | Attempt | Resolution |
|-------|---------|------------|

## Files Touched
<!-- Keep current and relevant. -->
- [path]: [why]

## History
- Cold archive: none <!-- Link history.md when created. -->
