#!/usr/bin/env python3
"""Install the plan-files Antigravity CLI (agy) hook into agy's shared hooks.json.

Usage: install-agy-hooks.py SOURCE DEST

agy's hooks.json maps hook names to their events. This installer owns the
`plan-files` name, replaces that entry whole, and leaves every other name alone.
"""

from __future__ import annotations

import copy
import json
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any

HOOK_NAME = "plan-files"
ADAPTER = ".agy/hooks/plan-files/scripts/agy_adapter.py"


def load_object(path: Path, label: str) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8-sig") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {label} {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} must contain a JSON object: {path}")
    return value


def handlers(events: dict[str, Any]) -> list[dict[str, Any]]:
    """Every command handler, whether listed flat or inside a matcher group."""
    found = []
    for entries in events.values():
        for entry in entries:
            if "hooks" in entry:
                found.extend(entry["hooks"])
            else:
                found.append(entry)
    return found


def installed_entry(source: Path) -> dict[str, Any]:
    entry = load_object(source, "hook sample").get(HOOK_NAME)
    if not isinstance(entry, dict) or not entry:
        raise ValueError(f"hook sample has no '{HOOK_NAME}' entry: {source}")
    adapter = source.resolve().parents[2] / ADAPTER
    result = copy.deepcopy(entry)
    for handler in handlers(result):
        command = handler.get("command", "")
        if ADAPTER not in command:
            raise ValueError(f"hook sample command does not run {ADAPTER}: {command}")
        handler["command"] = command.replace(ADAPTER, f'"{adapter}"')
    return result


def write_atomically(dest: Path, value: dict[str, Any], mode: int) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=dest.parent, prefix=f".{dest.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.chmod(temporary, mode)
        os.replace(temporary, dest)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    source, dest = map(Path, sys.argv[1:])
    # Keep a symlinked hooks.json a symlink by writing its target.
    dest = dest.resolve()
    try:
        entry = installed_entry(source)
        current = {}
        mode = 0o644
        if dest.exists():
            current = load_object(dest, "existing hooks file")
            mode = stat.S_IMODE(dest.stat().st_mode)
        if current.get(HOOK_NAME) == entry:
            print(f"  already configured: {dest}")
            return 0
        write_atomically(dest, {**current, HOOK_NAME: entry}, mode)
        print(f"  installed: {dest} ({HOOK_NAME})")
        return 0
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
