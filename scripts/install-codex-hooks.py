#!/usr/bin/env python3
"""Install plan-files Codex hooks while preserving other hooks."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from hook_install import merge_event_groups


def normalize_global_commands(hooks: dict, source: Path) -> None:
    """Convert repo-local hook commands into global commands.

    Global Codex hooks run from arbitrary project roots. They must dispatch to
    this installed source tree, not to `$ROOT/.codex/...` paths.
    """
    source = source.resolve()
    repo_root = source.parent.parent
    script_root = repo_root / ".codex/hooks/plan-files/scripts"
    resolver = repo_root / "skills/plan-files/scripts/resolve-project-root.sh"
    scripts = {
        "UserPromptSubmit": "user-prompt-submit.sh",
        "PostToolUse": "post-tool-use.sh",
        "Stop": "agent-stop.sh",
        "PreToolUse": "pre-tool-use.sh",
        "SessionEnd": "session-end.sh",
    }
    for event, script in scripts.items():
        groups = hooks.get(event)
        if not groups:
            continue
        command = (
            f"ROOT=\"$(bash \"{resolver}\")\" "
            f"&& cd \"$ROOT\" && bash "
            f"\"{script_root / script}\""
        )
        for group in groups:
            for hook in group.get("hooks", []):
                if hook.get("type") == "command":
                    hook["command"] = command


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: install-codex-hooks.py SOURCE DEST", file=sys.stderr)
        return 2
    source, dest = map(Path, sys.argv[1:])
    with source.open() as fh:
        incoming = json.load(fh)
    if dest.is_symlink() and dest.resolve() != source.resolve():
        dest = dest.resolve()  # Preserve user-managed configuration links.
    if dest.exists():
        with dest.open() as fh:
            current = json.load(fh)
    else:
        current = {"hooks": {}}

    normalize_global_commands(incoming.get("hooks", {}), source)
    hooks = current.setdefault("hooks", {})
    for event, value in incoming.get("hooks", {}).items():
        hooks[event] = merge_event_groups(hooks.get(event), value, event, source)

    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    with tmp.open("w") as fh:
        json.dump(current, fh, indent=2)
        fh.write("\n")
    tmp.replace(dest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
