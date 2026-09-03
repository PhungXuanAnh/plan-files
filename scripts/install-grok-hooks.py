#!/usr/bin/env python3
"""Install the native plan-files Grok hook into an explicit GROK_HOME."""

from __future__ import annotations

import copy
import json
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any


MANAGER = "plan-files-grok-installer"
MARKER = "_planFilesHook"
EVENT_SCRIPTS = {
    "UserPromptSubmit": "user-prompt-submit.sh",
    "PreToolUse": "pre-tool-use.sh",
    "PostToolUse": "post-tool-use.sh",
    "Stop": "agent-stop.sh",
}


def load_object(path: Path, label: str) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {label} {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} must contain a JSON object: {path}")
    return value


def is_owned(value: dict[str, Any]) -> bool:
    marker = value.get(MARKER)
    return isinstance(marker, dict) and marker.get("managedBy") == MANAGER


def normalize(source: Path, incoming: dict[str, Any]) -> dict[str, Any]:
    if not is_owned(incoming):
        raise ValueError(f"hook sample lacks the {MANAGER!r} ownership marker: {source}")
    hooks = incoming.get("hooks")
    if not isinstance(hooks, dict):
        raise ValueError(f"hook sample has no JSON object at 'hooks': {source}")

    repo_root = source.resolve().parents[2]
    script_root = repo_root / ".grok/hooks/plan-files/scripts"
    resolver = repo_root / "skills/plan-files/scripts/resolve-project-root.sh"
    result = copy.deepcopy(incoming)
    result[MARKER]["source"] = str(repo_root)

    for event, script in EVENT_SCRIPTS.items():
        groups = result["hooks"].get(event)
        if not isinstance(groups, list) or not groups:
            raise ValueError(f"hook sample event '{event}' must be a non-empty array: {source}")
        command = (
            f'ROOT="$(bash "{resolver}")" && cd "$ROOT" '
            f'&& bash "{script_root / script}"'
        )
        command_hooks = 0
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError(f"hook sample event '{event}' has an invalid group: {source}")
            for hook in group["hooks"]:
                if isinstance(hook, dict) and hook.get("type") == "command":
                    hook["command"] = command
                    command_hooks += 1
        if command_hooks == 0:
            raise ValueError(f"hook sample event '{event}' has no command hook: {source}")
    return result


def write_atomically(dest: Path, value: dict[str, Any], mode: int | None) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=dest.parent,
            prefix=f".{dest.name}.",
            delete=False,
        ) as handle:
            temporary_name = handle.name
            json.dump(value, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        if mode is not None:
            os.chmod(temporary_name, mode)
        os.replace(temporary_name, dest)
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: install-grok-hooks.py SOURCE DEST", file=sys.stderr)
        return 2
    source, dest = map(Path, sys.argv[1:])
    try:
        installed = normalize(source, load_object(source, "hook sample"))
        mode = None
        if dest.exists() or dest.is_symlink():
            if dest.is_symlink() or not dest.is_file():
                raise ValueError(f"refusing to overwrite non-regular hook file: {dest}")
            current = load_object(dest, "existing hook file")
            if not is_owned(current):
                raise ValueError(f"refusing to overwrite unrelated hook file: {dest}")
            if current == installed:
                print(f"  already configured: {dest}")
                return 0
            mode = stat.S_IMODE(dest.stat().st_mode)
        write_atomically(dest, installed, mode)
        print(f"  installed: {dest}")
        return 0
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
