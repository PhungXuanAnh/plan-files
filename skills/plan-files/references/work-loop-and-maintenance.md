# Work Loop and Maintenance Details

Read this reference when handling long waits, repeated failures, compaction, continuation across phases, or an intentional pause.

## Phase loop

Before a phase, read bounded overview and only the phase/decision/finding detail it lacks for the next action. Run restore-check for complete diagnostics when overview.restore.ok is false. Use checkpoint start (or phase-add with items and --start) to move Current Phase, Active Item, and status together. Do not load every planning file for one known edit.

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

Run `plan_state.py`, `plan_edit.py`, `plan_checkpoint.py`, session binding/root resolution and their path discovery in the foreground. Use the script directory next to the loaded `SKILL.md`; do not scan the home directory to rediscover a known installation. These are short, dependency-bearing operations: wait for the result before another plan mutation or implementation step. Do not combine them with a background build/test command; split the calls.

Grok exposes `background` (some versions/tools use `is_background`); Claude exposes `run_in_background`. Keep the applicable flag false. For Codex or another tool that yields a running session after its foreground time budget, use the returned wait/output tool in the same turn. Do not rerun a still-running checkpoint: collect its result first. Keep waits bounded so user updates remain possible.

Grok also permits the user to background a foreground command with Ctrl+B or a new message; a completion `<system-reminder>` is a host task notification, not a planning validation failure. The notification alone does not reveal which trigger applied. A home-wide `find` may take a long time even when its output is small. Hooks can deny an explicit background request they receive, but cannot undo host/UI scheduling or remove already queued notifications. Use the returned task id to collect output and continue; do not change harness binaries or disable all background work.

For a long command, external job, or test run, prefer a streaming/monitor tool that returns output into the same turn. Do not end turns merely to poll; each turn re-triggers Stop without proving useful progress. If no monitor exists and the external wait genuinely spans turns, record the exact resume check and mark the phase `blocked (reason)`, then continue other actionable phases.

## Exact verification

Name commands or observable checks before implementation. Do not replace a user-requested E2E, staging check, or external observation with a cheaper substitute. Keep only checks still required plus the latest relevant baseline in hot state; archive detailed completed evidence.

## Compaction order

Run `plan_state.py budgets` and use targeted operations. Never raw-truncate.

1. Consolidate old Progress Notes.
2. Archive completed Verification entries.
3. Archive resolved errors.
4. Archive the oldest non-current complete phase with `compact-oldest`.
5. Consolidate repeated findings while preserving a short Current Summary, durable conclusions, gotchas, and sources. Leave room for the next update. Existing legacy findings sections are editable through section-replace; use native Edit/Write for broader narrative repair.
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

If a true dependency blocks the active phase, use `plan_edit.py pause --phase <N> --status blocked --reason "..."`, adding partial evidence or handoff content when needed. It synchronizes Active Item and Resume Checkpoint so other actionable phases can continue. Use `deferred` only on explicit user instruction. `phase-update` can set the status of a non-active phase; it does not perform the active-work pause transition. Retitling a phase or omitting the reason leaves it actionable.

## Finalization

For a user-requested clarification or discussion-only turn, follow the `clarify`/`discuss` routing contract in [routing-and-hooks.md](routing-and-hooks.md). Keep unfinished phase state; these modes allow yielding without claiming execution is finalizable. Never use them to abandon authorized actionable work.

After all in-scope work settles:

1. Complete the final item with current evidence and `--deactivate-pointer`. When every item is already checked — a plan that finished in an earlier turn without the flag — run `plan_checkpoint.py deactivate-pointer --project-root <root>` instead; it clears the pointer only when this plan still owns it and refuses while any other finalization issue remains.
2. Run `plan_state.py restore-check <known-tasks.md>` followed by `plan_checkpoint.py --plan <known-tasks.md> assert-finalizable --project-root <root>`. These check final freshness and settlement respectively; after pointer cleanup the explicit plan path is required. No extra overview or full-file reread is needed.
3. If either names an issue, target-read and repair that issue before retrying.
4. Preserve the task directory as history and return the user-facing outcome.
