# Repository installation

- Run `make install` from this checkout to install the global planning skill and hooks for Codex, Claude Code, and GitHub Copilot; it also installs the Kiro skill.
- `make install` is safe to run repeatedly. Existing correct links are preserved, stale links are replaced, and the Claude Code and Codex planning hook groups are merged without duplication.
- Skill files and provider hook scripts execute from this repository, so edits to those files apply to the global installations without rerunning `make install`.
- Claude Code merges `.claude/settings.json.sample` planning groups into the regular `~/.claude/settings.json`, preserving unrelated settings and groups even within the same hook event. Missing planning groups are added and stale or duplicate planning groups are replaced; an already matching file is not rewritten.
- Codex likewise merges its sample into the regular `~/.codex/hooks.json` so unrelated global hooks are preserved. Copilot's global hook configuration is a symlink to this repository's `.sample` file.
- Rerun the corresponding Claude Code or Codex hook installer (or `make install`) after changing its sample hook definitions or moving this checkout. Script-only edits do not require reinstalling.
- If Codex reports that a changed hook definition is untrusted, review it with `/hooks`. Restart sessions that were opened in this repository before a project-local hook config was renamed to `.sample`, so a cached local layer cannot run alongside the global layer.
