# Targeted Plan Operations

Use these commands when a planning file is large enough that loading or patching the whole file would waste context. Direct Markdown reads and edits remain valid for unusual repairs or judgment-heavy rewrites.

Resolve all script paths relative to `SKILL.md`.

## Bounded reads

```bash
python3 <skill-dir>/scripts/plan_state.py overview <task-dir>/tasks.md
python3 <skill-dir>/scripts/plan_state.py resume-pack <task-dir>/tasks.md
python3 <skill-dir>/scripts/plan_state.py phase <task-dir>/tasks.md 3
python3 <skill-dir>/scripts/plan_state.py item <task-dir>/tasks.md P3.2
python3 <skill-dir>/scripts/plan_state.py section <task-dir>/decisions.md "Active Decisions"
python3 <skill-dir>/scripts/plan_state.py budgets <task-dir>/tasks.md
python3 <skill-dir>/scripts/plan_state.py restore-check <task-dir>/tasks.md
```

`overview` and its `resume-pack` alias emit schema version 2 with a strict 4 KiB serialized-character ceiling by default. They prioritize restore-critical state, return only the current/actionable phase frontier plus lifecycle counts, and expose every shortened section under `view_meta.truncated_sections` with an exact targeted entry in `view_meta.next_read.targets`. `--max-chars` remains the per-section ceiling; use `--total-max-chars 0` only for legacy unbounded overview output. The dedicated section/phase/item/budgets/fingerprint commands and their JSON fields remain unchanged. Section/phase/item output reports `truncated: true` when more exists; pass `--max-chars 0` only when the complete target is genuinely needed.

`restore-check` emits bounded issue metadata rather than section bodies. It validates semantic resume fields and freshness, exits 2 while repair is required, and names the source, heading, and targeted repair for every issue. `overview.restore` carries at most the first three issues plus `issue_count`; use `restore-check` for the complete diagnosis.

Schema-version migration notes:

- `phases` contains the current/actionable frontier; use `phase_counts` for the full status summary and `phase` for completed detail.
- `budgets` is a compact hot-state summary; use the unchanged `budgets` command for full limits and fingerprints.
- Text keys remain strings. When a value is shortened or empty, follow its `view_meta.next_read.targets` entry instead of assuming the source section is empty.
- `overview.restore` is an additive schema-2 field; consumers may ignore it, or follow `details` when `ok` is false.

`restore-check` uses schema version 1. Its issue objects are metadata-only and new checks/codes are additive; consumers should branch on `ok` and tolerate unknown issue codes.

Every read returns the target file's SHA-256. Pass that value to the next mutation as `--expected-fingerprint`; a stale value fails without writing.

## Structural edits

```bash
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  phase-add --title "Verify migration" --after 2 \
  --expected-history-fingerprint <history-sha-or-missing>
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  phase-update 3 --title "Verify production migration"
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  item-add --phase 3 --kind P --text "The production smoke check passes."
python3 <skill-dir>/scripts/plan_edit.py --plan <tasks.md> --expected-fingerprint <sha> \
  item-move P3.2 --phase 4 --after P4.1
```

Available phase operations are `phase-add`, `phase-update`, `phase-move`, and `phase-remove`. Item operations are `item-add`, `item-update`, `item-move`, and `item-remove`. Add operations allocate the next unused ID. Reordering within a phase preserves the ID; moving across phases allocates a phase-matching ID and returns the mapping. The history fingerprint is optional while fewer than 12 phase headings remain, but required when `phase-add` must archive the oldest eligible complete phase to keep the hot window at 12.

Use `--dry-run` before a consequential structural edit. A dry run validates the candidate, preflights budgets, and returns the candidate fingerprint without changing disk.

Direct removal is intentionally narrow: an item must be unchecked, non-active, and evidence-free; a phase must be pending, non-current, and contain no completed/evidenced work. Removed IDs leave compact retirement markers and are never reused. Archive completed/evidenced work instead.

## Section and entry edits

Use semantic section names, not line numbers:

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

The expected fingerprint belongs to the file named by `--file`, not always `tasks.md`. The editor allows only known planning filenames and sections, matches replacement/removal entries exactly once, rejects entries or section bodies that escape into another `##` section, preflights that file's budget, and atomically replaces it.

Common targets:

| File | Repeatedly edited sections |
|---|---|
| `tasks.md` | Resume Checkpoint, Key Questions, Verification, Progress Notes, Errors Encountered, Files Touched |
| `decisions.md` | Active Decisions, Superseded Decisions, Open Decision Questions |
| `findings.md` | Current Summary, Requirements, Discoveries, Known Gotchas, Sources, Detail Index |
| `history.md` | Completed Phases, Verification History, Resolved Errors |
| `handoff.md` | whole overwrite-only resume snapshot |

Keep using `plan_checkpoint.py` for `start`, `progress`, and `complete`. Do not emulate execution transitions with generic section edits.

## Lifecycle operations

```bash
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

`decision-supersede` moves one active row and records its replacement in one atomic file write. `archive-phase` evicts one named complete, non-current phase; `compact-oldest` chooses the oldest eligible phase. Rollover and entry/phase archival create a bounded `.plan-edit-transaction.json`, then commit history before hot state under a plan-directory lock. The next `plan_edit.py` call automatically reconciles a journal left after either write, validates both target fingerprints, and clears it only after the recovered plan validates. A conflicting external edit fails closed and preserves the journal for diagnosis. Repeat `compact-oldest` with refreshed task/history fingerprints while phase archival remains the right way to clear a budget warning. `handoff-write` accepts a complete snapshot and creates or replaces `handoff.md`; it requires timezone-aware ISO-8601 `Updated` and `Reverify after` fields with a positive freshness window. `handoff-clear` removes a fingerprint-matched obsolete snapshot.

Archive command JSON adds `transaction_id` on committed writes (`null` for dry runs). This is additive to the existing fingerprints/context/budgets response. `.plan-edit-transaction.json` is private internal schema version 1; callers must not edit it or depend on its fields.

## Limits and recovery

The maintenance ceilings are 300 lines, 24 KiB, 12 hot phase headings, about 100 visible items, and at most 15 items or 4 KiB in Current Phase. Crossing a ceiling is not malformed state: reads and plan-local repair remain allowed, while unrelated mutation waits for compaction or task splitting.

Compact in this order: old Progress Notes, completed verification, resolved errors, and completed phase detail. Archived phase headings leave the hot window; a single high-water marker prevents ID reuse. If neither `phase-add` rollover nor `compact-oldest` finds a non-current complete phase, it fails without writing. Split a new task only when the remaining work has an independent goal or ownership boundary.

If a structured command cannot express the intended repair, read the necessary full section or file, edit it directly, then run `plan_state.py validate`, `plan_state.py budgets`, and the appropriate finalizability check.
