"""Shared idempotent merging of planning hook groups; preserve unrelated hooks."""
from __future__ import annotations

import copy
from pathlib import Path
from typing import Any

PLANNING_COMMAND_MARKER = "plan-files/scripts/"


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
