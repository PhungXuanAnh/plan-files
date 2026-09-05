# Exact `tasks.md` Format Contract

Read this reference before creating, migrating, or repairing a plan. Hooks use simple regular expressions, so preserve headings and field forms exactly.

## Required section order

Use one `## Goal`, followed by `## Task Identity`, `## Current Phase`, `## Active Item`, `## Workflow Profile`, `## Resume Checkpoint`, and `## Phases`. Other template sections follow Phases.

Task Identity contains concise visible bullets:

```markdown
- Deliverable: <specific owned result>
- Anchors: <stable ids or explicit none>
- Non-goals: <scope boundary or explicit none>
```

Before work, Current Phase and Active Item may be empty with all phases pending; this is valid discussion state. An operational mutation still requires starting an item. During work:

```markdown
## Current Phase
Phase 2

## Active Item
P2.1
```

The entire visible Current Phase body is exactly an existing `Phase N`; retain the final resolved phase after settlement. Format/profile and status-integrity errors are checked before operational tools and repeated after every tool until repaired, using the same policy as Stop. The Active Item body is exactly one unchecked id in that phase. Clear Active Item after all phases settle.

Workflow Profile is exactly one of:

- `**Profile:** A` — stop after PR opened, CI green, reviewers requested.
- `**Profile:** B` — stop after staging deploy and staging E2E.
- `**Profile:** C` — stop when the research/document deliverable is complete.

Resume Checkpoint retains these fields:

```markdown
- **Next action:** Complete P2.1: <exact command/edit/outcome>
- **Blocker:** none
- **Details:** none
```

Use a real external dependency instead of `none` when blocked. The checkpoint script synchronizes Next action and Blocker when it advances Active Item.

## Phase and status grammar

Every phase heading is inside `## Phases` and has this form:

```markdown
### Phase 2: Implement migration
```

Use exactly one status, either recognized inline legacy syntax or the preferred body line:

```markdown
- **Status:** pending
- **Status:** in_progress
- **Status:** complete
- **Status:** blocked (external dependency reason)
- **Status:** deferred (explicit user-directed reason)
```

Only one of those lines appears per phase. Blocked/deferred require a non-empty reason. A complete phase has no unchecked item. Blocked/deferred phases may retain unchecked outcomes.

Any `###` section containing work checkboxes must be a valid Phase heading. Do not hide work under Step, Task, Stage, or other headings.

## Outcome items

Use P ids for work and V ids for phase acceptance:

```markdown
- [ ] [P2.1] Legacy MX records are absent from authoritative DNS.
  - Evidence: pending

**Done when:**
- [ ] [V2.1] The authoritative routing check passes.
  - Evidence: pending
- **Status:** in_progress
```

- IDs are globally unique, match their containing phase number, and are never reused.
- Every checkbox in a contracted phase has exactly one indented Evidence line.
- Outcomes are falsifiable observable states, not broad activities.
- Scope/invariants remain prose, not work checkboxes.
- Checked evidence is concise and non-placeholder: command result, UI/API state, test result, or artifact reference.
- Partial evidence can remain on the unchecked Active Item. Attempted work is not completion.
- Acceptance items remain before the phase status.

The immediate checkpoint barrier applies when the observable outcome becomes true, not at phase end. Use `plan_checkpoint.py` instead of editing checkbox/status/current pointers independently.

## Legacy migration

A plan without `## Active Item` remains readable. Before its next implementation mutation:

1. Insert Active Item immediately after Current Phase.
2. Add stable phase-matching P/V ids and Evidence lines to current and future incomplete phases.
3. Point Active Item at the first unchecked id in Current Phase.
4. Keep archived completed phases compact; they need not be expanded merely to migrate.
5. Run `plan_state.py validate` and `restore-check`.

## Restore semantics

`restore-check` requires non-placeholder Goal; Deliverable/Anchors/Non-goals; exact Next action and Blocker; valid Active Item for a contracted actionable plan; Verification; active decisions or explicit `- None.`; and current findings summary. It returns bounded issue objects with `code`, `source`, `heading`, and `repair`.

Volatile Verification evidence uses:

```markdown
- [external-state observed=2026-08-28T10:00:00+07:00 reverify-after=2026-08-28T10:30:00+07:00] staging smoke: PASS
```

Timezone-aware ISO-8601 timestamps and a positive window are required. Expired evidence must be rerun before it counts.

## Settlement

Discussion mode can stop only when Current Phase is empty and no phase is already settled/actionable work has begun. During execution, Stop blocks malformed or actionable plans. Finalization requires every phase settled, no Active Item, truthful status/evidence, and the owned pointer deactivated.
