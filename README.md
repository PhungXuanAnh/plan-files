# Planning with Files

Persistent file-based planning for AI coding agents.

The canonical skill lives in [skills/planning-with-files](./skills/planning-with-files). IDE-specific skill folders should link to that folder instead of copying it. IDE hook scripts stay in the IDE-specific folders because each tool expects hooks in a different location and format.

## Current Workflow

For each complex task, the agent uses a pointer plus one task directory:

```text
<project root>/
├── .plan-with-files
└── tmp/plan-with-files/
    └── <task-id>/
        ├── tasks.md
        ├── findings.md
        └── decisions.md
```

- `tasks.md` tracks goal, current phase, phases, concise progress, errors, and verification.
- `findings.md` stores research, discoveries, and untrusted external content.
- `decisions.md` stores user decisions, changed direction, superseded choices, and open decision questions.

There is no `progress.md`. Progress notes and test results belong in `tasks.md`.

## Repository Layout

```text
planning-with-files/
├── skills/
│   └── planning-with-files/          # Canonical skill source
│       ├── SKILL.md
│       ├── examples.md
│       ├── reference.md
│       └── templates/
│           ├── tasks.md
│           ├── findings.md
│           └── decisions.md
├── .codex/skills/planning-with-files      -> ../../skills/planning-with-files
├── .cursor/skills/planning-with-files     -> ../../skills/planning-with-files
├── .gemini/skills/planning-with-files     -> ../../skills/planning-with-files
├── .continue/skills/planning-with-files   -> ../../skills/planning-with-files
├── .opencode/skills/planning-with-files   -> ../../skills/planning-with-files
├── .claude/hooks/                         # Claude Code hook scripts
├── .codex/hooks/                          # Codex hook scripts
├── .cursor/hooks/                         # Cursor hook scripts
├── .gemini/hooks/                         # Gemini hook scripts
├── .github/hooks/                         # GitHub Copilot hook scripts
├── .kiro/hooks/                           # Kiro hook scripts
├── CHANGELOG.md
├── CONTRIBUTORS.md
├── LICENSE
└── README.md
```

## Use

Ask the agent to use the `planning-with-files` skill for any multi-step task. The agent should:

1. Read `.plan-with-files` if it exists.
2. Read `tasks.md`, `decisions.md`, and `findings.md` from the active task folder.
3. Create a new task folder from the templates when starting a new task.
4. Re-read `tasks.md` and `decisions.md` before major decisions.
5. Compact planning files when they grow past about 250 lines; never raw-truncate them.

## Install Shape

Use the canonical skill folder as the source of truth:

```bash
ln -s ../../skills/planning-with-files .codex/skills/planning-with-files
```

Adjust the relative path for the target IDE folder. Keep hook scripts in the IDE-specific hook directories.

## License

MIT License.
