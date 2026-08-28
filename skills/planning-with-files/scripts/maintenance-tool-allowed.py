#!/usr/bin/env python3
"""Classify planning tool calls and extract deterministic plan targets.

Read operations may inspect the project. Plan maintenance is recognized from
the tool input itself rather than from a particular mutation tool name. The
optional extraction modes support prompt candidate routing and mutation-time
session ownership without trusting incidental plan prose.
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
MUTATION_TOOL_TOKENS = {
    "create",
    "delete",
    "edit",
    "insert",
    "move",
    "patch",
    "remove",
    "rename",
    "replace",
    "write",
}
SHELL_TOOL_NAMES = {"bash", "shell", "terminal", "exec", "exec_command", "run_command"}
EVIDENCE_TOOL_TOKENS = {
    "check",
    "click",
    "monitor",
    "poll",
    "screenshot",
    "test",
    "verify",
    "wait",
}
EVIDENCE_COMMAND_RE = re.compile(
    r"(^|\s)(pytest|unittest|make\s+(?:test|check)|npm\s+(?:test|run\s+test)|"
    r"pnpm\s+(?:test|run\s+test)|yarn\s+test|cargo\s+test|go\s+test|"
    r"mvn\s+test|gradle\s+test)(\s|$)",
    re.IGNORECASE,
)
TASK_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
TEXT_PLAN_PATH_RE = re.compile(
    r"(?P<path>(?:[A-Za-z]:)?[^\s\"'`<>|]*?tmp[\\/]+plan-with-files[\\/]"
    r"[A-Za-z0-9._-]+[\\/]+[^\s\"'`<>|]*?\.md)"
    r"(?=$|[\s\"'`<>|)\]},;:])"
)


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


def text_plan_paths(value: object) -> list[str]:
    """Extract exact plan Markdown path tokens from strings in a payload."""
    paths: list[str] = []
    for text in strings(value):
        normalized = text.replace("\\", "/")
        paths.extend(match.group("path") for match in TEXT_PLAN_PATH_RE.finditer(normalized))
    return list(dict.fromkeys(paths))


REQUIRED_PLAN_FILES = {"tasks.md", "findings.md", "decisions.md"}


def plan_id_for_path(path: str, project_root: Path) -> str | None:
    """Resolve a path under this project's plan root and return its task id."""
    cleaned = path.strip().lstrip("([{=:").rstrip(")]},;:")
    candidate = Path(cleaned)
    if not candidate.is_absolute():
        candidate = project_root / candidate
    candidate = Path(os.path.realpath(candidate))
    plan_root = Path(os.path.realpath(project_root / "tmp/plan-with-files"))
    try:
        relative = candidate.relative_to(plan_root)
    except ValueError:
        return None
    if len(relative.parts) < 2 or candidate.suffix.lower() != ".md":
        return None
    task_id = relative.parts[0]
    if not TASK_ID_RE.fullmatch(task_id) or task_id in {".", "..", ".sessions"}:
        return None
    # A task is a recognized mutation target once its tasks.md already
    # exists on disk, OR when this write is itself creating one of the three
    # required plan files for a brand-new task — tasks.md necessarily doesn't
    # exist yet precisely because this very call is the one creating it.
    # Without this second branch, a new plan's very first Write is never
    # auto-claimed (tasks.md can't already exist before it's written), so the
    # session stays unowned until some later edit happens to touch an
    # already-existing file — silently defeating auto-claim for exactly the
    # moment it matters most: task creation.
    if (plan_root / task_id / "tasks.md").is_file():
        return task_id
    if candidate.name.lower() in REQUIRED_PLAN_FILES:
        return task_id
    return None


def plan_ids(paths: list[str], project_root: Path) -> set[str]:
    return {
        task_id
        for path in paths
        if (task_id := plan_id_for_path(path, project_root)) is not None
    }


def shell_has_mutation_intent(tool_input: object) -> bool:
    command = ""
    if isinstance(tool_input, dict):
        command = tool_input.get("command") or tool_input.get("cmd") or ""
    elif isinstance(tool_input, str):
        command = tool_input
    if not isinstance(command, str):
        return False
    if patch_paths(tool_input):
        return True
    mutation_command = re.compile(
        r"(^|[;&|]\s*)(apply_patch|cp|install|mv|rm|touch|truncate|tee|chmod|chown)\b"
        r"|(^|[;&|]\s*)(sed|perl)\b[^\n;&|]*\s-[A-Za-z]*i[A-Za-z]*\b"
        r"|(^|[^<>])>{1,2}(?!=)",
        re.IGNORECASE,
    )
    return mutation_command.search(command) is not None


def is_mutation_tool(tool_name: str, tool_input: object) -> bool:
    simple_name = tool_name.lower().rsplit("__", 1)[-1]
    if simple_name in SHELL_TOOL_NAMES:
        return shell_has_mutation_intent(tool_input)
    tokens = set(re.split(r"[^a-z0-9]+", simple_name))
    return bool(tokens & MUTATION_TOOL_TOKENS)


def payload_tool_input(payload: dict) -> object:
    if "tool_input" in payload:
        return payload.get("tool_input")
    return payload.get("toolInput")


def print_single_plan_id(ids: set[str]) -> int:
    if len(ids) == 1:
        sys.stdout.write(next(iter(ids)))
        return 0
    return 2 if ids else 1


def extract_prompt_plan_id(payload: dict, project_root: Path) -> int:
    prompt_values = [
        payload.get("prompt"),
        payload.get("transformedPrompt"),
        payload.get("transformed_prompt"),
    ]
    paths = text_plan_paths([value for value in prompt_values if isinstance(value, str)])
    return print_single_plan_id(plan_ids(paths, project_root))


def extract_mutation_plan_id(payload: dict, project_root: Path) -> int:
    tool_name = str(payload.get("tool_name") or payload.get("toolName") or "")
    tool_input = payload_tool_input(payload)
    if not is_mutation_tool(tool_name, tool_input):
        return 1
    targets = mutation_targets(tool_input)
    if not targets:
        targets = text_plan_paths(tool_input)
    return print_single_plan_id(plan_ids(targets, project_root))


def tool_class(payload: dict, plan_dir: Path) -> dict[str, object]:
    tool_name = str(payload.get("tool_name") or payload.get("toolName") or "")
    simple_name = tool_name.lower().rsplit("__", 1)[-1]
    tool_input = payload_tool_input(payload)
    mutation = is_mutation_tool(tool_name, tool_input)
    targets = mutation_targets(tool_input)
    plan_maintenance = mutation and (
        (bool(targets) and all(inside(path, plan_dir) for path in targets))
        or references_owned_plan(tool_input, plan_dir)
    )
    if plan_maintenance:
        category = "plan_maintenance"
        semantic_weight = 0
    elif any(simple_name.startswith(prefix) for prefix in READ_TOOL_PREFIXES) or (
        simple_name in SHELL_TOOL_NAMES and bash_is_read_only(tool_input)
    ):
        category = "read_only_exploration"
        semantic_weight = 0
    else:
        command = ""
        if isinstance(tool_input, dict):
            command = tool_input.get("command") or tool_input.get("cmd") or ""
        elif isinstance(tool_input, str):
            command = tool_input
        tokens = set(re.split(r"[^a-z0-9]+", simple_name))
        if (isinstance(command, str) and EVIDENCE_COMMAND_RE.search(command)) or tokens & EVIDENCE_TOOL_TOKENS:
            category = "evidence_likely"
            semantic_weight = 2
        elif mutation:
            category = "operational_mutation"
            semantic_weight = 1
        else:
            category = "unknown"
            semantic_weight = 1
    return {
        "class": category,
        "semantic_weight": semantic_weight,
        "mutation": mutation,
        "plan_maintenance": plan_maintenance,
    }


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


def load_payload() -> dict | None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "tool-class":
        payload = load_payload()
        if payload is None:
            return 1
        plan_dir = Path(os.path.realpath(sys.argv[2]))
        print(json.dumps(tool_class(payload, plan_dir), separators=(",", ":")))
        return 0
    if len(sys.argv) == 3 and sys.argv[1] in {"prompt-plan-id", "mutation-plan-id"}:
        payload = load_payload()
        if payload is None:
            return 1
        project_root = Path(os.path.realpath(sys.argv[2]))
        if sys.argv[1] == "prompt-plan-id":
            return extract_prompt_plan_id(payload, project_root)
        return extract_mutation_plan_id(payload, project_root)

    if len(sys.argv) != 2:
        return 1
    plan_dir = Path(os.path.realpath(sys.argv[1]))
    payload = load_payload()
    if payload is None:
        return 1
    tool_name = str(payload.get("tool_name") or payload.get("toolName") or "").lower()
    simple_name = tool_name.rsplit("__", 1)[-1]
    tool_input = payload_tool_input(payload)

    if any(simple_name.startswith(prefix) for prefix in READ_TOOL_PREFIXES):
        return 0
    if simple_name in SHELL_TOOL_NAMES:
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
