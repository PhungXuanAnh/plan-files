# Planning with Files

Persistent file-based planning for AI coding agents.

The canonical skill lives in [skills/plan-files](./skills/plan-files). IDE-specific skill folders should link to that folder instead of copying it. Provider hook paths stay in the IDE-specific folders because each tool expects hooks in a different location and format, but duplicated behavior lives in canonical shared shell scripts and the provider files remain thin launch shims. Repository hook configs end in `.sample`; only the global hook layer is enabled by default.

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

Bounded `overview`/`resume-pack` output is capped at 4 KiB and supplies targeted follow-up reads for truncated sections. `restore-check` validates semantic resume fields plus handoff/external-evidence freshness before operational work. PostTool reminders use semantic risk classes, so read-only exploration and plan maintenance do not create false stale pressure while likely evidence and mutations still require timely checkpoints. Early validation also catches malformed legacy plans, missing profiles and inconsistent phase status before operational tools. PostTool repeats unresolved repair warnings and a compact reminder when actionable work would block Stop, while full context remains debounced. Short planning commands run in the foreground; background builds/tests remain supported. Hook messages name the absolute path of every script and document they ask for, so the agent never guesses an install location or searches for a skill script, and the ownership message offers every routing verb its gate accepts, including `discuss` for a question that implements nothing. Operational work on an owned plan also requires the skill to have been read once in the session. See the [early enforcement matrix](skills/plan-files/references/routing-and-hooks.md#early-enforcement-and-stop-audit).

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
│       ├── scripts/                 # Canonical planning tools and shared shell hook cores
│       └── templates/
│           ├── tasks.md
│           ├── findings.md
│           ├── decisions.md
│           ├── history.md
│           └── handoff.md
├── .claude/hooks/                         # Claude Code hook scripts
├── .codex/hooks/                          # Codex hook scripts
├── .grok/hooks/                           # Native Grok Build hook sample + adapter scripts
├── .github/hooks/                         # GitHub Copilot hook scripts
├── CHANGELOG.md
├── CONTRIBUTORS.md
├── LICENSE
└── README.md
```

## Hook Architecture: Abstract Core and Provider Adapters

The hook system follows an Abstract Core + Adapter architecture. These are architectural roles independent of implementation language. Bash is the current implementation, not a permanent constraint; the core and adapters may be migrated to Python when the complexity and maintenance benefits justify it.

```text
Codex / Claude / Copilot / Grok event
             │ provider-specific JSON, fields, session id
             ▼
      Provider Adapter
             │ normalized hook request
             ▼
       Abstract Hook Core
             │ provider-neutral hook result
             ▼
      Provider Adapter
             │ provider-specific output envelope
             ▼
             Agent
```

The abstract core owns all planning behavior: project-root and session resolution, restore and maintenance gates, phase/item state, semantic risk, checkpoint guidance, Stop finalization, and telemetry policy. In the Bash implementation this role is fulfilled by the canonical `hook-*.sh` scripts and their shared helpers under `skills/plan-files/scripts/`.

A provider adapter owns only the protocol boundary. It converts the provider's event name, input fields, session identity, and capabilities into the logical core request, invokes the canonical core, then converts the provider-neutral result into the exact JSON envelope expected by Codex, Claude Code, GitHub Copilot, or Grok Build. The scripts under `.codex/hooks/`, `.claude/hooks/`, `.github/hooks/`, and `.grok/hooks/` fulfill this adapter role and should remain small.

To prevent duplication:

- Never copy planning decisions, parsing rules, reminder text, Stop policy, or telemetry policy into a provider directory.
- If behavior is needed by two providers, move it into a canonical core/helper and keep only conversion at the provider boundary.
- A provider-only event may remain local, but it must reuse canonical candidate, session, and plan-state operations wherever those semantics overlap.
- Test shared behavior once at the core level and test each adapter only for input normalization, capability selection, and output-envelope rendering.
- Adding a provider means adding an adapter, not forking an existing provider's policy implementation.

Porting from Bash to Python is appropriate when JSON/protocol handling, state transitions, error handling, locking, testing, or the expected volume of changes has become difficult to maintain safely in shell. Treat the migration as an architectural change, not a line-by-line translation:

- Migrate a complete shared responsibility or the complete hook runtime, including its tests and all provider entrypoints that consume it.
- Preserve one normalized `HookRequest`/`HookResult` contract and the existing observable provider behavior.
- Remove the superseded Bash policy after the new implementation passes parity tests; do not maintain the same policy in both Bash and Python.
- Keep stable provider hook paths where possible so installed configurations do not break.

In an object-oriented Python implementation, preserve the same boundary: one `AbstractHook`/`HookCore` accepts a normalized `HookRequest` and returns a normalized `HookResult`; `CodexAdapter`, `ClaudeAdapter`, `CopilotAdapter`, and `GrokAdapter` classes perform `from_provider_input(...)` and `to_provider_output(...)`. Provider subclasses must not override or duplicate planning policy.

## Use

Ask the agent to use the `plan-files` skill for any multi-step task. The agent should:

1. Treat `.plan-files` as a candidate, not proof that the conversation owns that task.
2. Compare only candidate Task Identity + Goal with the latest request and classify it as `SAME`, `DIFFERENT`, or `AMBIGUOUS`.
3. Run the supplied `bind` for `SAME` before loading state, `release` for a genuinely `DIFFERENT` goal, or `clarify` then ask for `AMBIGUOUS`. Clarification preserves the candidate. Explicitly implementing the same research plan after answers is SAME; reconcile its authorized scope before execution.
4. Create a new task folder when a separate complex request needs one, and bind it when the adapter supports ownership.
5. Use `plan_state.py overview/restore-check/phase/item/section` to load only needed state, then use fingerprinted `plan_edit.py` operations for routine structural/section changes. Full Markdown reads and edits remain available for unusual repairs.
6. Checkpoint the Active Item immediately after its evidence becomes true; the checkpoint synchronizes the exact Resume next action.
7. Keep a rolling window of at most 12 hot phase headings: `phase-add` archives the oldest eligible complete phase before adding a thirteenth, and `compact-oldest` performs the same history-first eviction explicitly. Archive writes are locked and journaled for automatic crash recovery. Split only an independent goal; never raw-truncate or raise the ceiling.

Codex, Claude Code, GitHub Copilot, and Grok Build implement this prompt-scoped handshake through shared cores under `skills/plan-files/scripts/`. Provider wrappers translate event arguments, session identity, and output envelopes. All four repeat the same action-first recovery contract at PreTool and pending Stop. An unidentified session or one without a candidate receives no full plan injection or Stop enforcement. A pending candidate must be resolved before work; clarification wait permits only questions and exact routing commands. A future provider reuses the same core.

Each new user prompt suspends the old lease; a matching pointer does not remove the need to bind. Stop automatically finishes a fully complete lease, while preserving paused work. `release` rejects a candidate and is not routine cleanup. For a user-requested discussion-only turn about an owned plan/workflow, use the supplied bind command with verb `discuss`: reads, questions, and plan repair remain allowed, Stop may yield, and execution stays gated until the next prompt is bound. Neither discussion nor clarification marks unfinished phases complete.

When `.plan-files` is empty, an exact `tmp/plan-files/<task-id>/*.md` path in the user prompt becomes the fallback candidate. As a stronger safety net, PreToolUse auto-claims an unowned session immediately before a recognized mutation that targets Markdown in exactly one existing plan directory. It never silently switches an owned or different pending task, and blocks multi-plan mutations as ambiguous.

A successful `claim`/`bind` keeps `.plan-files` in sync with whichever task the session just became the confirmed owner of — this assumes, as this skill does, that at most one agent works a given project at a time. `.plan-files` remains a convenience default for humans and new sessions, never a decision input: hooks always gate and enforce against the per-session lease under `tmp/plan-files/.sessions/`, never against `.plan-files` directly.

Stop completion is re-evaluated on every invocation, including recursive invocations marked `stop_hook_active=true`. Incomplete or structurally invalid actionable work remains blocked indefinitely; an item, checkpoint, or phase is progress rather than a final-answer boundary, so the agent must continue through every non-settled phase in the plan. A phase with a genuine external dependency must use `blocked (reason)`, while a phase explicitly postponed by the user must use `deferred (reason)`; both are settled and prevent non-actionable recursive Stop loops. Planning/discussion mode, disabled sessions, unowned sessions, and fully settled plans still allow Stop.

Run `make behavioral-eval` for an isolated 12→13 rollover/new-session comparison. It verifies the 4 KiB packet, semantic restore diagnosis, risk-aware reminder behavior, finalization enforcement, session routing, and history-first recovery without mutating the working project.

The canonical skill remains host-neutral. Each ownership-aware hook adapter resolves its own session identity and injects a directly executable bind command, so the skill never hardcodes `/home/...` or requires the agent to discover hook scripts. An absolute command produced by a hook may point through a symlink or to the source tree; both are valid.

GitHub's `user-prompt-transformed.py` remains a provider-specific envelope adapter: it preserves the incoming transformed prompt and returns it as `modifiedTransformedPrompt` with candidate context appended. Candidate selection and session state remain provider-neutral through the canonical scripts it calls.

Grok's native adapter follows the [official hook contract](https://docs.x.ai/build/features/hooks): it validates camelCase `sessionId` against `GROK_SESSION_ID`, maps the shared PreToolUse block verdict to Grok's `deny`, and gates Stop only when `reason == "end_turn"`. An allowing `UserPromptSubmit` cannot inject context, so the next denied PreToolUse or pending Stop includes the bounded Task Identity, Goal, and exact bind/release commands. PostToolUse always performs auto-claim/cache side effects; it also emits standard `additionalContext` for Grok releases that deliver it, but correctness does not depend on that channel. Grok forcibly ends a turn after eight Stop continuations, so an unfinished lease remains resumable on the next prompt.

Official Grok truncates PreTool denial reasons to 256 Unicode characters before they reach the model. The Grok adapter advertises that transport limit to the shared core: long reasons are written intact to a private feedback file, and the short deny names its path. Any tool call containing that current feedback path anywhere in its arguments is allowed, regardless of tool name or other arguments. Other calls still follow normal gates. Feedback access itself does not bind/release a plan; prompt and ownership transitions invalidate the file. No Grok source change, rebuild, or replacement of the official executable is needed. See [routing and hook semantics](skills/plan-files/references/routing-and-hooks.md).

## Install Shape

Install all supported skills and hooks globally from this checkout:

```bash
make install-global
```

`make install-hooks` installs only the hooks. Claude Code merges the planning groups in `.claude/settings.json.sample` into the regular global file `~/.claude/settings.json`; missing groups are added, stale or duplicate planning groups are replaced, and unrelated settings and hook groups are preserved even when they share the same event. Codex merges its sample into `~/.codex/hooks.json`. Copilot's global hook config remains a symlink to its `.sample` file. Grok installs an owned native file at `${GROK_HOME:-$HOME/.grok}/hooks/plan-files.json` and leaves every sibling JSON hook untouched. Hook scripts execute from this checkout, so script-only edits apply globally without reinstalling. Rerun the relevant installer after changing a sample definition or moving this checkout.

Install only the native Grok hook into the normal global home:

```bash
make install-hook-grok
```

Install the Grok skill and hook together, or target an isolated runtime explicitly:

```bash
make install-grok
GROK_HOME=/path/to/isolated/grok-home make install-hook-grok
```

The Grok installer writes atomically, is byte-idempotent, and refuses to overwrite an unrelated existing `plan-files.json`. `.grok/hooks/plan-files.json.sample` is the source-controlled project example; it deliberately does not end in `.json`, so opening this checkout cannot register a duplicate project layer. Rename/copy it to `.json` only when a trusted project-local layer is intentional, then grant Grok project hook trust.

Do not rename the `.sample` files back to active project-local config names unless a second local hook layer is intentional. Codex and Grok run every matching global and project hook, so enabling both layers executes both configurations.

## License

MIT License.
