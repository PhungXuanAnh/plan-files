# Planning with Files

Persistent file-based planning for AI coding agents.

The canonical skill lives in [skills/plan-files](./skills/plan-files). IDE-specific skill folders should link to that folder instead of copying it. IDE hook scripts stay in the IDE-specific folders because each tool expects hooks in a different location and format. Repository hook configs end in `.sample`; only the global hook layer is enabled by default.

## Current Workflow

For each complex task, the agent uses a default pointer, prompt-scoped routing, and one task directory:

```text
<project root>/
├── .plan-files
└── tmp/plan-files/
    ├── .sessions/       # private hook-owned routing state
    └── <task-id>/
        ├── tasks.md
        ├── findings.md
        ├── decisions.md
        ├── history.md       # optional cold archive
        └── handoff.md       # optional latest resume snapshot
```

- `tasks.md` is the single authoritative plan: task identity, goal, current phase, phases/items/evidence, concise progress, errors, and verification. Its maintenance ceiling is 300 lines/24 KiB, 12 phases, about 100 visible items, and 15 items/4 KiB in Current Phase.
- `findings.md` stores research, discoveries, and untrusted external content.
- `decisions.md` stores user decisions, changed direction, superseded choices, and open decision questions.
- `history.md` stores trusted completed-work summaries and is read only when needed.
- `handoff.md` is overwritten only for an intentional pause whose volatile state does not fit in `tasks.md`.

Bounded `overview`/`resume-pack` output is capped at 4 KiB and supplies targeted follow-up reads for truncated sections. `restore-check` validates semantic resume fields plus handoff/external-evidence freshness before operational work. PostTool reminders use semantic risk classes, so read-only exploration and plan maintenance do not create false stale pressure while likely evidence and mutations still require timely checkpoints.

There is no `progress.md`. Keep current progress and verification in `tasks.md`; archive completed detail in `history.md` when needed.

## Project Root Resolution

Every hook needs to agree on a single `<project root>` for the storage model above, regardless of which directory inside a workspace a tool call happens to run in. `skills/plan-files/scripts/resolve-project-root.sh` resolves it in this order:

1. Walk upward from the tool call's cwd collecting every ancestor that already has a `.plan-files` file (present, even empty, is enough — no separate marker file). The **farthest** (outermost) match wins. A `.plan-files` can legitimately exist at more than one nesting level (an outer workspace-level plan, plus a leftover one inside a child repo); picking the nearest one would silently resolve to the wrong plan whenever cwd drifts into — or a session simply starts inside — that child repo.
2. Otherwise, fall back to `git rev-parse --show-toplevel`, then walk out through every enclosing git superproject (`--show-superproject-working-tree`), so a cwd inside a registered git submodule resolves to the outermost superproject root, not the submodule's own toplevel.
3. Otherwise, the cwd itself.

### Workspaces that are not a repo themselves

Some workspaces are a plain folder — not a git repository at all — that simply contains several independent repo checkouts as subdirectories, for example:

```text
my-workspace/            # not a git repo
├── service-a/           # its own git repo
├── service-b/           # its own git repo
└── service-c/           # its own git repo
```

`git rev-parse` has no notion of "root" for a folder like this (there is no `.gitmodules` relationship tying the checkouts together), so step 2 above cannot help — only step 1 (an existing `.plan-files`) can name the true root:

- If `my-workspace/.plan-files` already exists (from ordinary prior use — a successful `claim`/`bind` now keeps it populated automatically, see below), everything already works with no extra setup.
- For a brand new such workspace with no `.plan-files` anywhere yet, run `touch .plan-files` at the intended root once, before creating the first task there.

### Opening a session directly inside a child repo

It is common to `cd` into one specific repo (say `service-a/`) and start an agent session there directly, instead of at the workspace root. This is fully supported: as long as the workspace root has a `.plan-files`, the resolver walks upward from `service-a/` and finds it — **the session's plan is stored under the parent workspace root (`my-workspace/tmp/plan-files/...`), not under `service-a/`.** Ordinary work inside `service-a/` (editing files, running commands, git operations) is unaffected; only the plan-tracking storage location is centralized at the workspace root. There is intentionally no mechanism for a nested child repo to "opt out" and keep its own independent plan — every plan for a given workspace lives in one place, by design.

A repo that is genuinely opened standalone — with no workspace folder as an ancestor on disk at all — is unaffected by any of this: step 1 finds nothing above it, so step 2 falls back to that repo's own `git rev-parse --show-toplevel`, and it is treated as its own independent project root.

## Repository Layout

```text
plan-files/
├── skills/
│   └── plan-files/          # Canonical skill source
│       ├── SKILL.md
│       ├── examples.md
│       ├── reference.md
│       ├── references/              # Focused routing, format, operations, evaluation details
│       ├── scripts/                 # Canonical prompt/session routing helper
│       └── templates/
│           ├── tasks.md
│           ├── findings.md
│           ├── decisions.md
│           ├── history.md
│           └── handoff.md
├── .claude/hooks/                         # Claude Code hook scripts
├── .codex/hooks/                          # Codex hook scripts
├── .github/hooks/                         # GitHub Copilot hook scripts
├── CHANGELOG.md
├── CONTRIBUTORS.md
├── LICENSE
└── README.md
```

## Use

Ask the agent to use the `plan-files` skill for any multi-step task. The agent should:

1. Treat `.plan-files` as a candidate, not proof that the conversation owns that task.
2. Compare only candidate Task Identity + Goal with the latest request and classify it as `SAME`, `DIFFERENT`, or `AMBIGUOUS`.
3. When an ownership hook supplies a bind command, bind `SAME` before loading full hot state; ignore `DIFFERENT` without mutating it; ask only for `AMBIGUOUS`.
4. Create a new task folder when a separate complex request needs one, and bind it when the adapter supports ownership.
5. Use `plan_state.py overview/restore-check/phase/item/section` to load only needed state, then use fingerprinted `plan_edit.py` operations for routine structural/section changes. Full Markdown reads and edits remain available for unusual repairs.
6. Checkpoint the Active Item immediately after its evidence becomes true; the checkpoint synchronizes the exact Resume next action.
7. Keep a rolling window of at most 12 hot phase headings: `phase-add` archives the oldest eligible complete phase before adding a thirteenth, and `compact-oldest` performs the same history-first eviction explicitly. Archive writes are locked and journaled for automatic crash recovery. Split only an independent goal; never raw-truncate or raise the ceiling.

Codex, Claude Code, and GitHub Copilot hooks implement this prompt-scoped ownership handshake. An unbound or unidentified session receives no full plan injection and no hard Stop/PostTool enforcement. Future adapters can implement the same generic ownership interface without changing the shared skill contract.

When `.plan-files` is empty, an exact `tmp/plan-files/<task-id>/*.md` path in the user prompt becomes the fallback candidate. As a stronger safety net, PreToolUse auto-claims an unowned session immediately before a recognized mutation that targets Markdown in exactly one existing plan directory. It never silently switches an owned or different pending task, and blocks multi-plan mutations as ambiguous.

A successful `claim`/`bind` keeps `.plan-files` in sync with whichever task the session just became the confirmed owner of — this assumes, as this skill does, that at most one agent works a given project at a time. `.plan-files` remains a convenience default for humans and new sessions, never a decision input: hooks always gate and enforce against the per-session lease under `tmp/plan-files/.sessions/`, never against `.plan-files` directly.

Stop completion is re-evaluated on every invocation, including recursive invocations marked `stop_hook_active=true`. Incomplete or structurally invalid actionable work remains blocked indefinitely; an item, checkpoint, or phase is progress rather than a final-answer boundary, so the agent must continue through every non-settled phase in the plan. A phase with a genuine external dependency must use `blocked (reason)`, while a phase explicitly postponed by the user must use `deferred (reason)`; both are settled and prevent non-actionable recursive Stop loops. Planning/discussion mode, disabled sessions, unowned sessions, and fully settled plans still allow Stop.

Run `make behavioral-eval` for an isolated 12→13 rollover/new-session comparison. It verifies the 4 KiB packet, semantic restore diagnosis, risk-aware reminder behavior, finalization enforcement, session routing, and history-first recovery without mutating the working project.

The canonical skill remains host-neutral. Each ownership-aware hook adapter resolves its own session identity and injects a directly executable bind command, so the skill never hardcodes `/home/...` or requires the agent to discover hook scripts. An absolute command produced by a hook may point through a symlink or to the source tree; both are valid.

The GitHub `user-prompt-transformed.py` file is intentionally adapter-specific: that event must preserve the incoming transformed prompt and return it as `modifiedTransformedPrompt` with candidate context appended. Shared candidate selection and state remain in the canonical skill scripts.

## Install Shape

Install all supported skills and hooks globally from this checkout:

```bash
make install-global
```

`make install-hooks` installs only the hooks. Claude Code merges the planning groups in `.claude/settings.json.sample` into the regular global file `~/.claude/settings.json`; missing groups are added, stale or duplicate planning groups are replaced, and unrelated settings and hook groups are preserved even when they share the same event. Codex merges its sample into `~/.codex/hooks.json`. Copilot's global hook config remains a symlink to its `.sample` file. Hook scripts execute from this checkout, so script-only edits apply globally without reinstalling. Rerun `make install-hooks` after changing a Claude or Codex hook definition, or after moving this checkout. The command is safe to repeat and leaves an already matching Claude settings file unchanged.

Do not rename the `.sample` files back to active project-local config names unless a second local hook layer is intentional. Codex runs every matching global and project hook, so enabling both layers executes both configurations.

## License

MIT License.
