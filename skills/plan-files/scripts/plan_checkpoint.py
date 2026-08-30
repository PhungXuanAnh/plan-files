#!/usr/bin/env python3
"""Atomically transition a contracted plan-files item."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Iterable

from plan_state import (
    file_fingerprint,
    pointer_path,
    ITEM_ID_RE,
    PHASE_RE,
    PLACEHOLDER_EVIDENCE,
    STATUS_RE,
    SETTLED,
    explain_issues,
    finalizability_issues,
    parse_plan,
    progress_fingerprint,
)


class CheckpointError(RuntimeError):
    pass


def _resolve_project_root(start: Path) -> Path:
    """Resolve the true project root from a directory, via the shared resolver.

    A fixed parent-count (e.g. `plan.parents[3]`) breaks the moment a plan
    lives somewhere the storage model's usual depth doesn't hold — a
    submodule, a non-git multi-repo workspace, or any other layout the
    shared resolver already handles. Delegate to it instead of assuming.
    """
    resolver = Path(__file__).resolve().parent / "resolve-project-root.sh"
    result = subprocess.run(
        ["bash", str(resolver), str(start)],
        capture_output=True,
        text=True,
        check=False,
    )
    output = result.stdout.strip()
    return Path(output) if output else start


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


def _set_resume_field(lines: list[str], label: str, value: str) -> None:
    indices = [index for index, line in enumerate(lines) if line.strip() == "## Resume Checkpoint"]
    if not indices:
        return
    if len(indices) != 1:
        raise CheckpointError('expected exactly one "## Resume Checkpoint" section')
    start = indices[0]
    end = next((index for index in range(start + 1, len(lines)) if lines[index].startswith("## ")), len(lines))
    prefix = f"- **{label}:**"
    matches = [index for index in range(start + 1, end) if lines[index].startswith(prefix)]
    if not matches:
        return
    if len(matches) != 1:
        raise CheckpointError(f"Resume Checkpoint must contain exactly one {prefix} field")
    lines[matches[0]] = f"{prefix} {value}"


def _next_action(item) -> str:
    return f"Complete {item.item_id}: {item.text}"


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
        raise CheckpointError(f"plan contract invalid: {explain_issues(unexpected)}")
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
    _set_resume_field(lines, "Next action", _next_action(item))
    _set_resume_field(lines, "Blocker", "none")
    phase = state.phase(item.phase_num)
    if phase and phase.status == "pending":
        _set_phase_status(lines, item.phase_num, "in_progress")
    _atomic_write(plan, lines)
    new_state = _validate_for_transition(plan)
    return {"operation": "start", "item": item_id, "phase": item.phase_num, **_fingerprints(new_state)}


def _fingerprints(state) -> dict[str, str]:
    """Both hashes, under names that say which is which.

    `fingerprint` is the 16-hex semantic progress hash used to detect that the
    plan advanced. `file_fingerprint` is the full SHA-256 of the file and is the
    only value `plan_edit.py --expected-fingerprint` accepts. Emitting only the
    former made the two look interchangeable, so passing it to plan_edit failed
    with a "stale fingerprint" error that reads like a concurrent write.
    """
    return {
        "fingerprint": progress_fingerprint(state),
        "file_fingerprint": file_fingerprint(state.path),
    }


def progress(plan: Path, item_id: str, evidence_value: str) -> dict[str, object]:
    state = _validate_for_transition(plan)
    if state.active_item != item_id:
        raise CheckpointError(f"{item_id} is not Active Item")
    item = state.item(item_id)
    if not item or item.checked:
        raise CheckpointError(f"{item_id} is not an unchecked contracted item")
    lines = list(state.lines)
    _set_item_evidence(lines, item, _clean_evidence(evidence_value))
    _set_resume_field(lines, "Next action", _next_action(item))
    _atomic_write(plan, lines)
    new_state = _validate_for_transition(plan)
    return {"operation": "progress", "item": item_id, "phase": item.phase_num, **_fingerprints(new_state)}


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
    if next_item:
        _set_resume_field(lines, "Next action", _next_action(next_item))
        _set_resume_field(lines, "Blocker", "none")
    else:
        _set_resume_field(lines, "Next action", "Run finalization checks and close the completed task")
        _set_resume_field(lines, "Blocker", "none")

    _atomic_write(plan, lines)
    new_state = _validate_for_transition(plan)
    all_settled = all(phase.status in SETTLED for phase in new_state.phases)
    if deactivate:
        project_root = _resolve_project_root(plan.parent.resolve())
        pointer = pointer_path(project_root)
        if pointer.is_file() and pointer.read_text(encoding="utf-8").strip() == plan.parent.name:
            pointer.write_text("", encoding="utf-8")
    return {
        "operation": "complete",
        "item": item_id,
        "phase": item.phase_num,
        "next_item": next_item.item_id if next_item else None,
        "all_settled": all_settled,
        **_fingerprints(new_state),
    }


def assert_finalizable(plan: Path, project_root: Path | None) -> dict[str, object]:
    state = parse_plan(plan)
    issues = finalizability_issues(state, project_root)
    if issues:
        raise CheckpointError(f"plan is not finalizable: {explain_issues(issues)}")
    return {"operation": "assert-finalizable", "finalizable": True, **_fingerprints(state)}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Execution transitions for a planning task. Use this instead of editing the "
            "checkbox, phase status, Current Phase, and Active Item separately."
        ),
    )
    parser.add_argument(
        "--plan", required=True, type=Path, help="path to the plan's tasks.md file (not the task directory)"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    start_parser = subparsers.add_parser("start", help="make an item the Active Item and open its phase")
    start_parser.add_argument("item", help="item id in Current Phase, e.g. P2.1")

    progress_parser = subparsers.add_parser(
        "progress", help="record partial or error evidence while the outcome is still false"
    )
    progress_parser.add_argument("item", help="the current Active Item id")
    progress_parser.add_argument("--evidence", required=True, help="observable partial state, not an activity log")

    complete_parser = subparsers.add_parser(
        "complete", help="check the item off and advance Active Item / Current Phase"
    )
    complete_parser.add_argument("item", help="the current Active Item id")
    complete_parser.add_argument(
        "--evidence", required=True, help="concrete non-placeholder evidence that the outcome is now true"
    )
    complete_parser.add_argument("--next", help="assert the expected next item id; fails if it differs")
    complete_parser.add_argument(
        "--deactivate-pointer",
        action="store_true",
        help="required on the call whose result reports \"next_item\":null, else finalization fails with POINTER_ACTIVE",
    )

    final_parser = subparsers.add_parser(
        "assert-finalizable", help="verify every phase is settled and the plan can be closed"
    )
    final_parser.add_argument("--project-root", type=Path, help="workspace root that owns .plan-files")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.plan.is_dir():
            candidate = args.plan / "tasks.md"
            hint = (
                f"--plan must point at the tasks.md file, not the task directory. Use: --plan {candidate}"
                if candidate.is_file()
                else f"--plan must point at a tasks.md file; {args.plan} is a directory"
            )
            raise CheckpointError(hint)
        if not args.plan.is_file():
            raise CheckpointError(f"plan file does not exist: {args.plan}")
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
