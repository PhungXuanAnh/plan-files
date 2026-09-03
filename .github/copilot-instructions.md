# Repository architecture

This repository contains one host-neutral planning skill plus provider-specific hook adapters. Keep behavior in the canonical skill/scripts and keep provider wrappers thin.

## Canonical skill layout

- `skills/plan-files/SKILL.md` is the compact entrypoint. It contains only routing, trust, hot-state, work-loop, checkpoint, and maintenance invariants.
- `skills/plan-files/references/` contains conditional detail:
  - `routing-and-hooks.md` — root resolution, ownership, sessions, and provider behavior.
  - `format-contract.md` — exact Markdown section/phase/item grammar and legacy migration.
  - `plan-operations.md` — bounded reads, fingerprinted edits, archival, schemas, and recovery.
  - `work-loop-and-maintenance.md` — continuation, waits, errors, compaction, and handoff.
  - `observing-runs.md` — privacy-safe telemetry and deterministic behavioral evaluation.
- `skills/plan-files/templates/` defines new planning files. There is one authoritative `tasks.md` format; do not add `plan.md`, `tasks-long.md`, or an unbounded mode.
- `skills/plan-files/scripts/` contains shared provider-neutral behavior:
  - `plan_state.py` — parsing, validation, budgets, bounded reads, overview/resume-pack, and restore checks.
  - `plan_checkpoint.py` — execution transitions (`start`, `progress`, `complete`, finalizability).
  - `plan_edit.py` — fingerprinted structural/section edits and transactional lifecycle operations.
  - `session-state.sh` and `resolve-project-root.sh` — prompt-scoped ownership and workspace resolution.
  - `pre-tool-gate.sh` and `maintenance-tool-allowed.py` — restore/maintenance enforcement and semantic tool classification.
  - `hook-common.sh`, `hook-post-tool-use.sh`, and `hook-agent-stop.sh` — shared hook helpers plus canonical PostTool and Stop policy.
  - `hook-user-prompt-submit.sh` and `hook-bind-session.sh` — shared prompt and session-binding behavior for providers with compatible envelopes.
  - `observe.py` and `behavioral_eval.py` — telemetry reporting and isolated regression evaluation.

Use snake_case for importable Python module filenames. Resolve all skill script paths relative to `SKILL.md`; never hardcode a user's installation path in the canonical skill.

## Runtime planning state

Planning state is private and project-local:

```text
<project-root>/
├── .plan-files                  # candidate/default task id, not ownership
└── tmp/plan-files/
    ├── .sessions/                    # private prompt-scoped ownership state
    └── <task-id>/
        ├── tasks.md                  # trusted authoritative hot plan
        ├── findings.md               # discoveries and untrusted external content
        ├── decisions.md              # trusted user-decision ledger
        ├── history.md                # optional trusted cold archive
        └── handoff.md                # optional overwrite-only volatile snapshot
```

- A session lease owns a task; `.plan-files` only supplies a candidate for humans/new prompts.
- On every new prompt, classify the candidate as `SAME`, `DIFFERENT`, or `AMBIGUOUS`. Bind before loading SAME state; never mutate a DIFFERENT candidate; ask before changing an AMBIGUOUS one.
- `overview`/`resume-pack` schema 2 has a strict 4 KiB serialized cap and names targeted follow-up reads for shortened sections.
- `restore-check` schema 1 validates non-placeholder identity/resume fields, Active Item, verification, decisions/findings, and handoff/external-evidence freshness without returning complete file bodies.
- Use `plan_checkpoint.py` immediately when an Active Item's evidence becomes true. Do not independently edit checkbox, phase status, Current Phase, and Active Item.
- Use `plan_edit.py` for routine phase/item/section/archive mutations. Direct Markdown access remains an allowed fallback for unusual repair or narrative judgment.

## Limits and lifecycle

Maintenance limits are enforcement boundaries, not reasons to truncate:

| File/scope | Limit |
|---|---:|
| `tasks.md` | 300 lines / 24 KiB |
| `findings.md` | 250 lines / 32 KiB |
| `decisions.md` | 150 lines / 12 KiB |
| `handoff.md` | 50 lines / 6 KiB |
| hot phase headings | 12 |
| visible items | about 100 |
| Current Phase | 15 items / 4 KiB |

- Keep one coherent goal in one bounded `tasks.md`. Add Phase 13+ only for the same goal.
- `phase-add` and `compact-oldest` history-first archive the oldest eligible non-current complete phase and preserve a monotonic phase-id high-water mark.
- Never evict pending/current/blocked/deferred work or delete evidenced work to meet a limit. Split only work with an independent goal or ownership boundary.
- Rollover and phase/entry archival use `.plan-edit-transaction.json` under a plan-directory lock. The next `plan_edit.py` invocation automatically reconciles interrupted history/tasks writes; fingerprint conflicts fail closed. Do not edit the journal manually.
- `handoff.md` requires timezone-aware ISO-8601 `Updated` and `Reverify after` fields. Expired or dependency-stale state must be re-verified.

## Hook architecture and parity

Provider adapters live under:

- `.codex/hooks/plan-files/scripts/`
- `.claude/hooks/plan-files/scripts/`
- `.github/hooks/scripts/`

Codex, Claude Code, and GitHub Copilot must preserve the same behavioral contract:

- PreTool: resolve session ownership, block invalid restore/item state and over-budget unrelated mutation, but allow read-only diagnosis and owned-plan maintenance.
- PostTool: inject bounded context, targeted restore/compaction guidance, and risk-aware checkpoint reminders. Read-only exploration and plan maintenance have zero semantic risk; likely evidence and operational mutations raise risk.
- Stop: continue actionable/invalid work until every phase is settled and finalization succeeds.
- Telemetry: log provider plus hashed task/session scope, injection sizes, semantic class/risk, and Stop continuations; never log raw session ids or raw hook input previews.

Keep the three provider `common.sh` bridges byte-identical. Provider event scripts must remain thin launch shims into the canonical shell cores; provider-only code may translate event arguments, session identity, or output envelopes, but must not redefine planning policy. Keep semantic-delta policy single-sourced in `hook-post-tool-use.sh` and Stop policy single-sourced in `hook-agent-stop.sh`.

Treat the hook design as an Abstract Core + Provider Adapter architecture. These roles are language-independent. Bash is the current implementation, not a permanent constraint.

- The abstract core accepts a logical normalized hook request and produces a logical provider-neutral result. It exclusively owns root/session resolution, plan parsing, restore/maintenance gating, semantic risk, checkpoint guidance, Stop/finalization decisions, message text, locking, and telemetry policy.
- A provider adapter converts the raw provider event/input/session/capabilities to the core contract, invokes the core, and converts the result to the exact provider output envelope. It may not read plan Markdown to make policy decisions or duplicate core messages and conditions.
- If equivalent logic is required by two providers, extract it to `skills/plan-files/scripts/`; never solve parity by copying one provider script into another.
- Provider-only events may remain local only when no cross-provider event exists. They must still delegate overlapping candidate, ownership, and plan-state semantics to canonical scripts.
- Test policy at the shared-core boundary. Provider tests should focus on input normalization, capability flags, session identity, and output rendering for every supported envelope.
- A new provider must be implemented as a new adapter around the existing core, not as a fork of Codex, Claude, or Copilot policy code.

Port shared hook code to Python when shell complexity creates a meaningful maintenance or correctness cost—for example, complex JSON/protocol conversion, state transitions, concurrency/locking, error recovery, testability problems, or a large expected change surface. When porting:

- Migrate a complete shared responsibility or the complete runtime, not scattered branches inside provider wrappers.
- Switch every affected provider entrypoint and its tests to the new implementation together.
- Prove behavioral and output-envelope parity before removing the old implementation.
- Remove superseded Bash policy once parity passes; never leave Bash and Python as two authoritative implementations of the same behavior.
- Preserve stable hook paths or update installers/configuration atomically when a path must change.

For an object-oriented Python implementation, retain one `AbstractHook`/`HookCore` with `handle(HookRequest) -> HookResult` and separate `CodexAdapter`, `ClaudeAdapter`, and `CopilotAdapter` classes with `from_provider_input(...)` and `to_provider_output(...)`. Provider classes must not override planning behavior.

## Repository installation

- Run `make install` from this checkout to install the global planning skill and hooks for Codex, Claude Code, and GitHub Copilot; it also installs the Kiro skill.
- `make install` is safe to repeat. Correct links are preserved, stale links are replaced, and Claude Code/Codex planning hook groups are merged without duplication.
- Skill files and provider hook scripts execute from this repository, so edits to those files apply to global installations without reinstalling.
- Claude Code merges `.claude/settings.json.sample` into `~/.claude/settings.json`, preserving unrelated settings and hook groups. Codex similarly merges `.codex/hooks.json.sample` into `~/.codex/hooks.json`.
- Copilot's global hook configuration is a symlink to `.github/hooks/plan-files.json.sample`.
- Rerun the relevant hook installer (or `make install`) after changing a Claude/Codex sample hook definition or moving this checkout. Script-only edits do not require reinstalling.
- If Codex reports an untrusted changed hook definition, review it with `/hooks`. Restart sessions opened before a local config was renamed to `.sample`, so cached local/global layers do not both execute.

## Change and validation rules

- Update the compact entrypoint, focused reference, template, examples/README, and provider comments/tests together when behavior changes; do not duplicate all conditional detail back into `SKILL.md`.
- Output-schema changes should be additive when possible and documented in `references/plan-operations.md` or `references/observing-runs.md`.
- Preserve unrelated dirty worktree state. Never push code or submit review comments unless the user explicitly asks.
- Keep tests concise and consolidate related cases.

Before handing off a behavioral change, run the applicable checks, including:

```bash
make test
make behavioral-eval
python3 <skill-creator-dir>/scripts/quick_validate.py skills/plan-files
python3 -m py_compile skills/plan-files/scripts/*.py
bash -n skills/plan-files/scripts/*.sh \
  .codex/hooks/plan-files/scripts/*.sh \
  .claude/hooks/plan-files/scripts/*.sh \
  .github/hooks/scripts/*.sh
git diff --check
```

Also verify provider `common.sh` identity and exercise every provider adapter whenever shared hook behavior changes.
