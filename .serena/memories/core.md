# Core

Planning-with-files is an Agent Skills/plugin distribution repo for Manus-style file-based planning.

Root entry points:
- `README.md` explains the product, supported assistants, release highlights, and repository layout.
- Canonical skill: `skills/planning-with-files/SKILL.md` with templates in `skills/planning-with-files/templates/` and references in `skills/planning-with-files/{examples.md,reference.md}`.
- Root templates: `templates/task_plan.md`, `templates/findings.md`, `templates/progress.md`, plus analytics variants.
- Plugin commands: `commands/plan.md`, `commands/status.md`, `commands/start.md`.
- Claude plugin metadata: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.
- GitHub Copilot hooks: `.github/hooks/planning-with-files.json` and `.github/hooks/scripts/*.sh`.
- Multi-IDE packaged copies live under `.codex/`, `.cursor/`, `.gemini/`, `.opencode/`, `.continue/`, `.factory/`, `.mastracode/`, `.codebuddy/`, `.pi/`, `.kiro/`.

Core behavior:
- Skill teaches agents to persist work state on disk instead of relying on volatile context/TodoWrite.
- Active task layout is pointer-based: `.plan-with-files` contains one task id; actual files live under `tmp/plan-with-files/<task-id>/`.
- Per task files: `task_plan.md` for goal/current phase/phases/decisions/errors, `findings.md` for research/discoveries, `progress.md` for session log/test/errors.
- Hooks no-op when there is no valid pointer/plan. Valid task ids are only letters, digits, `.`, `_`, `-`; no spaces, slashes, empty, `.`, or `..`.

Related memories:
- Tech stack and packaging: `mem:tech_stack`
- Commands: `mem:suggested_commands`
- Plan/hook conventions: `mem:conventions`
- Completion checks: `mem:task_completion`