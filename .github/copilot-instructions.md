# Repository installation

- Run `make install` from this checkout to install the global planning skill and hooks for Codex, Claude Code, and GitHub Copilot; it also installs the Kiro skill.
- `make install` is safe to run repeatedly. Existing correct links are preserved, stale links are replaced, and the Codex planning hook groups are merged without duplication.
- Skill files and provider hook scripts execute from this repository, so edits to those files apply to the global installations without rerunning `make install`.
- Claude Code and Copilot hook configuration files are global symlinks to this repository's `.sample` files, so edits to those samples also flow through the links.
- Codex is the exception: `~/.codex/hooks.json` is a merged regular file so unrelated global hooks are preserved. Rerun `make install-hook-codex` (or `make install`) after changing `.codex/hooks.json.sample`, changing hook definitions, or moving this checkout. Script-only edits do not require reinstalling.
- If Codex reports that a changed hook definition is untrusted, review it with `/hooks`. Restart sessions that were opened in this repository before a project-local hook config was renamed to `.sample`, so a cached local layer cannot run alongside the global layer.
