# Suggested Commands

Project discovery:
- `make help` — list Makefile targets.

Planning utilities:
- `bash scripts/check-complete.sh path/to/task_plan.md` — report phase completion/settled status for a plan file.
- `bash scripts/init-session.sh [--template analytics] [project-name]` — legacy/root-file initializer for `task_plan.md`, `findings.md`, `progress.md`; verify current pointer-based workflow before relying on it.

IDE copy synchronization:
- `python scripts/sync-ide-folders.py --dry-run` — preview canonical-to-IDE sync changes.
- `python scripts/sync-ide-folders.py --verify` — check drift; exits nonzero if IDE copies are out of sync.
- `python scripts/sync-ide-folders.py` — apply sync.

Tests/checks found in repo:
- `python -m unittest tests/test_session_catchup.py`
- `python tests/test_path_fix.py`
- `bash tests/test_clear_recovery.sh`

Makefile utilities:
- `make injected-content` — inspect what the old/root `task_plan.md` extraction would inject.
- `make sync-upstream-rebase` / `make sync-upstream-merge` — fetch upstream and rebase/merge current branch.