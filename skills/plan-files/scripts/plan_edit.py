#!/usr/bin/env python3
"""Context-safe structural and section edits for plan-files Markdown."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Iterable

import plan_checkpoint
from plan_state import (
    CURRENT_PHASE_BYTE_LIMIT,
    CURRENT_PHASE_ITEM_LIMIT,
    FILE_BUDGETS,
    ITEM_ID_RE,
    PHASE_RE,
    PLACEHOLDER_EVIDENCE,
    restore_payload,
    SETTLED,
    TASKS_ITEM_LIMIT,
    TASKS_PHASE_LIMIT,
    budget_payload,
    context_payload,
    file_fingerprint,
    handoff_metadata,
    parse_plan,
    resolve_plan_argument,
)

PHASE_HIGH_WATER_RE = re.compile(r"<!-- Phase ID high-water:\s*(\d+) -->")
TRANSACTION_FILE = ".plan-edit-transaction.json"
LOCK_FILE = ".plan-edit.lock"
TRANSACTION_MAX_BYTES = 64 * 1024


class EditError(RuntimeError):
    pass


def _fsync_dir(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_write(path: Path, text: str) -> None:
    mode = path.stat().st_mode if path.exists() else 0o600
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
        _fsync_dir(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def _plan_lock(plan: Path):
    lock = plan.parent / LOCK_FILE
    descriptor = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        with os.fdopen(descriptor, "r+") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            yield
    finally:
        pass


def _transaction_path(plan: Path) -> Path:
    return plan.parent / TRANSACTION_FILE


def _write_transaction(plan: Path, payload: dict[str, object]) -> None:
    path = _transaction_path(plan)
    if path.exists():
        raise EditError(f"unfinished plan transaction exists: {path}; recover it before another edit")
    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    if len(text.encode("utf-8")) > TRANSACTION_MAX_BYTES:
        raise EditError(f"transaction journal exceeds {TRANSACTION_MAX_BYTES} bytes")
    _atomic_write(path, text)


def _clear_transaction(plan: Path) -> None:
    path = _transaction_path(plan)
    if path.exists():
        path.unlink()
        _fsync_dir(path.parent)


def _fault_after(boundary: str) -> None:
    if os.environ.get("PWF_PLAN_EDIT_FAIL_AFTER") == boundary:
        raise EditError(f"injected failure after {boundary}")


def _recover_transaction(plan: Path) -> dict[str, object] | None:
    path = _transaction_path(plan)
    if not path.is_file():
        return None
    raw = path.read_bytes()
    if len(raw) > TRANSACTION_MAX_BYTES:
        raise EditError(f"transaction journal exceeds {TRANSACTION_MAX_BYTES} bytes")
    try:
        journal = json.loads(raw)
    except json.JSONDecodeError as error:
        raise EditError(f"invalid transaction journal: {error}") from error
    required = {
        "schema_version",
        "transaction_id",
        "operation",
        "plan",
        "history",
        "tasks_old_fingerprint",
        "tasks_fingerprint",
        "tasks_candidate",
        "history_old_fingerprint",
        "history_fingerprint",
        "history_heading",
        "history_marker",
        "history_entry",
    }
    if not isinstance(journal, dict) or not required.issubset(journal) or journal["schema_version"] != 1:
        raise EditError("invalid or unsupported transaction journal schema")
    if journal["plan"] != plan.name or journal["history"] != "history.md":
        raise EditError("transaction journal targets do not match the owned plan directory")
    string_fields = required - {"schema_version"}
    if any(not isinstance(journal[field], str) for field in string_fields):
        raise EditError("transaction journal fields have invalid types")

    tasks_candidate = journal["tasks_candidate"]
    tasks_target = hashlib.sha256(tasks_candidate.encode("utf-8")).hexdigest()
    if tasks_target != journal["tasks_fingerprint"]:
        raise EditError("transaction tasks candidate fingerprint mismatch")
    tasks_current = file_fingerprint(plan)
    if tasks_current not in {journal["tasks_old_fingerprint"], tasks_target}:
        raise EditError("transaction recovery conflict: tasks.md matches neither old nor intended state")

    history = plan.parent / "history.md"
    history_current = file_fingerprint(history) if history.is_file() else "missing"
    history_target = journal["history_fingerprint"]
    if history_current not in {journal["history_old_fingerprint"], history_target}:
        raise EditError("transaction recovery conflict: history.md matches neither old nor intended state")
    history_candidate = history.read_text(encoding="utf-8") if history.is_file() else HISTORY_TEMPLATE
    if history_current != history_target:
        history_candidate = _history_with_entry(
            history_candidate,
            journal["history_heading"],
            journal["history_marker"],
            journal["history_entry"],
        )
        if hashlib.sha256(history_candidate.encode("utf-8")).hexdigest() != history_target:
            raise EditError("transaction recovery could not reproduce intended history.md")

    recovered_boundaries: list[str] = []
    if history_current != history_target:
        _atomic_write(history, history_candidate)
        recovered_boundaries.append("history")
    if tasks_current != tasks_target:
        _atomic_write(plan, tasks_candidate)
        recovered_boundaries.append("tasks")
    _validated_state(plan)
    _clear_transaction(plan)
    return {
        "transaction_id": journal["transaction_id"],
        "operation": journal["operation"],
        "recovered_boundaries": recovered_boundaries,
        "tasks_fingerprint": tasks_target,
        "history_fingerprint": history_target,
    }


def _transactional_archive_write(
    *,
    plan: Path,
    operation: str,
    plan_old_fingerprint: str,
    tasks_candidate: str,
    history_path: Path,
    history_old_fingerprint: str,
    history_candidate: str,
    history_heading: str,
    marker: str,
    archive_entry: str,
) -> str:
    tasks_fingerprint = hashlib.sha256(tasks_candidate.encode("utf-8")).hexdigest()
    history_fingerprint = hashlib.sha256(history_candidate.encode("utf-8")).hexdigest()
    transaction_id = hashlib.sha256(
        f"{operation}\n{plan_old_fingerprint}\n{tasks_fingerprint}\n{history_fingerprint}".encode()
    ).hexdigest()[:16]
    journal = {
        "schema_version": 1,
        "transaction_id": transaction_id,
        "operation": operation,
        "plan": plan.name,
        "history": history_path.name,
        "tasks_old_fingerprint": plan_old_fingerprint,
        "tasks_fingerprint": tasks_fingerprint,
        "tasks_candidate": tasks_candidate,
        "history_old_fingerprint": history_old_fingerprint,
        "history_fingerprint": history_fingerprint,
        "history_heading": history_heading,
        "history_marker": marker,
        "history_entry": archive_entry,
    }
    _write_transaction(plan, journal)
    _fault_after("journal")
    if not history_path.is_file() or file_fingerprint(history_path) != history_fingerprint:
        _atomic_write(history_path, history_candidate)
    _fault_after("history")
    _atomic_write(plan, tasks_candidate)
    _fault_after("tasks")
    _validated_state(plan)
    _clear_transaction(plan)
    return transaction_id


def _text(lines: list[str]) -> str:
    return "\n".join(lines).rstrip() + "\n"


def _check_expected(path: Path, expected: str) -> str:
    actual = file_fingerprint(path)
    if actual != expected:
        # A 16-hex value is almost always the semantic progress hash that
        # plan_checkpoint.py and the read commands also call "fingerprint".
        # Saying only "stale" sends the caller hunting for a concurrent writer.
        if re.fullmatch(r"[0-9a-f]{16}", expected or ""):
            raise EditError(
                f"--expected-fingerprint got a 16-hex progress fingerprint, not a file fingerprint. "
                f"Pass the 'file_fingerprint' field (full SHA-256) instead. For {path} it is {actual}"
            )
        raise EditError(f"stale fingerprint for {path}: expected {expected}, actual {actual}")
    return actual


def _phase_section_end(lines: list[str]) -> int:
    headings = [index for index, line in enumerate(lines) if line.strip() == "## Phases"]
    if len(headings) != 1:
        raise EditError("expected exactly one ## Phases section")
    return next((index for index in range(headings[0] + 1, len(lines)) if lines[index].startswith("## ")), len(lines))


def _phase_blocks(lines: list[str], state) -> tuple[int, int, list[str], list[tuple[int, list[str]]]]:
    heading = next((index for index, line in enumerate(lines) if line.strip() == "## Phases"), None)
    if heading is None:
        raise EditError("expected ## Phases")
    end = _phase_section_end(lines)
    first = state.phases[0].heading_index if state.phases else end
    preamble = lines[heading + 1 : first]
    blocks = [(phase.num, lines[phase.heading_index : phase.end_index]) for phase in state.phases]
    return heading, end, preamble, blocks


def _normalize_block(block: list[str]) -> list[str]:
    result = list(block)
    while result and not result[0].strip():
        result.pop(0)
    while result and not result[-1].strip():
        result.pop()
    return result


def _replace_phase_blocks(
    lines: list[str], state, blocks: list[tuple[int | None, list[str]]]
) -> list[str]:
    heading, end, preamble, _ = _phase_blocks(lines, state)
    section = list(lines[: heading + 1])
    clean_preamble = list(preamble)
    while clean_preamble and not clean_preamble[-1].strip():
        clean_preamble.pop()
    if clean_preamble:
        section.extend(["", *clean_preamble])
    for _, block in blocks:
        section.extend(["", *_normalize_block(block)])
    section.append("")
    return section + lines[end:]


def _validated_state(path: Path):
    state = parse_plan(path)
    if state.issues:
        raise EditError(f"plan contract invalid: {state.issues[0]}")
    nums = [phase.num for phase in state.phases]
    if not nums or len(nums) != len(set(nums)):
        raise EditError("phase numbers must be unique and at least one phase must exist")
    if any(not phase.status for phase in state.phases):
        raise EditError("every phase must have one recognized status")
    if state.current_phase is not None and not state.phase(state.current_phase):
        raise EditError("Current Phase must name an existing phase")
    return state


def _measure(path: Path, text: str) -> tuple[dict[str, int], object]:
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.validate.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        temp_path = Path(temporary)
        state = _validated_state(temp_path)
        raw = text.encode("utf-8")
        current = state.phase(state.current_phase) if state.current_phase is not None else None
        current_text = ""
        if current:
            current_text = "\n".join(state.lines[current.heading_index : current.end_index])
        usage = {
            "lines": raw.count(b"\n") + (1 if raw and not raw.endswith(b"\n") else 0),
            "bytes": len(raw),
            "phases": len(state.phases),
            "items": len(state.items),
            "current_phase_items": len(current.items) if current else 0,
            "current_phase_bytes": len(current_text.encode("utf-8")),
        }
        return usage, state
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


LIMITS = {
    "lines": FILE_BUDGETS["tasks.md"][0],
    "bytes": FILE_BUDGETS["tasks.md"][1],
    "phases": TASKS_PHASE_LIMIT,
    "items": TASKS_ITEM_LIMIT,
    "current_phase_items": CURRENT_PHASE_ITEM_LIMIT,
    "current_phase_bytes": CURRENT_PHASE_BYTE_LIMIT,
}

ALLOWED_SECTIONS: dict[str, set[str]] = {
    "tasks.md": {
        "Goal",
        "Task Identity",
        "Workflow Profile",
        "Resume Checkpoint",
        "Key Questions",
        "Verification",
        "Progress Notes",
        "Errors Encountered",
        "Files Touched",
        "History",
    },
    "decisions.md": {"Active Decisions", "Superseded Decisions", "Open Decision Questions"},
    "findings.md": {"Current Summary", "Requirements", "Discoveries", "Known Gotchas", "Sources", "Detail Index"},
    "history.md": {"Completed Phases", "Verification History", "Resolved Errors"},
    "handoff.md": {"Resume Checkpoint", "Working State", "Relevant Context", "Verification", "Safety"},
}

HISTORY_TEMPLATE = """# History
<!-- Optional trusted cold archive. Do not auto-read. Never store external/untrusted content here. -->

## Completed Phases

## Verification History

## Resolved Errors
"""


def _preflight(plan: Path, candidate: str) -> tuple[dict[str, int], object]:
    old_usage, _ = _measure(plan, plan.read_text(encoding="utf-8"))
    new_usage, state = _measure(plan, candidate)
    worsened = [
        key
        for key, limit in LIMITS.items()
        if new_usage[key] > limit and new_usage[key] > old_usage[key]
    ]
    if worsened:
        detail = ", ".join(f"{key}={new_usage[key]}/{LIMITS[key]}" for key in worsened)
        raise EditError(f"edit would worsen plan budget: {detail}")
    return new_usage, state


def _resolve_target(plan: Path, name: str) -> Path:
    if name not in ALLOWED_SECTIONS:
        raise EditError(f"unsupported planning file: {name}")
    target = plan.parent / name
    if target.parent.resolve() != plan.parent.resolve():
        raise EditError("target must stay inside the owned plan directory")
    return target


def _check_optional_expected(path: Path, expected: str) -> str:
    if not path.exists():
        if expected != "missing":
            raise EditError(f"{path} is missing; expected fingerprint must be 'missing'")
        return "missing"
    if not path.is_file() or path.is_symlink():
        raise EditError(f"target must be a regular file: {path}")
    return _check_expected(path, expected)


def _section_bounds(lines: list[str], heading: str) -> tuple[int, int]:
    label = heading if heading.startswith("## ") else f"## {heading}"
    indices = [index for index, line in enumerate(lines) if line.strip() == label]
    if len(indices) != 1:
        raise EditError(f"expected exactly one {label} section")
    start = indices[0]
    end = next((index for index in range(start + 1, len(lines)) if lines[index].startswith("## ")), len(lines))
    return start, end


def _section_name(name: str) -> str:
    return name[3:] if name.startswith("## ") else name


def _validate_section_target(file_name: str, heading: str) -> str:
    normalized = _section_name(heading)
    if normalized not in ALLOWED_SECTIONS[file_name]:
        raise EditError(f"section is not editable through the structured interface: {file_name} / {normalized}")
    return normalized


def _content_lines(value: str, *, entry: bool = False) -> list[str]:
    lines = value.strip("\n").splitlines() if value.strip("\n") else []
    if any(line.startswith("## ") for line in lines):
        noun = "entry" if entry else "section body"
        raise EditError(f"a {noun} may not introduce a level-2 section heading")
    return lines


def _replace_section(lines: list[str], heading: str, content: str) -> list[str]:
    start, end = _section_bounds(lines, heading)
    body = _content_lines(content)
    replacement = body + ([""] if end < len(lines) else [])
    result = list(lines)
    result[start + 1 : end] = replacement
    return result


def _is_table_row(line: str) -> bool:
    stripped = line.strip()
    return stripped.startswith("|") and stripped.endswith("|")


REOPEN_DECISION_HINT = (
    '--decision must be one full Active Decisions row, for example '
    '"| D9 | Add branded short URLs | user authorized on 2026-09-07 | 2026-09-07 |"'
)


def _find_entry(lines: list[str], heading: str, entry: str) -> tuple[int, int]:
    start, end = _section_bounds(lines, heading)
    needle = _content_lines(entry, entry=True)
    if not needle:
        raise EditError("entry must not be empty")
    matches = [
        index
        for index in range(start + 1, end - len(needle) + 1)
        if lines[index : index + len(needle)] == needle
    ]
    if len(matches) != 1:
        raise EditError(f"expected exactly one matching entry, found {len(matches)}")
    return matches[0], matches[0] + len(needle)


def _edit_section_entry(lines: list[str], command: str, heading: str, entry: str, replacement: str | None) -> list[str]:
    result = list(lines)
    if command == "entry-append":
        start, end = _section_bounds(result, heading)
        body = _content_lines(entry, entry=True)
        if not body:
            raise EditError("entry must not be empty")
        while end > start + 1 and not result[end - 1].strip():
            end -= 1
        # A blank line between two table rows ends the table and starts a new
        # one, so the ledger a decisions row was appended to stops rendering as
        # a single table. Separate prose entries, never consecutive rows.
        separated = end > start + 1 and not (_is_table_row(result[end - 1]) and _is_table_row(body[0]))
        result[end:end] = ([""] if separated else []) + body
        return result
    entry_start, entry_end = _find_entry(result, heading, entry)
    if command == "entry-replace":
        result[entry_start:entry_end] = _content_lines(replacement or "", entry=True)
    else:
        del result[entry_start:entry_end]
    return result


def _file_usage(path: Path, text: str) -> dict[str, int]:
    raw = text.encode("utf-8")
    return {
        "lines": raw.count(b"\n") + (1 if raw and not raw.endswith(b"\n") else 0),
        "bytes": len(raw),
    }


def _preflight_target(plan: Path, target: Path, candidate: str) -> dict[str, int]:
    if target.name == "tasks.md":
        usage, _ = _preflight(plan, candidate)
        return usage
    new_usage = _file_usage(target, candidate)
    if target.name in FILE_BUDGETS:
        old_usage = _file_usage(target, target.read_text(encoding="utf-8")) if target.is_file() else {"lines": 0, "bytes": 0}
        line_limit, byte_limit = FILE_BUDGETS[target.name]
        worsened = (
            (new_usage["lines"] > line_limit and new_usage["lines"] > old_usage["lines"])
            or (new_usage["bytes"] > byte_limit and new_usage["bytes"] > old_usage["bytes"])
        )
        if worsened:
            raise EditError(
                f"edit would worsen {target.name} budget: lines={new_usage['lines']}/{line_limit}, "
                f"bytes={new_usage['bytes']}/{byte_limit}"
            )
    return new_usage


def _history_with_entry(history_text: str, heading: str, marker: str, entry: str) -> str:
    if marker in history_text:
        return history_text
    lines = history_text.splitlines()
    return _text(_edit_section_entry(lines, "entry-append", heading, f"{marker}\n{entry}", None))


def _history_state(plan: Path, expected: str, marker: str) -> tuple[Path, str, str, bool]:
    history = plan.parent / "history.md"
    current = history.read_text(encoding="utf-8") if history.is_file() else HISTORY_TEMPLATE
    already_archived = marker in current
    old_fingerprint = file_fingerprint(history) if history.is_file() else "missing"
    if not already_archived:
        _check_optional_expected(history, expected)
    return history, current, old_fingerprint, already_archived


def _decision_supersede(lines: list[str], decision_id: str, replacement_id: str, reason: str) -> list[str]:
    active_start, active_end = _section_bounds(lines, "Active Decisions")
    active_rows = [index for index in range(active_start + 1, active_end) if lines[index].startswith(f"| {decision_id} |")]
    replacement_rows = [index for index in range(active_start + 1, active_end) if lines[index].startswith(f"| {replacement_id} |")]
    if len(active_rows) != 1 or len(replacement_rows) != 1:
        raise EditError("decision and replacement must each exist exactly once in Active Decisions")
    cells = [cell.strip() for cell in lines[active_rows[0]].strip().strip("|").split("|")]
    if len(cells) < 4:
        raise EditError("active decision row is malformed")
    result = list(lines)
    del result[active_rows[0]]
    row = f"| {decision_id} | {cells[1]} | {replacement_id} | {' '.join(reason.split())} |"
    return _edit_section_entry(result, "entry-append", "Superseded Decisions", row, None)


def _retired_phase_numbers(lines: list[str]) -> set[int]:
    return {int(value) for value in re.findall(r"Retired Phase\s+(\d+)", "\n".join(lines))}


def _phase_high_water(lines: list[str]) -> int:
    return max((int(value) for value in PHASE_HIGH_WATER_RE.findall("\n".join(lines))), default=0)


def _set_phase_high_water(lines: list[str], phase_num: int) -> list[str]:
    result = list(lines)
    matches = [index for index, line in enumerate(result) if PHASE_HIGH_WATER_RE.fullmatch(line.strip())]
    marker = f"<!-- Phase ID high-water: {max(phase_num, _phase_high_water(result))} -->"
    if matches:
        result[matches[0]] = marker
        for index in reversed(matches[1:]):
            del result[index]
        return result
    heading = next((index for index, line in enumerate(result) if line.strip() == "## Phases"), None)
    if heading is None:
        raise EditError("expected ## Phases")
    result.insert(heading + 1, marker)
    return result


def _retired_item_ids(lines: list[str]) -> set[str]:
    return set(re.findall(r"Retired\s+([PV]\d+\.\d+)", "\n".join(lines)))


def _next_phase_num(state) -> int:
    used = {phase.num for phase in state.phases} | _retired_phase_numbers(state.lines)
    return max(max(used, default=0), _phase_high_water(state.lines)) + 1


def _next_item_id(state, phase_num: int, kind: str) -> str:
    ids = {item.item_id for item in state.items if item.item_id} | _retired_item_ids(state.lines)
    serials = [
        int(match.group(2))
        for item_id in ids
        if (match := ITEM_ID_RE.fullmatch(item_id))
        and item_id.startswith(kind)
        and int(match.group(1)) == phase_num
    ]
    return f"{kind}{phase_num}.{max(serials, default=0) + 1}"


def _phase_add(
    state, title: str, before: int | None, after: int | None
) -> tuple[list[str], dict[str, object], object | None]:
    if before is not None and after is not None:
        raise EditError("choose only one of --before or --after")
    blocks = _phase_blocks(state.lines, state)[3]
    new_num = _next_phase_num(state)
    block = [f"### Phase {new_num}: {' '.join(title.split())}", "- **Status:** pending"]
    index = len(blocks)
    target = before if before is not None else after
    if target is not None:
        target_index = next((i for i, (num, _) in enumerate(blocks) if num == target), None)
        if target_index is None:
            raise EditError(f"Phase {target} does not exist")
        index = target_index if before is not None else target_index + 1
    blocks.insert(index, (new_num, block))
    archived = None
    if len(blocks) > TASKS_PHASE_LIMIT:
        archived = next(
            (
                phase
                for phase in state.phases
                if phase.status == "complete" and phase.num != state.current_phase
            ),
            None,
        )
        if archived is None:
            raise EditError(
                f"adding Phase {new_num} would exceed the {TASKS_PHASE_LIMIT}-phase hot window, "
                "and no non-current complete phase is eligible for archival"
            )
        blocks = [(num, value) for num, value in blocks if num != archived.num]
    lines = _set_phase_high_water(_replace_phase_blocks(state.lines, state, blocks), new_num)
    return lines, {"phase": new_num, "archived_phase": archived.num if archived else None}, archived


HANDOFF_REQUIRED_HEADINGS = (
    "# Handoff",
    "## Resume Checkpoint",
    "## Working State",
    "## Verification",
    "## Safety",
)


def _handoff_problems(plan: Path, target: Path, content: str) -> list[str]:
    """Collect every handoff defect in one pass, including the budget."""
    problems: list[str] = []
    present = set(content.splitlines())
    missing = [heading for heading in HANDOFF_REQUIRED_HEADINGS if heading not in present]
    if missing:
        problems.append("missing required heading(s) " + ", ".join(repr(h) for h in missing))
    updated_at, reverify_after = handoff_metadata(content)
    if updated_at is None or reverify_after is None:
        problems.append(
            "needs exactly one timezone-aware ISO-8601 'Updated:' and 'Reverify after:' line, "
            "for example 'Updated: 2026-08-29T10:00:00+07:00'"
        )
    elif reverify_after <= updated_at:
        problems.append("'Reverify after' must be later than 'Updated'")
    try:
        _preflight_target(plan, target, content)
    except EditError as exc:
        problems.append(str(exc))
    return problems


PHASE_STATUSES = ("pending", "in_progress", "complete", "blocked", "deferred")
REASON_STATUSES = ("blocked", "deferred")


def _phase_update(
    state, phase_num: int, title: str | None, status: str | None, reason: str | None
) -> tuple[list[str], dict[str, object]]:
    phase = state.phase(phase_num)
    if not phase:
        raise EditError(f"Phase {phase_num} does not exist")
    if title is None and status is None:
        raise EditError("phase-update needs --title, --status, or both")
    lines = list(state.lines)
    result: dict[str, object] = {"phase": phase_num}
    if title is not None:
        suffix = f" [{phase.status}]" if PHASE_RE.match(lines[phase.heading_index]).group(3) else ""
        lines[phase.heading_index] = f"### Phase {phase_num}: {' '.join(title.split())}{suffix}"
        result["title"] = " ".join(title.split())
    if status is not None:
        lines = _set_phase_status_lines(lines, state, phase_num, status, reason)
        result["status"] = status if status not in REASON_STATUSES else f"{status} ({' '.join((reason or '').split())})"
    return lines, result


def _set_phase_status_lines(
    lines: list[str], state, phase_num: int, status: str, reason: str | None
) -> list[str]:
    """Write the exact `- **Status:**` grammar for one phase.

    Editing this line by hand is the single most common contract mistake:
    retitling a phase "DEFERRED" or dropping the reason leaves the plan
    actionable and the Stop hook blocks. Making it a first-class operation is
    what turns a pause from a multi-step ceremony into one call.
    """
    if status not in PHASE_STATUSES:
        raise EditError(f"--status must be one of {', '.join(PHASE_STATUSES)}")
    cleaned = " ".join((reason or "").split())
    if status in REASON_STATUSES and not cleaned:
        raise EditError(f"--status {status} requires a non-empty --reason")
    if status not in REASON_STATUSES and cleaned:
        raise EditError(f"--reason is only meaningful with --status {' or '.join(REASON_STATUSES)}")
    phase = state.phase(phase_num)
    if status == "complete":
        unchecked = [item.item_id for item in phase.items if not item.checked]
        if unchecked:
            raise EditError(
                f"Phase {phase_num} still has unchecked item(s) {', '.join(unchecked)}; "
                "complete them with plan_checkpoint.py, or use --status blocked/deferred with a reason"
            )
    body = f"- **Status:** {status}" + (f" ({cleaned})" if cleaned else "")
    lines = list(lines)
    index = next(
        (i for i in range(phase.heading_index + 1, phase.end_index) if lines[i].startswith("- **Status:**")),
        None,
    )
    if index is None:
        raise EditError(f"Phase {phase_num} has no '- **Status:**' line to update")
    lines[index] = body
    return lines


def _phase_move(state, phase_num: int, before: int | None, after: int | None) -> tuple[list[str], dict[str, object]]:
    if (before is None) == (after is None):
        raise EditError("choose exactly one of --before or --after")
    blocks = _phase_blocks(state.lines, state)[3]
    source_index = next((i for i, (num, _) in enumerate(blocks) if num == phase_num), None)
    target = before if before is not None else after
    target_index = next((i for i, (num, _) in enumerate(blocks) if num == target), None)
    if source_index is None or target_index is None:
        raise EditError("source or target phase does not exist")
    source = blocks.pop(source_index)
    target_index = next(i for i, (num, _) in enumerate(blocks) if num == target)
    blocks.insert(target_index if before is not None else target_index + 1, source)
    return _replace_phase_blocks(state.lines, state, blocks), {"phase": phase_num}


def _phase_remove(state, phase_num: int) -> tuple[list[str], dict[str, object]]:
    phase = state.phase(phase_num)
    if not phase:
        raise EditError(f"Phase {phase_num} does not exist")
    if phase.status != "pending" or state.current_phase == phase_num:
        raise EditError("only a non-current pending phase may be removed")
    if any(item.checked or item.evidence.lower() not in PLACEHOLDER_EVIDENCE for item in phase.items):
        raise EditError("phase has completed or evidenced work; archive it instead")
    blocks = _phase_blocks(state.lines, state)[3]
    index = next(i for i, (num, _) in enumerate(blocks) if num == phase_num)
    blocks[index] = (None, [f"<!-- Retired Phase {phase_num} -->"])
    return _replace_phase_blocks(state.lines, state, blocks), {"phase": phase_num, "retired": True}


def _item_block(state, item) -> tuple[int, int]:
    start = item.line_index
    end = item.evidence_index + 1 if item.evidence_index is not None else start + 1
    return start, end


def _item_add(state, phase_num: int, kind: str, text: str, after: str | None) -> tuple[list[str], dict[str, object]]:
    phase = state.phase(phase_num)
    if not phase or phase.status in SETTLED:
        raise EditError("target phase must exist and remain actionable")
    item_id = _next_item_id(state, phase_num, kind)
    block = [f"- [ ] [{item_id}] {' '.join(text.split())}", "  - Evidence: pending"]
    lines = list(state.lines)
    if after:
        target = state.item(after)
        if not target or target.phase_num != phase_num:
            raise EditError("--after must name an item in the target phase")
        _, insert_at = _item_block(state, target)
    elif kind == "P":
        insert_at = next(
            (
                index
                for index in range(phase.heading_index + 1, phase.end_index)
                if lines[index].startswith("- **Status:**") or lines[index].strip() == "**Done when:**"
            ),
            phase.end_index,
        )
    else:
        status_index = next(
            (index for index in range(phase.heading_index + 1, phase.end_index) if lines[index].startswith("- **Status:**")),
            phase.end_index,
        )
        insert_at = status_index
        if not any(lines[index].strip() == "**Done when:**" for index in range(phase.heading_index, status_index)):
            block = ["**Done when:**", *block]
    lines[insert_at:insert_at] = block
    return lines, {"item": item_id, "phase": phase_num}


def _item_update(state, item_id: str, text: str) -> tuple[list[str], dict[str, object]]:
    item = state.item(item_id)
    if not item:
        raise EditError(f"item {item_id} does not exist")
    lines = list(state.lines)
    mark = "x" if item.checked else " "
    lines[item.line_index] = f"- [{mark}] [{item_id}] {' '.join(text.split())}"
    return lines, {"item": item_id, "phase": item.phase_num}


def _insert_item_block(lines: list[str], state, phase_num: int, block: list[str], after: str | None) -> None:
    phase = state.phase(phase_num)
    if not phase or phase.status in SETTLED:
        raise EditError("target phase must exist and remain actionable")
    if after:
        target = state.item(after)
        if not target or target.phase_num != phase_num:
            raise EditError("--after must name an item in the target phase")
        _, insert_at = _item_block(state, target)
    else:
        insert_at = next(
            (index for index in range(phase.heading_index + 1, phase.end_index) if lines[index].startswith("- **Status:**")),
            phase.end_index,
        )
    lines[insert_at:insert_at] = block


def _item_move(state, item_id: str, phase_num: int, after: str | None) -> tuple[list[str], dict[str, object]]:
    item = state.item(item_id)
    target_phase = state.phase(phase_num)
    if not item or not target_phase:
        raise EditError("source item or target phase does not exist")
    if after == item_id:
        raise EditError("an item cannot move after itself")
    start, end = _item_block(state, item)
    block = state.lines[start:end]
    lines = list(state.lines)
    if phase_num == item.phase_num:
        del lines[start:end]
        refreshed = _validated_from_lines(state.path, lines)
        _insert_item_block(lines, refreshed, phase_num, block, after)
        return lines, {"item": item_id, "phase": phase_num}
    if item.checked or item.evidence.lower() not in PLACEHOLDER_EVIDENCE or state.active_item == item_id:
        raise EditError("cross-phase move requires an unchecked, non-active, evidence-free item")
    if target_phase.status in SETTLED:
        raise EditError("target phase is settled")
    new_id = _next_item_id(state, phase_num, item_id[0])
    block[0] = re.sub(rf"\[{re.escape(item_id)}\]", f"[{new_id}]", block[0], count=1)
    lines[start:end] = [f"<!-- Retired {item_id}: moved to {new_id} -->"]
    refreshed = _validated_from_lines(state.path, lines)
    _insert_item_block(lines, refreshed, phase_num, block, after)
    return lines, {"old_item": item_id, "item": new_id, "phase": phase_num}


def _item_remove(state, item_id: str) -> tuple[list[str], dict[str, object]]:
    item = state.item(item_id)
    if not item:
        raise EditError(f"item {item_id} does not exist")
    if item.checked or state.active_item == item_id or item.evidence.lower() not in PLACEHOLDER_EVIDENCE:
        raise EditError("only unchecked, non-active, evidence-free work may be removed")
    start, end = _item_block(state, item)
    lines = list(state.lines)
    lines[start:end] = [f"<!-- Retired {item_id} -->"]
    return lines, {"item": item_id, "retired": True}


def _validated_from_lines(path: Path, lines: list[str]):
    _, state = _measure(path, _text(lines))
    return state


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fingerprinted structural edits to a planning task folder.",
        epilog=(
            "Global flags must precede the subcommand, e.g. plan_edit.py --plan tasks.md "
            "--expected-fingerprint <sha256> --dry-run phase-update 2 --status deferred --reason 'user paused'"
        ),
    )
    parser.add_argument(
        "--plan",
        type=Path,
        help=(
            "path to the plan's tasks.md file (not the task directory); omit it to use "
            "the task named by this workspace's .plan-files pointer"
        ),
    )
    parser.add_argument(
        "--expected-fingerprint",
        required=True,
        help=(
            "full SHA-256 of the target file, from a read command's 'file_fingerprint' field "
            "or 'sha256sum <file>'. NOT the 16-hex 'fingerprint' progress hash."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="validate and report without writing (must appear before the subcommand)",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    phase_add = commands.add_parser("phase-add", help="append a phase for the same goal; history-first rollover past the hot window")
    phase_add.add_argument("--title", required=True)
    phase_add.add_argument("--before", type=int)
    phase_add.add_argument("--after", type=int)
    phase_add.add_argument("--expected-history-fingerprint")
    phase_update = commands.add_parser(
        "phase-update", help="retitle a phase and/or set its status atomically"
    )
    phase_update.add_argument("phase", type=int, help="phase number, e.g. 2")
    phase_update.add_argument("--title", help="new phase title (omit to keep the current one)")
    phase_update.add_argument(
        "--status",
        choices=PHASE_STATUSES,
        help="new phase status; 'blocked' and 'deferred' require --reason",
    )
    phase_update.add_argument(
        "--reason",
        help="external dependency (blocked) or the user's postponement (deferred)",
    )
    phase_move = commands.add_parser("phase-move", help="reorder a phase relative to another")
    phase_move.add_argument("phase", type=int)
    phase_move.add_argument("--before", type=int)
    phase_move.add_argument("--after", type=int)
    phase_remove = commands.add_parser("phase-remove", help="delete a phase that holds no evidenced work")
    phase_remove.add_argument("phase", type=int)

    item_add = commands.add_parser("item-add", help="add an outcome (P) or acceptance (V) item to a phase")
    item_add.add_argument("--phase", required=True, type=int)
    item_add.add_argument("--kind", choices=("P", "V"), default="P")
    item_add.add_argument("--text", required=True)
    item_add.add_argument("--after")
    item_update = commands.add_parser("item-update", help="rewrite the outcome text of one item")
    item_update.add_argument("item")
    item_update.add_argument("--text", required=True)
    item_move = commands.add_parser("item-move", help="move an item to another phase")
    item_move.add_argument("item")
    item_move.add_argument("--phase", required=True, type=int)
    item_move.add_argument("--after")
    item_remove = commands.add_parser("item-remove", help="delete an unchecked item")
    item_remove.add_argument("item")

    for name in ("section-replace", "entry-append", "entry-replace", "entry-remove"):
        section = commands.add_parser(name, help=name.replace("-", " ") + " within one planning file section")
        section.add_argument("--file", required=True, choices=tuple(ALLOWED_SECTIONS), help="planning file to edit")
        section.add_argument(
            "--heading",
            required=True,
            help="section heading without the leading '## '; an invalid value lists the allowed headings",
        )
        if name == "section-replace":
            section.add_argument("--content", required=True)
        else:
            section.add_argument("--entry", required=True)
            if name == "entry-replace":
                section.add_argument("--replacement", required=True)

    reopen = commands.add_parser(
        "reopen",
        help="reopen a settled plan for newly authorized work, in one transaction",
        description=(
            "A plan whose phases are all settled cannot record what a new prompt authorizes, "
            "and Stop accepts it as finished. This does every step that fact requires, in the "
            "one order that is safe: append the authorizing decision (retiring what it "
            "replaces), reconcile the scope fields you name, open the phase that will carry "
            "the work with its items, and start the first one. Nothing is written until every "
            "step validates."
        ),
    )
    reopen.add_argument("--title", required=True, help="title of the phase that carries the authorized work")
    reopen.add_argument(
        "--decision",
        required=True,
        help='the authorization as one Active Decisions row: "| D9 | <decision> | <rationale> | <date> |"',
    )
    reopen.add_argument(
        "--item",
        action="append",
        required=True,
        metavar="OUTCOME",
        help="observable outcome for the new phase; repeatable, and the first one becomes the Active Item",
    )
    reopen.add_argument(
        "--verify",
        action="append",
        metavar="ACCEPTANCE",
        help="acceptance (V) item for the new phase; repeatable",
    )
    reopen.add_argument("--supersede", metavar="OLD-ID", help="retire this Active Decisions row, replaced by --decision")
    reopen.add_argument("--supersede-reason", help="why it was replaced; defaults to the new decision text")
    reopen.add_argument("--goal", help="rewrite ## Goal for the authorized scope")
    reopen.add_argument("--deliverable", help="rewrite the Task Identity Deliverable")
    reopen.add_argument("--non-goals", help="rewrite the Task Identity Non-goals")
    reopen.add_argument("--profile", choices=("A", "B", "C"), help="reset the Workflow Profile")
    reopen.add_argument(
        "--expected-decisions-fingerprint",
        help="SHA-256 of decisions.md; optional, since the append is idempotent under the plan lock",
    )
    reopen.add_argument(
        "--expected-history-fingerprint",
        help="required only when the new phase rolls the oldest complete phase into history.md",
    )

    supersede = commands.add_parser("decision-supersede", help="retire a decision into Superseded Decisions with a reason")
    supersede.add_argument("decision")
    supersede.add_argument("--replacement", required=True)
    supersede.add_argument("--reason", required=True)

    archive_phase = commands.add_parser("archive-phase", help="move one complete phase into history.md")
    archive_phase.add_argument("phase", type=int)
    archive_phase.add_argument("--expected-history-fingerprint", required=True)
    compact_oldest = commands.add_parser("compact-oldest", help="archive the oldest eligible complete phase to reclaim budget")
    compact_oldest.add_argument("--expected-history-fingerprint", required=True)

    archive_entry = commands.add_parser("archive-entry", help="move one Verification or Errors Encountered row into history.md")
    archive_entry.add_argument("--source-section", required=True, choices=("Verification", "Errors Encountered"))
    archive_entry.add_argument("--entry", required=True)
    archive_entry.add_argument("--archive-entry", required=True)
    archive_entry.add_argument("--expected-history-fingerprint", required=True)

    handoff_write = commands.add_parser(
        "handoff-write",
        help="overwrite handoff.md for an intentional pause",
        description=(
            "Overwrite handoff.md. The content must contain these headings verbatim: "
            + ", ".join(HANDOFF_REQUIRED_HEADINGS)
            + ". It must also carry exactly one timezone-aware ISO-8601 'Updated:' line and one "
            "'Reverify after:' line strictly later than it, for example "
            "'Updated: 2026-08-29T10:00:00+07:00'. Budget: "
            + "{} lines / {} KiB".format(FILE_BUDGETS["handoff.md"][0], FILE_BUDGETS["handoff.md"][1] // 1024)
            + ". Every violation is reported in one response."
        ),
    )
    handoff_write.add_argument(
        "--content",
        required=True,
        help="full replacement body; see this subcommand's description for the required shape",
    )
    pause = commands.add_parser(
        "pause",
        help="settle a phase and stage its handoff in one ordered transaction",
        description=(
            "Pause work in one call: optionally record partial evidence on the Active Item, "
            "set the phase status with its reason, move Active Item to whatever is still "
            "actionable (or clear it), sync Resume Checkpoint, and write handoff.md last so it "
            "is not immediately stale. Does not write decisions.md or findings.md; their content "
            "needs your judgment, so write them yourself before calling this."
        ),
    )
    pause.add_argument("--phase", type=int, help="the single phase to settle")
    pause.add_argument(
        "--all-remaining",
        action="store_true",
        help="settle every non-settled phase, for pausing a whole task",
    )
    pause.add_argument(
        "--status",
        choices=PAUSE_STATUSES,
        default="deferred",
        help="deferred (user postponed, default) or blocked (external dependency)",
    )
    pause.add_argument("--reason", required=True, help="why the work stops; recorded in the status line")
    pause.add_argument("--evidence", help="partial evidence for the current Active Item before it is stood down")
    pause.add_argument(
        "--next-action",
        help="Resume Checkpoint next action; defaults to a line naming the reason",
    )
    pause.add_argument(
        "--handoff-content",
        help="full handoff.md body; see 'handoff-write --help' for the required shape",
    )
    commands.add_parser("handoff-clear", help="delete handoff.md")
    return parser


STRUCTURAL_COMMANDS = {
    "phase-update",
    "phase-move",
    "phase-remove",
    "item-add",
    "item-update",
    "item-move",
    "item-remove",
}
SECTION_COMMANDS = {"section-replace", "entry-append", "entry-replace", "entry-remove"}


def _structural_edit(args, state) -> tuple[list[str], dict[str, object]]:
    if args.command == "phase-update":
        return _phase_update(state, args.phase, args.title, args.status, args.reason)
    if args.command == "phase-move":
        return _phase_move(state, args.phase, args.before, args.after)
    if args.command == "phase-remove":
        return _phase_remove(state, args.phase)
    if args.command == "item-add":
        return _item_add(state, args.phase, args.kind, args.text, args.after)
    if args.command == "item-update":
        return _item_update(state, args.item, args.text)
    if args.command == "item-move":
        return _item_move(state, args.item, args.phase, args.after)
    return _item_remove(state, args.item)


PAUSE_STATUSES = ("deferred", "blocked")


def _set_section_body(lines: list[str], heading: str, value: str | None) -> list[str]:
    start, end = _section_bounds(lines, heading)
    lines = list(lines)
    replacement = [value] if value else []
    lines[start + 1 : end] = replacement + ([""] if end < len(lines) else [])
    return lines


def _set_resume_field_lines(lines: list[str], label: str, value: str) -> list[str]:
    start, end = _section_bounds(lines, "Resume Checkpoint")
    prefix = f"- **{label}:**"
    matches = [index for index in range(start + 1, end) if lines[index].startswith(prefix)]
    if len(matches) != 1:
        raise EditError(f"Resume Checkpoint must contain exactly one {prefix} field")
    lines = list(lines)
    lines[matches[0]] = f"{prefix} {value}"
    return lines


def _set_item_evidence_lines(lines: list[str], item, evidence: str) -> list[str]:
    cleaned = " ".join(evidence.split())
    if not cleaned or cleaned.lower() in PLACEHOLDER_EVIDENCE:
        raise EditError("--evidence must be concrete, not a placeholder")
    index = item.evidence_index
    if index is None or index >= len(lines):
        raise EditError(f"{item.item_id} has no Evidence line to update")
    indent = lines[index][: len(lines[index]) - len(lines[index].lstrip())]
    lines = list(lines)
    lines[index] = f"{indent}- Evidence: {cleaned}"
    return lines


def _set_prose_body(lines: list[str], heading: str, value: str) -> list[str]:
    """Replace a section's visible prose while keeping its guidance comments.

    The comments in tasks.md carry the format contract itself, so rewriting a
    Goal must not silently delete the rules for writing the next one.
    """
    start, end = _section_bounds(lines, heading)
    kept: list[str] = []
    in_comment = False
    for line in lines[start + 1 : end]:
        stripped = line.strip()
        opens = "<!--" in stripped
        if in_comment or opens:
            kept.append(line)
            in_comment = (in_comment or opens) and "-->" not in stripped
    result = list(lines)
    result[start + 1 : end] = kept + _content_lines(value) + ([""] if end < len(lines) else [])
    return result


def _set_labelled_field(lines: list[str], heading: str, label: str, value: str) -> list[str]:
    """Rewrite one '- Label:' line, in either the plain or bold spelling."""
    start, end = _section_bounds(lines, heading)
    prefixes = (f"- {label}:", f"- **{label}:**")
    matches = [
        index
        for index in range(start + 1, end)
        if lines[index].strip().startswith(prefixes)
    ]
    if len(matches) != 1:
        raise EditError(f"{heading} must contain exactly one '- {label}:' field")
    bold = lines[matches[0]].strip().startswith(prefixes[1])
    result = list(lines)
    result[matches[0]] = f"{prefixes[1] if bold else prefixes[0]} {' '.join(value.split())}"
    return result


def _set_workflow_profile(lines: list[str], profile: str) -> list[str]:
    start, end = _section_bounds(lines, "Workflow Profile")
    matches = [index for index in range(start + 1, end) if lines[index].strip().startswith("**Profile:**")]
    if len(matches) != 1:
        raise EditError("Workflow Profile must contain exactly one '**Profile:**' line")
    result = list(lines)
    result[matches[0]] = f"**Profile:** {profile}"
    return result


def _decision_row_cells(row: str) -> list[str]:
    stripped = row.strip()
    if not _is_table_row(stripped):
        raise EditError(REOPEN_DECISION_HINT)
    cells = [cell.strip() for cell in stripped.strip("|").split("|")]
    if len(cells) < 4 or not cells[0] or not cells[1]:
        raise EditError(REOPEN_DECISION_HINT)
    return cells


def _reopen_decisions(args) -> tuple[Path, str, str, bool]:
    """Record the authorization that makes reopening this plan legitimate."""
    target = _resolve_target(args.plan, "decisions.md")
    if not target.is_file():
        raise EditError(f"target does not exist: {target}")
    cells = _decision_row_cells(args.decision)
    decision_id = cells[0]
    row = args.decision.strip()
    lines = target.read_text(encoding="utf-8").splitlines()
    start, end = _section_bounds(lines, "Active Decisions")
    # Idempotent on purpose: decisions.md is written before tasks.md, so a
    # crash in between must leave `reopen` safe to run again rather than
    # appending the same authorization twice.
    already = any(lines[index].strip() == row for index in range(start + 1, end))
    if not already:
        lines = _edit_section_entry(lines, "entry-append", "Active Decisions", row, None)
    if args.supersede:
        if args.supersede == decision_id:
            raise EditError("--supersede must name a decision other than the one --decision adds")
        reason = args.supersede_reason or cells[1]
        lines = _decision_supersede(lines, args.supersede, decision_id, reason)
    return target, _text(lines), decision_id, already


def _reopen_tasks(args, state) -> tuple[list[str], object, dict[str, object]]:
    """Reconcile scope, open the phase that carries the work, and start it."""
    if not state.phases:
        raise EditError("reopen needs an existing plan with phases")
    actionable = [phase.num for phase in state.phases if phase.status not in SETTLED]
    if actionable:
        raise EditError(
            f"Phase {actionable[0]} is still actionable, so this plan is not settled; "
            "use phase-add/item-add and plan_checkpoint.py start instead"
        )
    lines = list(state.lines)
    if args.goal:
        lines = _set_prose_body(lines, "Goal", args.goal)
    if args.deliverable:
        lines = _set_labelled_field(lines, "Task Identity", "Deliverable", args.deliverable)
    if args.non_goals:
        lines = _set_labelled_field(lines, "Task Identity", "Non-goals", args.non_goals)
    if args.profile:
        lines = _set_workflow_profile(lines, args.profile)

    lines, phase_result, archived = _phase_add(_validated_from_lines(args.plan, lines), args.title, None, None)
    phase_num = phase_result["phase"]
    items: list[str] = []
    for kind, texts in (("P", args.item), ("V", args.verify or [])):
        # Chain each kind after its own last item only. Anchoring a V item on a
        # P item would place it above the phase status and skip the
        # "**Done when:**" header that acceptance items live under.
        previous = None
        for text in texts:
            lines, item_result = _item_add(
                _validated_from_lines(args.plan, lines), phase_num, kind, text, previous
            )
            previous = item_result["item"]
            items.append(previous)
    lines = plan_checkpoint.apply_start(_validated_from_lines(args.plan, lines), items[0])
    result = {
        "phase": phase_num,
        "archived_phase": phase_result["archived_phase"],
        "items": items,
        "item": items[0],
    }
    return lines, archived, result


def _reopen_command(args, state, old_fingerprint: str) -> dict[str, object]:
    decisions, decisions_candidate, decision_id, already = _reopen_decisions(args)
    decisions_old = (
        _check_expected(decisions, args.expected_decisions_fingerprint)
        if args.expected_decisions_fingerprint
        else file_fingerprint(decisions)
    )
    lines, archived, result = _reopen_tasks(args, state)
    candidate = _text(lines)
    # Validate every file before writing any of them: a reopen that fails half
    # way is worse than one that never started.
    decisions_usage = _preflight_target(args.plan, decisions, decisions_candidate)
    usage, _ = _preflight(args.plan, candidate)
    if archived is not None:
        _rollover_material(args, state, archived)
    if not args.dry_run:
        # Authorization lands first. The phase it justifies is what the Stop
        # gate reads, so a crash may leave a recorded decision with no phase
        # (rerunnable) but never a phase nothing authorized.
        _atomic_write(decisions, decisions_candidate)
    result.update(
        {
            "decision": decision_id,
            "decision_already_recorded": already,
            "superseded": args.supersede,
            "decisions_file": str(decisions),
            "decisions_old_fingerprint": decisions_old,
            "decisions_fingerprint": hashlib.sha256(decisions_candidate.encode("utf-8")).hexdigest(),
            "decisions_usage": decisions_usage,
        }
    )
    payload = _phase_write(args, state, archived, candidate, usage, result, old_fingerprint)
    if not args.dry_run:
        payload["restore"] = restore_payload(args.plan)
    return payload


def _pause(args, state) -> tuple[list[str], Path | None, str | None, dict[str, object]]:
    """Settle a phase and stage a matching handoff in one ordered transaction.

    The order matters and is the whole point of the command. handoff.md is
    considered stale whenever a required planning file is newer than it, so a
    handoff written before tasks.md is stale the moment it lands. Doing this by
    hand reliably costs a wasted write plus a re-write.
    """
    cleaned_reason = " ".join((args.reason or "").split())
    if not cleaned_reason:
        raise EditError("--reason is required and must be non-empty")
    if args.all_remaining and args.phase is not None:
        raise EditError("choose either --phase or --all-remaining, not both")
    if not args.all_remaining and args.phase is None:
        raise EditError("pause needs --phase N or --all-remaining")

    if args.all_remaining:
        targets = [phase.num for phase in state.phases if phase.status not in SETTLED]
        if not targets:
            raise EditError("every phase is already settled; nothing to pause")
    else:
        phase = state.phase(args.phase)
        if not phase:
            raise EditError(f"Phase {args.phase} does not exist")
        if phase.status in SETTLED:
            raise EditError(f"Phase {args.phase} is already '{phase.status}'; nothing to pause")
        targets = [args.phase]

    lines = list(state.lines)

    # Partial evidence first, while the item is still the Active Item.
    evidence_item = None
    if args.evidence:
        if not state.active_item:
            raise EditError("--evidence needs an Active Item to attach to")
        evidence_item = state.item(state.active_item)
        if not evidence_item or evidence_item.phase_num not in targets:
            raise EditError(
                f"Active Item {state.active_item} is not in a paused phase; "
                "checkpoint it separately before pausing"
            )
        lines = _set_item_evidence_lines(lines, evidence_item, args.evidence)

    for number in targets:
        lines = _set_phase_status_lines(lines, state, number, args.status, cleaned_reason)

    # Point the plan at whatever is still actionable, or stand it down cleanly.
    remaining = [
        phase
        for phase in state.phases
        if phase.num not in targets and phase.status not in SETTLED
    ]
    next_phase = remaining[0] if remaining else None
    next_item = next((item for item in next_phase.items if not item.checked), None) if next_phase else None
    if next_phase and next_item:
        lines = _set_section_body(lines, "Current Phase", f"Phase {next_phase.num}")
        lines = _set_section_body(lines, "Active Item", next_item.item_id)
        lines = _set_resume_field_lines(lines, "Next action", f"Complete {next_item.item_id}: {next_item.text}")
        lines = _set_resume_field_lines(lines, "Blocker", "none")
    else:
        lines = _set_section_body(lines, "Active Item", None)
        next_action = args.next_action or f"Resume the paused work: {cleaned_reason}"
        lines = _set_resume_field_lines(lines, "Next action", " ".join(next_action.split()))
        lines = _set_resume_field_lines(
            lines,
            "Blocker",
            cleaned_reason if args.status == "blocked" else "none",
        )

    handoff_target = None
    handoff_content = None
    if args.handoff_content is not None:
        handoff_target = _resolve_target(args.plan, "handoff.md")
        handoff_content = args.handoff_content.rstrip() + "\n"
        problems = _handoff_problems(args.plan, handoff_target, handoff_content)
        if problems:
            raise EditError("handoff content is invalid: " + "; ".join(problems))

    result: dict[str, object] = {
        "paused_phases": targets,
        "status": args.status,
        "reason": cleaned_reason,
        "evidence_item": evidence_item.item_id if evidence_item else None,
        "next_item": next_item.item_id if next_item else None,
        "still_actionable": [phase.num for phase in remaining],
        "handoff_written": handoff_content is not None,
    }
    return lines, handoff_target, handoff_content, result


def _pause_command(args, state, old_fingerprint: str) -> dict[str, object]:
    lines, handoff_target, handoff_content, result = _pause(args, state)
    candidate = _text(lines)
    usage, _ = _preflight(args.plan, candidate)
    payload = _candidate_payload(
        args.plan,
        args.plan,
        "pause",
        old_fingerprint,
        candidate,
        usage,
        result,
        args.dry_run,
    )
    # tasks.md is already on disk here when this is not a dry run. Writing the
    # handoff second is what keeps it fresh, and a crash between the two leaves
    # a valid settled plan with a merely absent handoff rather than a handoff
    # describing a pause that never happened.
    if handoff_content is not None and not args.dry_run:
        _atomic_write(handoff_target, handoff_content)
        payload["handoff_fingerprint"] = file_fingerprint(handoff_target)
    if not args.dry_run:
        payload["restore"] = restore_payload(args.plan)
    return payload


def _candidate_payload(
    plan: Path,
    target: Path,
    command: str,
    old_fingerprint: str,
    candidate: str,
    usage: dict[str, int],
    result: dict[str, object],
    dry_run: bool,
) -> dict[str, object]:
    new_fingerprint = hashlib.sha256(candidate.encode("utf-8")).hexdigest()
    if not dry_run:
        _atomic_write(target, candidate)
        if target == plan:
            _validated_state(plan)
    context = context_payload(parse_plan(plan))
    if target == plan and dry_run:
        _, state = _measure(plan, candidate)
        state.path = plan
        context = context_payload(state)
        context["file_fingerprint"] = new_fingerprint
    return {
        "ok": True,
        "operation": command,
        "dry_run": dry_run,
        "file": str(target),
        **result,
        "old_fingerprint": old_fingerprint,
        "fingerprint": new_fingerprint,
        "usage": usage,
        "context": context,
        "budgets": budget_payload(plan) if not dry_run else None,
    }


def _section_edit(args) -> tuple[Path, str, dict[str, object]]:
    target = _resolve_target(args.plan, args.file)
    if not target.is_file():
        raise EditError(f"target does not exist: {target}")
    heading = _validate_section_target(args.file, args.heading)
    lines = target.read_text(encoding="utf-8").splitlines()
    if args.command == "section-replace":
        result = _replace_section(lines, heading, args.content)
    else:
        replacement = getattr(args, "replacement", None)
        result = _edit_section_entry(lines, args.command, heading, args.entry, replacement)
    return target, _text(result), {"heading": heading}


def _phase_history_material(plan: Path, state, phase, expected: str) -> dict[str, object]:
    block = "\n".join(state.lines[phase.heading_index : phase.end_index]).strip()
    marker_hash = hashlib.sha256(block.encode("utf-8")).hexdigest()[:16]
    marker = f"<!-- Archived Phase {phase.num}: {marker_hash} -->"
    history, history_text, old_fingerprint, already_archived = _history_state(plan, expected, marker)
    candidate = _history_with_entry(history_text, "Completed Phases", marker, block)
    return {
        "path": history,
        "candidate": candidate,
        "old_fingerprint": old_fingerprint,
        "fingerprint": hashlib.sha256(candidate.encode("utf-8")).hexdigest(),
        "already_archived": already_archived,
        "heading": "Completed Phases",
        "marker": marker,
        "entry": block,
    }


def _phase_add_command(args, state, old_fingerprint: str) -> dict[str, object]:
    lines, result, archived = _phase_add(state, args.title, args.before, args.after)
    candidate = _text(lines)
    usage, _ = _preflight(args.plan, candidate)
    return _phase_write(args, state, archived, candidate, usage, result, old_fingerprint)


def _rollover_material(args, state, archived) -> dict[str, object]:
    """Validate the archival half of a rollover without writing anything."""
    if args.expected_history_fingerprint is None:
        raise EditError(
            f"{args.command} rollover requires --expected-history-fingerprint with the "
            "current history.md SHA-256 or 'missing'"
        )
    return _phase_history_material(args.plan, state, archived, args.expected_history_fingerprint)


def _phase_write(args, state, archived, candidate: str, usage: dict[str, int],
                 result: dict[str, object], old_fingerprint: str) -> dict[str, object]:
    """Commit a tasks.md candidate, rolling the evicted phase into history.md.

    Shared by phase-add and reopen: both can push the hot window past its
    12-heading limit, and the archive must stay one transaction either way.
    """
    if archived is None:
        return _candidate_payload(
            args.plan,
            args.plan,
            args.command,
            old_fingerprint,
            candidate,
            usage,
            result,
            args.dry_run,
        )
    history = _rollover_material(args, state, archived)
    new_fingerprint = hashlib.sha256(candidate.encode("utf-8")).hexdigest()
    transaction_id = None
    if not args.dry_run:
        transaction_id = _transactional_archive_write(
            plan=args.plan,
            operation=args.command,
            plan_old_fingerprint=old_fingerprint,
            tasks_candidate=candidate,
            history_path=history["path"],
            history_old_fingerprint=history["old_fingerprint"],
            history_candidate=history["candidate"],
            history_heading=history["heading"],
            marker=history["marker"],
            archive_entry=history["entry"],
        )
        context = context_payload(parse_plan(args.plan))
        budgets = budget_payload(args.plan)
    else:
        _, candidate_state = _measure(args.plan, candidate)
        candidate_state.path = args.plan
        context = context_payload(candidate_state)
        context["file_fingerprint"] = new_fingerprint
        budgets = None
    return {
        "ok": True,
        "operation": args.command,
        "dry_run": args.dry_run,
        "file": str(args.plan),
        **result,
        "old_fingerprint": old_fingerprint,
        "fingerprint": new_fingerprint,
        "history_old_fingerprint": history["old_fingerprint"],
        "history_fingerprint": history["fingerprint"],
        "history_already_archived": history["already_archived"],
        "transaction_id": transaction_id,
        "usage": usage,
        "context": context,
        "budgets": budgets,
    }


def _archive_complete_phase(args, state, phase, old_fingerprint: str) -> dict[str, object]:
    if not phase or phase.status != "complete":
        raise EditError("archive-phase requires a complete phase")
    if state.current_phase == phase.num or (state.active_item and state.item(state.active_item).phase_num == phase.num):
        raise EditError("cannot archive the current or active phase")
    history = _phase_history_material(args.plan, state, phase, args.expected_history_fingerprint)
    lines = list(state.lines)
    del lines[phase.heading_index : phase.end_index]
    lines = _set_phase_high_water(lines, max(candidate.num for candidate in state.phases))
    tasks_candidate = _text(lines)
    usage, _ = _preflight(args.plan, tasks_candidate)
    transaction_id = None
    if not args.dry_run:
        transaction_id = _transactional_archive_write(
            plan=args.plan,
            operation=args.command,
            plan_old_fingerprint=old_fingerprint,
            tasks_candidate=tasks_candidate,
            history_path=history["path"],
            history_old_fingerprint=history["old_fingerprint"],
            history_candidate=history["candidate"],
            history_heading=history["heading"],
            marker=history["marker"],
            archive_entry=history["entry"],
        )
    return {
        "ok": True,
        "operation": args.command,
        "dry_run": args.dry_run,
        "phase": phase.num,
        "old_fingerprint": old_fingerprint,
        "fingerprint": hashlib.sha256(tasks_candidate.encode("utf-8")).hexdigest(),
        "history_old_fingerprint": history["old_fingerprint"],
        "history_fingerprint": history["fingerprint"],
        "history_already_archived": history["already_archived"],
        "transaction_id": transaction_id,
        "usage": usage,
        "context": context_payload(parse_plan(args.plan)) if not args.dry_run else None,
        "budgets": budget_payload(args.plan) if not args.dry_run else None,
    }


def _archive_phase(args, state, old_fingerprint: str) -> dict[str, object]:
    phase = state.phase(args.phase)
    return _archive_complete_phase(args, state, phase, old_fingerprint)


def _compact_oldest(args, state, old_fingerprint: str) -> dict[str, object]:
    phase = next(
        (
            candidate
            for candidate in state.phases
            if candidate.status == "complete" and candidate.num != state.current_phase
        ),
        None,
    )
    if phase is None:
        raise EditError("no non-current complete phase is eligible for compaction")
    return _archive_complete_phase(args, state, phase, old_fingerprint)


def _archive_entry(args, old_fingerprint: str) -> dict[str, object]:
    pairs = {"Verification": "Verification History", "Errors Encountered": "Resolved Errors"}
    history_heading = pairs[args.source_section]
    tasks_lines = args.plan.read_text(encoding="utf-8").splitlines()
    source_start, source_end = _find_entry(tasks_lines, args.source_section, args.entry)
    tasks_lines[source_start:source_end] = []
    tasks_candidate = _text(tasks_lines)
    usage, _ = _preflight(args.plan, tasks_candidate)
    marker_hash = hashlib.sha256(f"{args.source_section}\n{args.entry}".encode("utf-8")).hexdigest()[:16]
    marker = f"<!-- Archived {args.source_section}: {marker_hash} -->"
    history, history_text, old_history_fingerprint, already_archived = _history_state(
        args.plan, args.expected_history_fingerprint, marker
    )
    history_candidate = _history_with_entry(history_text, history_heading, marker, args.archive_entry)
    transaction_id = None
    if not args.dry_run:
        transaction_id = _transactional_archive_write(
            plan=args.plan,
            operation=args.command,
            plan_old_fingerprint=old_fingerprint,
            tasks_candidate=tasks_candidate,
            history_path=history,
            history_old_fingerprint=old_history_fingerprint,
            history_candidate=history_candidate,
            history_heading=history_heading,
            marker=marker,
            archive_entry=args.archive_entry,
        )
    return {
        "ok": True,
        "operation": args.command,
        "dry_run": args.dry_run,
        "source_section": args.source_section,
        "history_section": history_heading,
        "old_fingerprint": old_fingerprint,
        "fingerprint": hashlib.sha256(tasks_candidate.encode("utf-8")).hexdigest(),
        "history_old_fingerprint": old_history_fingerprint,
        "history_fingerprint": hashlib.sha256(history_candidate.encode("utf-8")).hexdigest(),
        "history_already_archived": already_archived,
        "transaction_id": transaction_id,
        "usage": usage,
        "context": context_payload(parse_plan(args.plan)) if not args.dry_run else None,
        "budgets": budget_payload(args.plan) if not args.dry_run else None,
    }


def _bad_plan_message(plan: Path) -> str:
    """Explain the usual slip: --plan wants tasks.md, not the task directory."""
    if plan.is_dir():
        candidate = plan / "tasks.md"
        if candidate.is_file():
            return f"--plan must point at the tasks.md file, not the task directory. Use: --plan {candidate}"
        return f"--plan must point at a tasks.md file; {plan} is a directory and contains no tasks.md"
    return f"plan file does not exist: {plan}"


def _main_locked(args) -> int:
    try:
        if not args.plan.is_file():
            raise EditError(_bad_plan_message(args.plan))
        if args.command == "phase-add":
            old_fingerprint = _check_expected(args.plan, args.expected_fingerprint)
            payload = _phase_add_command(args, _validated_state(args.plan), old_fingerprint)
        elif args.command == "reopen":
            old_fingerprint = _check_expected(args.plan, args.expected_fingerprint)
            payload = _reopen_command(args, _validated_state(args.plan), old_fingerprint)
        elif args.command in STRUCTURAL_COMMANDS:
            old_fingerprint = _check_expected(args.plan, args.expected_fingerprint)
            state = _validated_state(args.plan)
            lines, result = _structural_edit(args, state)
            candidate = _text(lines)
            usage, _ = _preflight(args.plan, candidate)
            payload = _candidate_payload(
                args.plan,
                args.plan,
                args.command,
                old_fingerprint,
                candidate,
                usage,
                result,
                args.dry_run,
            )
        elif args.command in SECTION_COMMANDS:
            target, candidate, result = _section_edit(args)
            old_fingerprint = _check_expected(target, args.expected_fingerprint)
            usage = _preflight_target(args.plan, target, candidate)
            payload = _candidate_payload(
                args.plan, target, args.command, old_fingerprint, candidate, usage, result, args.dry_run
            )
        elif args.command == "decision-supersede":
            target = _resolve_target(args.plan, "decisions.md")
            old_fingerprint = _check_expected(target, args.expected_fingerprint)
            candidate = _text(
                _decision_supersede(
                    target.read_text(encoding="utf-8").splitlines(),
                    args.decision,
                    args.replacement,
                    args.reason,
                )
            )
            usage = _preflight_target(args.plan, target, candidate)
            payload = _candidate_payload(
                args.plan,
                target,
                args.command,
                old_fingerprint,
                candidate,
                usage,
                {"decision": args.decision, "replacement": args.replacement},
                args.dry_run,
            )
        elif args.command == "archive-phase":
            old_fingerprint = _check_expected(args.plan, args.expected_fingerprint)
            payload = _archive_phase(args, _validated_state(args.plan), old_fingerprint)
        elif args.command == "compact-oldest":
            old_fingerprint = _check_expected(args.plan, args.expected_fingerprint)
            payload = _compact_oldest(args, _validated_state(args.plan), old_fingerprint)
        elif args.command == "archive-entry":
            old_fingerprint = _check_expected(args.plan, args.expected_fingerprint)
            payload = _archive_entry(args, old_fingerprint)
        elif args.command == "pause":
            old_fingerprint = _check_expected(args.plan, args.expected_fingerprint)
            payload = _pause_command(args, _validated_state(args.plan), old_fingerprint)
        elif args.command == "handoff-write":
            target = _resolve_target(args.plan, "handoff.md")
            old_fingerprint = _check_optional_expected(target, args.expected_fingerprint)
            content = args.content.rstrip() + "\n"
            problems = _handoff_problems(args.plan, target, content)
            if problems:
                # Report every defect at once. Surfacing them one per attempt
                # made a single handoff cost several round trips: fix headings,
                # rerun, learn about timestamps, rerun, learn about the budget.
                raise EditError("handoff content is invalid: " + "; ".join(problems))
            usage = _preflight_target(args.plan, target, content)
            payload = _candidate_payload(
                args.plan,
                target,
                args.command,
                old_fingerprint,
                content,
                usage,
                {},
                args.dry_run,
            )
        else:
            target = _resolve_target(args.plan, "handoff.md")
            old_fingerprint = _check_optional_expected(target, args.expected_fingerprint)
            if old_fingerprint == "missing":
                raise EditError("handoff.md is already absent")
            if not args.dry_run:
                target.unlink()
            payload = {
                "ok": True,
                "operation": args.command,
                "dry_run": args.dry_run,
                "file": str(target),
                "old_fingerprint": old_fingerprint,
                "fingerprint": "missing",
                "context": context_payload(parse_plan(args.plan)),
                "budgets": budget_payload(args.plan),
            }
        payload["plan"] = str(args.plan)
        print(json.dumps(payload, separators=(",", ":")))
        return 0
    except (EditError, OSError, ValueError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, separators=(",", ":")))
        return 2


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        args.plan = resolve_plan_argument(args.plan)
        with _plan_lock(args.plan):
            _recover_transaction(args.plan)
            return _main_locked(args)
    except (EditError, OSError, ValueError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, separators=(",", ":")))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
