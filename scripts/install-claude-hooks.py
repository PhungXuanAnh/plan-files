#!/usr/bin/env python3
"""Merge planning hooks into Claude Code's global settings file."""

from __future__ import annotations

import copy
import json
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any


PLANNING_COMMAND_MARKER = "plan-files/scripts/"


def load_object(path: Path, label: str) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {label} {path}: {error}") from error

    if not isinstance(value, dict):
        raise ValueError(f"{label} must contain a JSON object: {path}")
    return value


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


def is_planning_group(group: Any) -> bool:
    if not isinstance(group, dict):
        return False
    hooks = group.get("hooks")
    if not isinstance(hooks, list):
        return False
    return any(
        isinstance(hook, dict)
        and isinstance(hook.get("command"), str)
        and PLANNING_COMMAND_MARKER in hook["command"]
        for hook in hooks
    )


def merge_event_groups(
    existing: Any, incoming: Any, event: str, source: Path
) -> list[Any]:
    if not isinstance(incoming, list) or not incoming:
        raise ValueError(f"hook sample event '{event}' must be a non-empty array: {source}")
    if not all(is_planning_group(group) for group in incoming):
        raise ValueError(
            f"hook sample event '{event}' contains a non-planning group: {source}"
        )
    if existing is None:
        return copy.deepcopy(incoming)
    if not isinstance(existing, list):
        raise ValueError(f"global settings hook event '{event}' is not an array")

    planning_indexes = [
        index for index, group in enumerate(existing) if is_planning_group(group)
    ]
    if not planning_indexes:
        return copy.deepcopy(existing) + copy.deepcopy(incoming)

    first_planning_index = planning_indexes[0]
    insertion_index = sum(
        not is_planning_group(group) for group in existing[:first_planning_index]
    )
    result = [group for group in existing if not is_planning_group(group)]
    result[insertion_index:insertion_index] = copy.deepcopy(incoming)
    return result


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: install-claude-hooks.py SOURCE DEST", file=sys.stderr)
        return 2

    source, dest = map(Path, sys.argv[1:])
    try:
        incoming = load_object(source, "hook sample")
        incoming_hooks = incoming.get("hooks")
        if not isinstance(incoming_hooks, dict):
            raise ValueError(f"hook sample has no JSON object at 'hooks': {source}")

        was_symlink = dest.is_symlink()
        if was_symlink:
            if dest.resolve() != source.resolve():
                raise ValueError(
                    f"refusing to replace unrelated settings symlink: {dest}"
                )
            current = load_object(dest, "legacy global settings")
        elif dest.exists():
            if not dest.is_file():
                raise ValueError(f"global settings is not a regular file: {dest}")
            current = load_object(dest, "global settings")
        else:
            current = {}

        merged = copy.deepcopy(current)
        current_hooks = merged.setdefault("hooks", {})
        if not isinstance(current_hooks, dict):
            raise ValueError(f"global settings has a non-object 'hooks' value: {dest}")
        for event, definitions in incoming_hooks.items():
            current_hooks[event] = merge_event_groups(
                current_hooks.get(event), definitions, event, source
            )

        if not was_symlink and dest.exists() and merged == current:
            print(f"  already configured: {dest}")
            return 0

        mode = stat.S_IMODE(dest.stat().st_mode) if dest.exists() else None
        write_atomically(dest, merged, mode)
        action = "detached and merged" if was_symlink else "merged"
        print(f"  {action}: {dest}")
        return 0
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
