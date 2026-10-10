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


from hook_install import merge_event_groups


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
