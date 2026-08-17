# Planning with Files

Persistent file-based planning for AI coding agents.

The canonical skill lives in [skills/planning-with-files](./skills/planning-with-files). IDE-specific skill folders should link to that folder instead of copying it. IDE hook scripts stay in the IDE-specific folders because each tool expects hooks in a different location and format. Repository hook configs end in `.sample`; only the global hook layer is enabled by default.

## Current Workflow

For each complex task, the agent uses a default pointer, prompt-scoped routing, and one task directory:

```text
<project root>/
├── .plan-with-files
└── tmp/plan-with-files/
    ├── .sessions/       # private hook-owned routing state
    └── <task-id>/
        ├── tasks.md
        ├── findings.md
        ├── decisions.md
        ├── history.md       # optional cold archive
        └── handoff.md       # optional latest resume snapshot
```

- `tasks.md` tracks task identity, goal, current phase, phases, concise progress, errors, and verification.
- `findings.md` stores research, discoveries, and untrusted external content.
- `decisions.md` stores user decisions, changed direction, superseded choices, and open decision questions.
- `history.md` stores trusted completed-work summaries and is read only when needed.
- `handoff.md` is overwritten only for an intentional pause whose volatile state does not fit in `tasks.md`.

There is no `progress.md`. Keep current progress and verification in `tasks.md`; archive completed detail in `history.md` when needed.

## Repository Layout

```text
planning-with-files/
├── skills/
│   └── planning-with-files/          # Canonical skill source
│       ├── SKILL.md
│       ├── examples.md
│       ├── reference.md
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

Ask the agent to use the `planning-with-files` skill for any multi-step task. The agent should:

1. Treat `.plan-with-files` as a candidate, not proof that the conversation owns that task.
2. Compare only candidate Task Identity + Goal with the latest request and classify it as `SAME`, `DIFFERENT`, or `AMBIGUOUS`.
3. When an ownership hook supplies a bind command, bind `SAME` before loading full hot state; ignore `DIFFERENT` without mutating it; ask only for `AMBIGUOUS`.
4. Create a new task folder when a separate complex request needs one, and bind it when the adapter supports ownership.
5. Re-read `tasks.md` and `decisions.md` before major decisions, and compact cold completed detail instead of raw-truncating it.

Codex, Claude Code, and GitHub Copilot hooks implement this prompt-scoped ownership handshake. An unbound or unidentified session receives no full plan injection and no hard Stop/PostTool enforcement. Future adapters can implement the same generic ownership interface without changing the shared skill contract.

When `.plan-with-files` is empty, an exact `tmp/plan-with-files/<task-id>/*.md` path in the user prompt becomes the fallback candidate. As a stronger safety net, PreToolUse auto-claims an unowned session immediately before a recognized mutation that targets Markdown in exactly one existing plan directory. It never changes `.plan-with-files`, never silently switches an owned or different pending task, and blocks multi-plan mutations as ambiguous.

Stop completion is re-evaluated on every invocation, including recursive invocations marked `stop_hook_active=true`. Incomplete or structurally invalid actionable work remains blocked indefinitely; an item, checkpoint, or phase is progress rather than a final-answer boundary, so the agent must continue through every non-settled phase in the plan. A phase with a genuine external dependency must use `blocked (reason)`, while a phase explicitly postponed by the user must use `deferred (reason)`; both are settled and prevent non-actionable recursive Stop loops. Planning/discussion mode, disabled sessions, unowned sessions, and fully settled plans still allow Stop.

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
