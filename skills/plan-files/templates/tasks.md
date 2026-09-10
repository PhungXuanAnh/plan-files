# Tasks: [Brief Description]
<!-- Private runtime file. Session hooks add local Git excludes when the project root has a .git directory. -->
<!-- Trusted hot state. Keep at most 300 lines, 24 KiB, 12 hot phase headings, ~100 visible items, and 15 items/4 KiB in Current Phase. -->

## Goal
<!-- One or two short sentences. Hooks may inject this, so keep it concise. -->
[One sentence describing the end state]

## Task Identity
<!-- Keep this deterministic and concise; session-owned hooks expose it before binding. -->
<!-- Update scope after explicit user authorization within this same plan; other Non-goals remain in force. -->
- Deliverable: [specific result this task owns]
- Anchors: [ticket, PR, task id, or other stable identifiers; `none` if absent]
- Non-goals: [nearby work that must not be mistaken for this task]

## Current Phase
<!-- Keep empty only before any phase starts. Otherwise use exactly an existing "Phase N", even after settlement. PreTool gates invalid format; PostTool repeats repairs until fixed. -->

## Active Item
<!-- Keep empty while planning/discussing or after settlement. During work use exactly one unchecked ID from Current Phase, for example P2.1 or V2.1. -->

## Workflow Profile
<!-- Fill exactly one before operational work: A, B, or C. Unfilled profiles trigger PreTool repair gating. -->
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

<!-- Begin with one useful phase. Replace these outcomes with task-specific ones; add phases only for real work boundaries. Do not create separate items merely to narrate planning activity. -->
### Phase 1: Deliver the requested result
- [ ] [P1.1] [Specific observable result requested by the user]
  - Evidence: pending

**Done when:**
- [ ] [V1.1] [Exact acceptance check demonstrates the requested result]
  - Evidence: pending
- **Status:** pending

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
