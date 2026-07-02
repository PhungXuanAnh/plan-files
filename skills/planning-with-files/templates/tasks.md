# Tasks: [Brief Description]
<!-- Keep this active file near 150 lines. Compact ## Progress Notes hardest, then completed phases (keep phase headings + Status lines verbatim); never raw-truncate. -->

## Goal
<!-- One or two short sentences. The hook re-injects this, so keep it concise. -->
[One sentence describing the end state]

## Current Phase
<!-- Leave empty while planning/discussing. Fill only when starting implementation, e.g. "Phase 1". -->

## Workflow Profile
<!-- Pick exactly one before implementation: A, B, or C. -->
**Profile:** [A | B | C]

- **A - PR-Handoff:** stop after PR opened, CI green, reviewers requested.
- **B - Staging-Verified:** stop after staging deploy and staging E2E pass.
- **C - Research/Document:** stop after deliverable file/report is complete.

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
<!-- Exact commands/checks only. Do not substitute cheaper checks for stricter ones. -->
- `<exact command or check>`:

## Progress Notes
<!-- Concise chronological notes. Summarize or remove stale detail during compaction. -->
- [YYYY-MM-DD] Created plan.

## Errors Encountered
<!-- Log all errors to avoid repeating failures. -->
| Error | Attempt | Resolution |
|-------|---------|------------|

## Files Touched
<!-- Keep current and relevant. -->
- [path]: [why]

## Compaction Notes
<!-- If this file grows beyond about 150 lines, compact before continuing. -->
- Preserve: goal, current phase, incomplete tasks, blockers, verification commands, recent errors, and active user decisions referenced from `decisions.md`.
- Compact in order: (1) `## Progress Notes` hardest — keep only active/recent entries; (2) completed phases → one-line outcome, keeping each `### Phase N:` heading and `- **Status:**` line verbatim; (3) resolved errors → short summaries.
- Never raw-truncate.
