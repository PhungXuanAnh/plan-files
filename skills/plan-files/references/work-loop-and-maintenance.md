# Work Loop and Maintenance Details

Read this reference when handling long waits, repeated failures, compaction, continuation across phases, or an intentional pause.

## Phase loop

Before a phase, refresh bounded overview, restore-check, the exact phase, active decisions, and relevant findings. Set Current Phase, Active Item, and phase status before acting. Do not load every planning file for one known edit.

Give each phase executable acceptance outcomes. After meaningful work, keep verification, current errors, and touched files current. When an item becomes true, checkpoint immediately. A phase completes only after its acceptance outcomes pass.

When Current Phase settles, advance to the next non-settled phase and continue in the same turn. Commentary may report progress; final output is only for terminal state. Completing one item or phase, updating Resume Checkpoint, or receiving a Stop continuation is not permission to stop.

Append a phase only for the same goal. Phase 13+ uses history-first rollover: archive the oldest eligible non-current complete phase, preserve the monotonic high-water id, then allocate the new id. If twelve hot phases are all unfinished, finish/compact them or split work with a genuinely independent goal/owner.

## Errors and alternative paths

Log errors immediately with attempt and resolution.

Log a failure that changes your approach: it altered the plan, revealed a constraint, or left the item unfinished. A failure you immediately retried and got past is not an error, it is a retry, and recording it produces planning noise with no resume value. If the same retry-able failure recurs, that pattern is itself a finding and belongs in `findings.md` as a gotcha.

A failed click, selector, timeout, rejected execution route, or tool path is not an external blocker while a materially different path remains. Diagnose before retrying and attempt three materially different viable approaches before declaring an external impasse.

Retain errors by future value:

- unresolved/current operational errors stay in `tasks.md`;
- recurring root causes and workarounds move to `findings.md`;
- audit-worthy resolved failures move to `history.md`;
- resolved noise is removed after its phase settles.

## Async waits

For a long command, external job, or test run, prefer a streaming/monitor tool that returns output into the same turn. Do not end turns merely to poll; each turn re-triggers Stop without proving useful progress. If no monitor exists and the external wait genuinely spans turns, record the exact resume check and mark the phase `blocked (reason)`, then continue other actionable phases.

## Exact verification

Name commands or observable checks before implementation. Do not replace a user-requested E2E, staging check, or external observation with a cheaper substitute. Keep only checks still required plus the latest relevant baseline in hot state; archive detailed completed evidence.

## Compaction order

Run `plan_state.py budgets` and use targeted operations. Never raw-truncate.

1. Consolidate old Progress Notes.
2. Archive completed Verification entries.
3. Archive resolved errors.
4. Archive the oldest non-current complete phase with `compact-oldest`.
5. Consolidate repeated findings while preserving a short Current Summary, durable conclusions, gotchas, and sources.
6. Compress superseded decisions without losing rationale that explains the active choice.
7. Split only independent follow-up work if the coherent hot state still cannot fit.

Preserve Goal, Task Identity, current and unfinished phases, Active Item, exact next action/blocker, required checks, active decisions, relevant findings, and current file/error state. Never automatically archive pending, current, blocked, or deferred phases. Never delete evidenced work.

`history.md` stores concise trusted phase outcomes, verification evidence, resolved root causes, and durable references. Do not auto-read it or copy external content into it.

## Handoff and freshness

Resume Checkpoint is the normal resume source. Create/overwrite `handoff.md` only when an intentional pause has volatile details that do not fit concisely: running processes, partial commands, live external state, or multi-repo working state. Never append or duplicate goals, decisions, findings, or completed narrative.

Write handoff after required planning files and include:

```markdown
Updated: 2026-08-28T10:00:00+07:00
Reverify after: 2026-08-28T10:30:00+07:00
```

On resume, ignore and re-verify it if expired or if tasks/findings/decisions are newer. Clear obsolete handoff state. External-state Verification markers follow the same observed/reverify-after rule.

If a true dependency blocks one phase, update Resume Checkpoint, use `blocked (reason)`, and continue other phases. Use `deferred (reason)` only on explicit user instruction. Set either with `plan_edit.py phase-update <N> --status blocked|deferred --reason "..."` so the exact machine-readable grammar is written for you; retitling a phase or dropping the reason leaves it actionable and the Stop hook will correctly refuse to finish. When the pause also needs a handoff, `plan_edit.py pause` does both in the correct order.

## Finalization

After all in-scope work settles:

1. Complete the final item with current evidence and `--deactivate-pointer`.
2. Refresh bounded overview and restore state.
3. Re-read tasks state from disk.
4. Run `plan_checkpoint.py assert-finalizable --project-root <root>`.
5. If it names an issue, continue/repair instead of emitting another progress summary.
6. Preserve the task directory as history and return only the user-facing outcome.
