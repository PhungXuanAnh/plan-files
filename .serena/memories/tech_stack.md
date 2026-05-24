# Tech Stack

- Primary artifacts are Markdown Agent Skills, templates, docs, and JSON manifests.
- Bash is the active Serena language and the main hook/runtime script language.
- PowerShell equivalents exist in packaged skill variants for Windows support.
- Python is used for utility/testing scripts: `scripts/session-catchup.py`, `scripts/sync-ide-folders.py`, `tests/test_session_catchup.py`, `tests/test_path_fix.py`.
- No app runtime/server/package manager is central to the repo. It is a distribution/tooling repo, not a web app/library package.
- Hook scripts are designed to be pure Bash where possible; GitHub Copilot hook scripts explicitly avoid Python dependencies for JSON escaping and run on Bash 4+.
- `scripts/sync-ide-folders.py` syncs canonical files from `skills/planning-with-files/` to IDE-specific folders. `.kiro` is intentionally skipped/maintained separately because it has a custom Agent Skill layout.
- Release metadata may lag across surfaces; README current version was v2.29.0 while `.claude-plugin/plugin.json` observed as 2.23.0.