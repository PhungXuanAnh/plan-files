#!/usr/bin/env python3
"""Atomically transition a contracted planning-with-files item."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Iterable

from plan_state import (
    ITEM_ID_RE,
    PHASE_RE,
    PLACEHOLDER_EVIDENCE,
    STATUS_RE,
    SETTLED,
    finalizability_issues,
    parse_plan,
    progress_fingerprint,
)


class CheckpointError(RuntimeError):
    pass


def _clean_evidence(value: str) -> str:
    evidence = " ".join(value.split()).strip()
    if evidence.lower() in PLACEHOLDER_EVIDENCE:
        raise CheckpointError("evidence must be concise and non-placeholder")
    return evidence


def _replace_section_body(lines: list[str], heading: str, value: str | None) -> None:
    indices = [index for index, line in enumerate(lines) if line.strip() == heading]
    if len(indices) != 1:
        raise CheckpointError(f"expected exactly one {heading} section")
    start = indices[0]
    end = next((index for index in range(start + 1, len(lines)) if lines[index].startswith("## ")), len(lines))
    replacement = [value] if value else []
    lines[start + 1 : end] = replacement + ([""] if end < len(lines) else [])


def _set_phase_status(lines: list[str], phase_num: int, status: str) -> None:
    headings = [(index, PHASE_RE.match(line)) for index, line in enumerate(lines)]
    headings = [(index, match) for index, match in headings if match]
    target_offset = next((offset for offset, (_, match) in enumerate(headings) if int(match.group(1)) == phase_num), None)
    if target_offset is None:
        raise CheckpointError(f"Phase {phase_num} does not exist")
    heading_index, match = headings[target_offset]
    end = headings[target_offset + 1][0] if target_offset + 1 < len(headings) else next(
        (index for index in range(heading_index + 1, len(lines)) if lines[index].startswith("## ")),
        len(lines),
    )
    if match.group(3):
        lines[heading_index] = re.sub(r"\[(complete|in_progress|pending)\]\s*$", f"[{status}]", lines[heading_index])
        return
    status_indices = [index for index in range(heading_index + 1, end) if STATUS_RE.match(lines[index])]
    if len(status_indices) != 1:
        raise CheckpointError(f"Phase {phase_num} must have exactly one body status")
    lines[status_indices[0]] = f"- **Status:** {status}"


def _atomic_write(path: Path, lines: list[str]) -> None:
    text = "\n".join(lines) + "\n"
    mode = path.stat().st_mode
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _validate_for_transition(plan: Path, allowed_issues: set[str] | None = None):
    state = parse_plan(plan)
    unexpected = [issue for issue in state.issues if issue not in (allowed_issues or set())]
    if unexpected:
        raise CheckpointError(f"plan contract invalid: {unexpected[0]}")
    if not state.contracted:
        raise CheckpointError("plan has no outcome-item contract; add ## Active Item first")
    return state


def _set_item_evidence(lines: list[str], item, evidence: str, checked: bool | None = None) -> None:
    if item.evidence_index is None:
        raise CheckpointError(f"{item.item_id} has no Evidence line")
    lines[item.evidence_index] = f"  - Evidence: {evidence}"
    if checked is not None:
        mark = "x" if checked else " "
        lines[item.line_index] = re.sub(r"^- \[[ xX]\]", f"- [{mark}]", lines[item.line_index], count=1)


def _next_unchecked(state, completed_id: str):
    current_phase = state.phase(state.current_phase) if state.current_phase is not None else None
    if current_phase:
        for item in current_phase.items:
            if item.item_id != completed_id and not item.checked:
                return current_phase, item
    current_index = next((index for index, phase in enumerate(state.phases) if phase.num == state.current_phase), -1)
    for phase in state.phases[current_index + 1 :]:
        if phase.status in SETTLED:
            continue
        item = next((candidate for candidate in phase.items if not candidate.checked), None)
        if not item or not item.item_id:
            raise CheckpointError(f"Phase {phase.num} has no contracted unchecked item")
        return phase, item
    return None, None


def start(plan: Path, item_id: str) -> dict[str, object]:
    state = _validate_for_transition(plan, {"ACTIVE_ITEM_REQUIRED"})
    item = state.item(item_id)
    if not item or item.checked:
        raise CheckpointError(f"{item_id} is not an unchecked contracted item")
    if state.active_item and state.active_item != item_id:
        raise CheckpointError(f"{state.active_item} is already active")
    if state.current_phase not in {None, item.phase_num}:
        current = state.phase(state.current_phase)
        if not current or current.status not in SETTLED:
            raise CheckpointError(f"Current Phase {state.current_phase} is still actionable")

    lines = list(state.lines)
    _replace_section_body(lines, "## Current Phase", f"Phase {item.phase_num}")
    _replace_section_body(lines, "## Active Item", item_id)
    phase = state.phase(item.phase_num)
    if phase and phase.status == "pending":
        _set_phase_status(lines, item.phase_num, "in_progress")
    _atomic_write(plan, lines)
    new_state = _validate_for_transition(plan)
    return {"operation": "start", "item": item_id, "phase": item.phase_num, "fingerprint": progress_fingerprint(new_state)}


def progress(plan: Path, item_id: str, evidence_value: str) -> dict[str, object]:
    state = _validate_for_transition(plan)
    if state.active_item != item_id:
        raise CheckpointError(f"{item_id} is not Active Item")
    item = state.item(item_id)
    if not item or item.checked:
        raise CheckpointError(f"{item_id} is not an unchecked contracted item")
    lines = list(state.lines)
    _set_item_evidence(lines, item, _clean_evidence(evidence_value))
    _atomic_write(plan, lines)
    new_state = _validate_for_transition(plan)
    return {"operation": "progress", "item": item_id, "phase": item.phase_num, "fingerprint": progress_fingerprint(new_state)}


def complete(plan: Path, item_id: str, evidence_value: str, requested_next: str | None, deactivate: bool) -> dict[str, object]:
    state = _validate_for_transition(plan)
    if state.active_item != item_id:
        raise CheckpointError(f"{item_id} is not Active Item")
    item = state.item(item_id)
    if not item or item.checked:
        raise CheckpointError(f"{item_id} is not an unchecked contracted item")

    next_phase, next_item = _next_unchecked(state, item_id)
    if requested_next and (not next_item or requested_next != next_item.item_id):
        expected = next_item.item_id if next_item else "none"
        raise CheckpointError(f"next item must be {expected}")
    if deactivate and next_item:
        raise CheckpointError("cannot deactivate pointer while another item remains actionable")

    lines = list(state.lines)
    _set_item_evidence(lines, item, _clean_evidence(evidence_value), checked=True)
    if next_phase and next_phase.num == item.phase_num:
        _replace_section_body(lines, "## Active Item", next_item.item_id)
    else:
        _set_phase_status(lines, item.phase_num, "complete")
        if next_phase and next_item:
            _replace_section_body(lines, "## Current Phase", f"Phase {next_phase.num}")
            _replace_section_body(lines, "## Active Item", next_item.item_id)
            if next_phase.status == "pending":
                _set_phase_status(lines, next_phase.num, "in_progress")
        else:
            _replace_section_body(lines, "## Active Item", None)

    _atomic_write(plan, lines)
    new_state = _validate_for_transition(plan)
    all_settled = all(phase.status in SETTLED for phase in new_state.phases)
    if deactivate:
        project_root = plan.parents[3]
        pointer = project_root / ".plan-with-files"
        if pointer.is_file() and pointer.read_text(encoding="utf-8").strip() == plan.parent.name:
            pointer.write_text("", encoding="utf-8")
    return {
        "operation": "complete",
        "item": item_id,
        "phase": item.phase_num,
        "next_item": next_item.item_id if next_item else None,
        "all_settled": all_settled,
        "fingerprint": progress_fingerprint(new_state),
    }


def assert_finalizable(plan: Path, project_root: Path | None) -> dict[str, object]:
    state = parse_plan(plan)
    issues = finalizability_issues(state, project_root)
    if issues:
        raise CheckpointError(f"plan is not finalizable: {issues[0]}")
    return {"operation": "assert-finalizable", "finalizable": True, "fingerprint": progress_fingerprint(state)}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True, type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)

    start_parser = subparsers.add_parser("start")
    start_parser.add_argument("item")

    progress_parser = subparsers.add_parser("progress")
    progress_parser.add_argument("item")
    progress_parser.add_argument("--evidence", required=True)

    complete_parser = subparsers.add_parser("complete")
    complete_parser.add_argument("item")
    complete_parser.add_argument("--evidence", required=True)
    complete_parser.add_argument("--next")
    complete_parser.add_argument("--deactivate-pointer", action="store_true")

    final_parser = subparsers.add_parser("assert-finalizable")
    final_parser.add_argument("--project-root", type=Path)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "start":
            payload = start(args.plan, args.item)
        elif args.command == "progress":
            payload = progress(args.plan, args.item, args.evidence)
        elif args.command == "complete":
            payload = complete(args.plan, args.item, args.evidence, args.next, args.deactivate_pointer)
        else:
            payload = assert_finalizable(args.plan, args.project_root)
    except (CheckpointError, OSError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, separators=(",", ":")))
        return 2
    print(json.dumps({"ok": True, **payload}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
