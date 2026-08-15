#!/usr/bin/env python3
"""Classify compaction-mode tool calls.

Read operations may inspect the project. Plan maintenance is recognized from
the tool input itself rather than from a particular mutation tool name.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path


READ_TOOL_PREFIXES = (
    "read",
    "get_",
    "find_",
    "list_",
    "search_",
    "inspect_",
    "rg",
    "grep",
    "cat",
)
READ_COMMANDS = {
    "cat",
    "head",
    "tail",
    "grep",
    "rg",
    "ls",
    "pwd",
    "stat",
    "wc",
}
READ_GIT_SUBCOMMANDS = {
    "diff",
    "grep",
    "log",
    "ls-files",
    "ls-tree",
    "rev-parse",
    "show",
    "status",
}


def strings(value: object):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def inside(path: str, plan_dir: Path) -> bool:
    candidate = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
    candidate = os.path.realpath(candidate)
    root = str(plan_dir)
    return candidate == root or candidate.startswith(root + os.sep)


PATH_KEYS = {
    "path",
    "file",
    "file_path",
    "filepath",
    "relative_path",
    "target",
    "target_path",
}
PATH_LIST_KEYS = {"paths", "files", "targets", "target_paths"}


def explicit_paths(value: object) -> list[str]:
    """Return explicit path-like fields recursively, independent of tool name."""
    paths: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            key_lower = str(key).lower()
            if key_lower in PATH_KEYS and isinstance(child, str):
                paths.append(child)
            elif key_lower in PATH_LIST_KEYS and isinstance(child, list):
                paths.extend(item for item in child if isinstance(item, str))
            else:
                paths.extend(explicit_paths(child))
    elif isinstance(value, list):
        for child in value:
            paths.extend(explicit_paths(child))
    return paths


def patch_paths(tool_input: object) -> list[str]:
    """Find apply-patch target markers anywhere in the tool input strings."""
    paths: list[str] = []
    for text in strings(tool_input):
        paths.extend(
            path.strip()
            for path in re.findall(
                r"^\*\*\* (?:Update|Add|Delete) File: (.+)$", text, re.MULTILINE
            )
        )
    return paths


def mutation_targets(tool_input: object) -> list[str]:
    """Collect recognizable writable targets without depending on tool identity."""
    return list(dict.fromkeys(explicit_paths(tool_input) + patch_paths(tool_input)))


def references_owned_plan(tool_input: object, plan_dir: Path) -> bool:
    """Fallback for unknown schemas: require the exact owned plan directory."""
    roots = {str(plan_dir).replace("\\", "/")}
    try:
        relative = os.path.relpath(plan_dir, os.getcwd()).replace("\\", "/")
    except ValueError:
        relative = ""
    if relative and relative != ".":
        roots.add(relative.rstrip("/"))

    for value in strings(tool_input):
        normalized = value.replace("\\", "/")
        for root in roots:
            if normalized == root or root + "/" in normalized:
                return True
    return False


def bash_is_read_only(tool_input: object) -> bool:
    command = ""
    if isinstance(tool_input, dict):
        command = tool_input.get("command") or tool_input.get("cmd") or ""
    elif isinstance(tool_input, str):
        command = tool_input
    if not isinstance(command, str):
        return False
    if any(x in command for x in (";", "&&", "||", ">", "<", "`", "$(", "\n")):
        return False
    try:
        argv = shlex.split(command)
    except ValueError:
        return False
    if not argv:
        return False
    executable = os.path.basename(argv[0])
    if executable in READ_COMMANDS:
        return True
    if executable == "git" and len(argv) >= 2 and argv[1] in READ_GIT_SUBCOMMANDS:
        return True
    return False


def main() -> int:
    if len(sys.argv) != 2:
        return 1
    plan_dir = Path(os.path.realpath(sys.argv[1]))
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 1
    tool_name = str(payload.get("tool_name") or payload.get("toolName") or "").lower()
    simple_name = tool_name.rsplit("__", 1)[-1]
    tool_input = payload.get("tool_input")

    if any(simple_name.startswith(prefix) for prefix in READ_TOOL_PREFIXES):
        return 0
    if simple_name in {"bash", "shell", "terminal", "exec", "exec_command", "run_command"}:
        if bash_is_read_only(tool_input):
            return 0

    targets = mutation_targets(tool_input)
    if targets:
        return 0 if all(inside(path, plan_dir) for path in targets) else 1
    if references_owned_plan(tool_input, plan_dir):
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
