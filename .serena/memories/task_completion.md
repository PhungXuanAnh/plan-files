# Task Completion

For documentation/skill/template changes:
- Run `python scripts/sync-ide-folders.py --dry-run` to inspect copy drift.
- Run `python scripts/sync-ide-folders.py` if canonical changes need propagation.
- Run `python scripts/sync-ide-folders.py --verify` before done.

For session-catchup/path changes:
- Run `python -m unittest tests/test_session_catchup.py`.
- Run `python tests/test_path_fix.py`.
- Run `bash tests/test_clear_recovery.sh` if behavior affects /clear recovery or planning-file injection.

For hook/parser changes:
- Exercise relevant `.github/hooks/scripts/*.sh` logic with representative `task_plan.md` states: no pointer, invalid pointer, missing dir, valid active plan, complete phase with unchecked work, stale Current Phase, deferred phase with/without reason, non-Phase unchecked work.

Always check `git diff` before final response. Do not push or submit PR comments unless the user explicitly requests it.