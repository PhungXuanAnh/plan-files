# Tasks: [Brief Description]
<!-- Trusted hot state. Keep at most 300 lines, 24 KiB, 12 hot phase headings, ~100 visible items, and 15 items/4 KiB in Current Phase. -->

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

## Active Item
<!-- Keep empty while planning/discussing or after settlement. During work use exactly one unchecked ID from Current Phase, for example P2.1 or V2.1. -->

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
- [ ] [PN.N] Observable outcome
  - Evidence: pending
- **Status:** pending | in_progress | complete | blocked (external reason) | deferred (user-directed reason)

Use `blocked (reason)` only for a genuine external dependency and `deferred (reason)` only when the user explicitly postpones the phase.
Use P IDs for work and V IDs for phase acceptance. IDs are unique and match the containing phase number.
Use targeted plan operations for routine reads/edits. Phase add/compaction archives and evicts the oldest eligible complete phase when the 12-heading hot window needs room; never remove unfinished work to make space.
-->

### Phase 1: Requirements & Discovery
- [ ] [P1.1] User intent, constraints, non-goals, and verification needs are recorded.
  - Evidence: pending
- [ ] [P1.2] Relevant discoveries and confirmed user choices are recorded in their durable files.
  - Evidence: pending
- **Status:** pending

**Done when:**
- [ ] [V1.1] `findings.md` answers the key questions, `decisions.md` reflects current choices, and Workflow Profile is selected.
  - Evidence: pending

### Phase 2: Planning
- [ ] [P2.1] The implementation approach and non-obvious decisions are recorded.
  - Evidence: pending
- [ ] [P2.2] Exact verification commands or observable checks are named.
  - Evidence: pending
- **Status:** pending

**Done when:**
- [ ] [V2.1] No unresolved question blocks implementation and every required check is listed below.
  - Evidence: pending

### Phase 3: Implementation
- [ ] [P3.1] The planned scoped changes are present without modifying unrelated worktree state.
  - Evidence: pending
- [ ] [P3.2] Current progress, errors, and touched files accurately reflect the implementation.
  - Evidence: pending
- **Status:** pending

**Done when:**
- [ ] [V3.1] Relevant implementation checks pass or a genuine external blocker is recorded.
  - Evidence: pending

### Phase 4: Verification & Delivery
- [ ] [P4.1] Every exact check listed in `## Verification` has a current result and failures have been resolved or externally blocked.
  - Evidence: pending
- [ ] [P4.2] The final user-facing outcome is ready and contains no plan-only narration.
  - Evidence: pending
- **Status:** pending

**Done when:**
- [ ] [V4.1] The plan is finalizable: every phase is settled, evidence is current, and the pointer can be deactivated.
  - Evidence: pending

## Key Questions
1. [Question to answer]
2. [Question to answer]

## Verification
<!-- Keep exact checks still required plus the latest relevant baseline. Move completed detail to history.md. -->
<!-- For volatile external results use: [external-state observed=<ISO-8601> reverify-after=<ISO-8601>]. -->
- `<exact command or check>`:

## Progress Notes
<!-- Keep only current/recent work. -->
- [YYYY-MM-DD] Created plan.

## Errors Encountered
<!-- Log immediately, but only failures that changed your approach; a retry that then succeeded is not an error. Keep unresolved/current errors; move recurring gotchas to findings.md and resolved audit history to history.md. -->
| Error | Attempt | Resolution |
|-------|---------|------------|

## Files Touched
<!-- Keep current and relevant. -->
- [path]: [why]

## History
- Cold archive: none <!-- Link history.md when created. -->
