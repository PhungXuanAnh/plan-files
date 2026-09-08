# Targeted Plan Operations

Use structural commands to preserve phase/item/archive invariants and bounded reads to avoid loading irrelevant state. Direct Markdown edits are also appropriate for short prose in findings, decisions, or narrative task sections; a small edit does not need a fingerprint round trip. Execution transitions still use checkpoints.

Resolve all script paths relative to `SKILL.md`.

## Resolving the plan

`plan_state.py`, `plan_edit.py`, and `plan_checkpoint.py` all take the plan as an optional argument (`--plan` on the editor and checkpoint, positional on the reader). When it is omitted they resolve the task named by this workspace's `.plan-files` pointer, discovered upward from the working directory — the same default the hooks route on, rewritten by `session-state.sh` whenever a session claims or binds a task. A command that resolved it this way echoes the file it acted on in `plan`, and one that cannot resolve a usable pointer fails without writing, naming the pointer it read. Name the plan explicitly to act on a task other than the active one, or when running from outside the project. Examples below keep `--plan` where the path is the point; everywhere else it is optional. `plan_state.py section` accepts a bare planning filename (`decisions.md`) and resolves it inside the active task directory.

## Bounded reads

`restore-check` schema 1 includes additive `discussion_mode`: true for an unstarted plan with empty Current Phase/Active Item and all phases pending. Such a plan may pass restore checks and yield for discussion, but PreTool still requires starting an item before execution. `assert-finalizable` continues to require settled phases; discussion is not completion.

```bash
python3 <skill-dir>/scripts/plan_state.py overview <task-dir>/tasks.md
python3 <skill-dir>/scripts/plan_state.py resume-pack <task-dir>/tasks.md
python3 <skill-dir>/scripts/plan_state.py phase <task-dir>/tasks.md 3
python3 <skill-dir>/scripts/plan_state.py item <task-dir>/tasks.md P3.2
python3 <skill-dir>/scripts/plan_state.py section <task-dir>/decisions.md "Active Decisions"
python3 <skill-dir>/scripts/plan_state.py budgets <task-dir>/tasks.md
python3 <skill-dir>/scripts/plan_state.py restore-check <task-dir>/tasks.md
```

`overview` and its `resume-pack` alias emit schema version 2 with a 4 KiB serialized-character ceiling by default. They prioritize restore-critical state, return only the current/actionable phase frontier plus lifecycle counts, and expose every shortened section under `view_meta.truncated_sections` with an exact targeted entry in `view_meta.next_read.targets`. `--max-chars` remains the per-section ceiling; use `--total-max-chars 0` only for legacy unbounded overview output.

`overview` never fails because state is too large. When trimming narrative sections is not enough it degrades further, in order: per-section truncation detail, non-plan fingerprints, phase titles, then non-current phases. Each step is named in `view_meta.degraded`, and `view_meta.next_read` gains `phases`/`fingerprints` commands to recover the shed detail. Identity, Active Item, next action, blocker, phase counts, and restore issues always survive, so a resume is always possible. The dedicated section/phase/item/budgets/fingerprint commands and their JSON fields remain unchanged. Section/phase/item output reports `truncated: true` when more exists; pass `--max-chars 0` only when the complete target is genuinely needed.

`restore-check` emits bounded issue metadata rather than section bodies. It validates semantic resume fields and freshness, exits 2 while repair is required, and names the source, heading, and targeted repair for every issue. `overview.restore` carries at most the first three issues plus `issue_count`; use `restore-check` for the complete diagnosis.

If `overview.restore.ok` is true, do not run a second restore check immediately. Follow targeted reads only for the state the next action needs. The hooks still recheck disk state before operational tools.

Schema-version migration notes:

- `phases` contains the current/actionable frontier; use `phase_counts` for the full status summary and `phase` for completed detail.
- `budgets` is a compact hot-state summary; use the unchanged `budgets` command for full limits and fingerprints.
- Text keys remain strings. When a value is shortened or empty, follow its `view_meta.next_read.targets` entry instead of assuming the source section is empty.
- `overview.restore` is an additive schema-2 field; consumers may ignore it, or follow `details` when `ok` is false.

`restore-check` uses schema version 1. Its issue objects are metadata-only and new checks/codes are additive; consumers should branch on `ok` and tolerate unknown issue codes.

Two different hashes appear in output, and only one is an edit token:

- `file_fingerprint` — full SHA-256 of the file. This is the only value `plan_edit.py --expected-fingerprint` accepts. `plan_checkpoint.py` returns it on every transition, as does `sha256sum <file>`.
- `fingerprint` — 16-hex semantic progress hash. Hooks use it to detect that the plan advanced. It is never a valid `--expected-fingerprint`.

The bare `fingerprint` CLI retains its legacy plain 16-hex output. `fingerprint --json [FILE]` returns `{file, file_fingerprint, fingerprint}`; `fingerprint --file [FILE]` prints only the full SHA-256, including for companion files such as `decisions.md`. Prefer reusing the full hash from the state you just read or the previous successful edit. A freshly computed hash is not proof that an old replacement body is still current.

Passing the 16-hex value to an edit is rejected with a message naming the mistake and the correct value; a genuinely stale file fingerprint fails without writing.

## Structural edits

```bash
python3 <skill-dir>/scripts/plan_edit.py --compact --expected-fingerprint <sha> \
  phase-add --title "Verify migration" --item "The migration result is present." \
  --verify "The requested smoke check passes." --start
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  phase-add --title "Verify migration" --after 2 \
  --expected-history-fingerprint <history-sha-or-missing>
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  phase-update 3 --title "Verify production migration"
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  phase-update 3 --status deferred --reason "user paused pending quota"
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  item-add --phase 3 --kind P --text "The production smoke check passes."
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  item-move P3.2 --phase 4 --after P4.1
```

Available phase operations are `phase-add`, `phase-update`, `phase-move`, and `phase-remove`. `phase-update` takes `--title`, `--status`, or both; it writes the exact `- **Status:**` grammar so a pause or block never depends on hand-editing that line. `blocked` and `deferred` require `--reason`, and `--status complete` is refused while the phase still holds unchecked items. Item operations are `item-add`, `item-update`, `item-move`, and `item-remove`. Add operations allocate the next unused ID. Reordering within a phase preserves the ID; moving across phases allocates a phase-matching ID and returns the mapping. The history fingerprint is optional while fewer than 12 phase headings remain, but required when `phase-add` must archive the oldest eligible complete phase to keep the hot window at 12.

`phase-add` accepts repeated `--item`/`--verify` values and optional `--start`. It assembles the phase and its outcomes in memory, then starts the first item in the same write. `--start` requires at least one item and cannot displace active work. Without `--start`, the populated phase stays pending. For newly authorized work when all old phases are settled (including blocked/deferred), prefer `reopen` so the decision is recorded too. For an existing pending phase, add its items before `plan_checkpoint.py start <item>`; do not first change an empty phase to `in_progress` or try to edit Current Phase through `section-replace`.

Successful editor JSON adds `file_fingerprint` as an unambiguous alias for the target file's full hash; older fields remain. Global `--compact` omits repeated context, budgets, usage, and old hashes, retaining operation results and current edit tokens. Errors remain complete with a nonzero exit. Use this mode instead of `head`/`tail`/`sed` filters that can hide failures or truncate JSON. Global flags go before the subcommand; subcommand help also states the required global options.

Use `--dry-run` before a consequential structural edit. A dry run validates the candidate, preflights budgets, and returns the candidate fingerprint without changing disk. `--plan`, `--expected-fingerprint`, and `--dry-run` are global flags and must appear before the subcommand; `--expected-history-fingerprint` belongs to the subcommand that archives.

Every subcommand carries `--help`. `handoff-write --help` states the required headings, the timestamp format, and the byte/line budget, and a rejected handoff reports every violation in one response rather than one per attempt.

Direct removal is intentionally narrow: an item must be unchecked, non-active, and evidence-free; a phase must be pending, non-current, and contain no completed/evidenced work. Removed IDs leave compact retirement markers and are never reused. Archive completed/evidenced work instead.

## Pausing

When the user postpones work, one call settles the phase and stages its handoff:

```bash
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <file_fingerprint> \
  pause --phase 13 --reason "user paused pending quota" \
  --evidence "18 of 20 Selenium steps ran; stopped at the onboarding regression" \
  --handoff-content '<handoff body>'
```

It records the partial evidence on the Active Item, writes the exact status grammar with its reason, moves Active Item to whatever is still actionable (or clears it when nothing is), syncs Resume Checkpoint, and writes `handoff.md` **last**. That order matters: `handoff.md` is stale whenever a required planning file is newer, so a handoff written before `tasks.md` is stale on arrival, and doing this by hand reliably costs a wasted write plus a rewrite.

Use `--all-remaining` instead of `--phase` to settle every non-settled phase when the whole task pauses. `--status blocked` records an external dependency instead of a user postponement, and also sets the Resume Checkpoint blocker. `--handoff-content` and `--evidence` are optional.

The response reports `paused_phases`, `next_item`, `still_actionable`, and a `restore` block. Validation is fail-closed: an empty reason, an already-settled phase, `--phase` together with `--all-remaining`, an Active Item outside the paused phases, or an invalid handoff body all leave every file untouched.

`pause` deliberately does not write `decisions.md` or `findings.md`. Their content needs judgment, so write them yourself before calling it.

Use `pause` for the active phase even when no handoff is needed. `phase-update --status` only changes the phase status; it cannot clear or advance Active Item and synchronize Resume Checkpoint for that transition.

## Section and entry edits

Use semantic section names, not line numbers:

`findings.md` accepts any existing, uniquely named level-2 section, including legacy names such as `Phase 5 Evidence`. Missing or duplicate headings fail without writing. Task, decision, history, and handoff fields retain their explicit section allowlists. Preserve detailed external evidence in a linked findings file before replacing its hot section with a summary; external content must not move into trusted history.

```bash
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  section-replace --file tasks.md --heading "Resume Checkpoint" --content '<new body>'
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  entry-append --file findings.md --heading Discoveries --entry '- New durable discovery.'
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  entry-replace --file tasks.md --heading "Files Touched" --entry '- old.py: old' --replacement '- new.py: new'
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  entry-remove --file decisions.md --heading "Open Decision Questions" --entry '- [ ] Resolved question'
```

The expected fingerprint belongs to the file named by `--file`, not always `tasks.md`. The editor allows only known planning filenames and sections, matches replacement/removal entries exactly once, rejects entries or section bodies that escape into another `##` section, preflights that file's budget, and atomically replaces it. `entry-append` separates prose entries with a blank line but appends a Markdown table row directly under the row above it, because a blank line between two rows ends the table and starts a second one.

Common targets:

| File | Repeatedly edited sections |
|---|---|
| `tasks.md` | Resume Checkpoint, Key Questions, Verification, Progress Notes, Errors Encountered, Files Touched |
| `decisions.md` | Active Decisions, Superseded Decisions, Open Decision Questions |
| `findings.md` | Current Summary, Requirements, Discoveries, Known Gotchas, Sources, Detail Index |
| `history.md` | Completed Phases, Verification History, Resolved Errors |
| `handoff.md` | whole overwrite-only resume snapshot |

Keep using `plan_checkpoint.py` for `start`, `progress`, and `complete`. Do not emulate execution transitions with generic section edits. `plan_checkpoint.py deactivate-pointer --project-root <root>` is the recovery for a settled plan that finished without `--deactivate-pointer`: it reports `{"operation":"deactivate-pointer","pointer":<path>,"cleared":<bool>}`, is idempotent, names whichever pointer file the workspace actually uses, and fails with the remaining issues when the plan is not otherwise finalizable. Reaching for a hand edit of the pointer instead is blocked on a settled plan.

After deactivation, the default pointer no longer resolves a plan. Keep its known path for subsequent reads and `python3 <skill-dir>/scripts/plan_checkpoint.py --plan <tasks.md> assert-finalizable --project-root <root>`.

## Lifecycle operations

```bash
python3 <skill-dir>/scripts/plan_edit.py --expected-fingerprint <tasks-sha> \
  reopen --title "Vanity domain aliases" \
  --decision '| D2 | Add vanity domain aliases | user authorized on 2026-09-07 | 2026-09-07 |' \
  --supersede D1 \
  --item "The alias resolver ships behind the existing redirect service." \
  --verify "The alias e2e suite passes." \
  --non-goals "analytics dashboards; per-user custom domains"
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <decisions-sha> \
  decision-supersede D1 --replacement D2 --reason "User changed the requirement"
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <tasks-sha> \
  archive-phase 2 --expected-history-fingerprint missing
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <tasks-sha> \
  compact-oldest --expected-history-fingerprint <history-sha-or-missing>
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <tasks-sha> \
  archive-entry --source-section Verification --entry '<exact hot entry>' \
  --archive-entry '<concise cold entry>' --expected-history-fingerprint <history-sha>
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <handoff-sha-or-missing> \
  handoff-write --content '<complete handoff snapshot>'
```

`reopen` is the one call that makes a settled plan able to record new work. It appends the authorizing row to Active Decisions, optionally retires what that row replaces, reconciles whichever scope fields you name, adds the phase that carries the work with its items, and starts the first one — validating everything before writing anything, and writing `decisions.md` before `tasks.md` so a crash can leave a recorded authorization with no phase, never a phase nothing authorized. Re-running it after such a crash does not duplicate the decision row. It refuses a plan that still has an actionable phase: that plan needs `phase-add`/`item-add` and `plan_checkpoint.py start` instead. Its JSON adds `phase`, `items`, `item` (the started one), `decision`, `decision_already_recorded`, `superseded`, and the `decisions_file`/`decisions_old_fingerprint`/`decisions_fingerprint`/`decisions_usage` fields, alongside the usual tasks.md fingerprints, context, and budgets. Like `phase-add`, it needs `--expected-history-fingerprint` only when the new phase pushes the hot window past 12 headings.

`decision-supersede` moves one active row and records its replacement in one atomic file write. `archive-phase` evicts one named complete, non-current phase; `compact-oldest` chooses the oldest eligible phase. Rollover and entry/phase archival create a bounded `.plan-edit-transaction.json`, then commit history before hot state under a plan-directory lock. The next `plan_edit.py` call automatically reconciles a journal left after either write, validates both target fingerprints, and clears it only after the recovered plan validates. A conflicting external edit fails closed and preserves the journal for diagnosis. Repeat `compact-oldest` with refreshed task/history fingerprints while phase archival remains the right way to clear a budget warning. `handoff-write` accepts a complete snapshot and creates or replaces `handoff.md`; it requires timezone-aware ISO-8601 `Updated` and `Reverify after` fields with a positive freshness window. `handoff-clear` removes a fingerprint-matched obsolete snapshot.

Archive command JSON adds `transaction_id` on committed writes (`null` for dry runs). This is additive to the existing fingerprints/context/budgets response. `.plan-edit-transaction.json` is private internal schema version 1; callers must not edit it or depend on its fields.

## Limits and recovery

The maintenance ceilings are 300 lines, 24 KiB, 12 hot phase headings, about 100 visible items, and at most 15 items or 4 KiB in Current Phase. Crossing a ceiling is not malformed state: reads and plan-local repair remain allowed, while unrelated mutation waits for compaction or task splitting.

Compact in this order: old Progress Notes, completed verification, resolved errors, and completed phase detail. Archived phase headings leave the hot window; a single high-water marker prevents ID reuse. If neither `phase-add` rollover nor `compact-oldest` finds a non-current complete phase, it fails without writing. Split a new task only when the remaining work has an independent goal or ownership boundary.

If a structured command cannot express the repair, read the relevant section and use native Edit/Write with its explicit file path. A shell alternative is `cat > '<absolute-plan-dir>/findings-detail.md' <<'MD'` with a matching `MD` line: the delimiter must be quoted, the single `.md` target literal and inside the owned plan, and any following commands read-only and foreground. Arbitrary Python, unquoted heredocs, expanded targets, and mixed unrelated writes do not qualify merely by naming the plan. Validate/budget-check the repaired state; consolidate with room for the next update instead of trimming exactly to the ceiling.
