#!/usr/bin/env python3
"""Parse and validate planning-with-files outcome-item state."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


PHASE_RE = re.compile(r"^### Phase\s+(\d+):\s+(.+?)(?:\s+\[(complete|in_progress|pending)\])?\s*$")
CHECKBOX_RE = re.compile(r"^- \[([ xX])\](?: \[([PV]\d+\.\d+)\])?\s+(.+)$")
ITEM_ID_RE = re.compile(r"^[PV](\d+)\.(\d+)$")
EVIDENCE_RE = re.compile(r"^  - Evidence:\s*(.*)$")
STATUS_RE = re.compile(r"^- \*\*Status:\*\*\s+(complete|in_progress|pending|blocked|deferred)(?:\s+\((.+)\))?\s*$")
SETTLED = {"complete", "blocked", "deferred"}
PLACEHOLDER_EVIDENCE = {"", "pending", "none", "n/a", "todo", "tbd"}


@dataclass
class Item:
    item_id: str | None
    phase_num: int
    line_index: int
    checked: bool
    text: str
    evidence_index: int | None
    evidence: str


@dataclass
class Phase:
    num: int
    title: str
    status: str
    heading_index: int
    end_index: int
    items: list[Item]

    @property
    def contracted(self) -> bool:
        return self.status not in SETTLED or any(item.item_id for item in self.items)


@dataclass
class PlanState:
    path: Path
    lines: list[str]
    contracted: bool
    current_phase: int | None
    active_item: str | None
    phases: list[Phase]
    issues: list[str]

    @property
    def items(self) -> list[Item]:
        return [item for phase in self.phases for item in phase.items if item.item_id]

    def item(self, item_id: str) -> Item | None:
        return next((item for item in self.items if item.item_id == item_id), None)

    def phase(self, num: int) -> Phase | None:
        return next((phase for phase in self.phases if phase.num == num), None)


def _section_indices(lines: list[str], heading: str) -> list[int]:
    return [index for index, line in enumerate(lines) if line.strip() == heading]


def _section_end(lines: list[str], start: int) -> int:
    for index in range(start + 1, len(lines)):
        if lines[index].startswith("## "):
            return index
    return len(lines)


def _visible_body(lines: list[str], start: int, end: int) -> list[str]:
    visible: list[str] = []
    in_comment = False
    for line in lines[start + 1 : end]:
        stripped = line.strip()
        if "<!--" in stripped:
            in_comment = True
        if not in_comment and stripped:
            visible.append(stripped)
        if "-->" in stripped:
            in_comment = False
    return visible


def _phase_status(lines: list[str], start: int, end: int, inline: str | None) -> str:
    if inline:
        return inline
    for line in lines[start + 1 : end]:
        match = STATUS_RE.match(line)
        if match:
            status, reason = match.groups()
            if status in {"blocked", "deferred"} and not (reason or "").strip():
                return ""
            return status
    return ""


def _phase_items(lines: list[str], phase_num: int, start: int, end: int) -> list[Item]:
    items: list[Item] = []
    checkbox_indices = [index for index in range(start + 1, end) if CHECKBOX_RE.match(lines[index])]
    for offset, line_index in enumerate(checkbox_indices):
        match = CHECKBOX_RE.match(lines[line_index])
        assert match is not None
        mark, item_id, text = match.groups()
        item_end = checkbox_indices[offset + 1] if offset + 1 < len(checkbox_indices) else end
        evidence_matches = [
            (index, EVIDENCE_RE.match(lines[index]))
            for index in range(line_index + 1, item_end)
            if EVIDENCE_RE.match(lines[index])
        ]
        evidence_index = evidence_matches[0][0] if len(evidence_matches) == 1 else None
        evidence = evidence_matches[0][1].group(1).strip() if len(evidence_matches) == 1 else ""
        items.append(
            Item(
                item_id=item_id,
                phase_num=phase_num,
                line_index=line_index,
                checked=mark.lower() == "x",
                text=text.strip(),
                evidence_index=evidence_index,
                evidence=evidence,
            )
        )
    return items


def parse_plan(path: Path) -> PlanState:
    lines = path.read_text(encoding="utf-8").splitlines()
    issues: list[str] = []

    current_sections = _section_indices(lines, "## Current Phase")
    active_sections = _section_indices(lines, "## Active Item")
    phases_sections = _section_indices(lines, "## Phases")
    contracted = bool(active_sections)

    current_phase: int | None = None
    if len(current_sections) == 1:
        body = _visible_body(lines, current_sections[0], _section_end(lines, current_sections[0]))
        if len(body) == 1 and re.fullmatch(r"Phase\s+(\d+)", body[0]):
            current_phase = int(re.fullmatch(r"Phase\s+(\d+)", body[0]).group(1))  # type: ignore[union-attr]

    active_item: str | None = None
    if contracted:
        if len(active_sections) != 1 or len(current_sections) != 1 or len(phases_sections) != 1:
            issues.append("ACTIVE_ITEM_SECTION_INVALID")
        elif not (current_sections[0] < active_sections[0] < phases_sections[0]):
            issues.append("ACTIVE_ITEM_SECTION_INVALID")
        else:
            body = _visible_body(lines, active_sections[0], _section_end(lines, active_sections[0]))
            if len(body) > 1 or (body and not ITEM_ID_RE.fullmatch(body[0])):
                issues.append("ACTIVE_ITEM_SECTION_INVALID")
            elif body:
                active_item = body[0]

    phases: list[Phase] = []
    phase_headings: list[tuple[int, re.Match[str]]] = []
    if len(phases_sections) == 1:
        for index in range(phases_sections[0] + 1, len(lines)):
            if lines[index].startswith("## "):
                break
            match = PHASE_RE.match(lines[index])
            if match:
                phase_headings.append((index, match))

    phases_end = _section_end(lines, phases_sections[0]) if len(phases_sections) == 1 else len(lines)
    for offset, (heading_index, match) in enumerate(phase_headings):
        end_index = phase_headings[offset + 1][0] if offset + 1 < len(phase_headings) else phases_end
        num = int(match.group(1))
        phases.append(
            Phase(
                num=num,
                title=match.group(2),
                status=_phase_status(lines, heading_index, end_index, match.group(3)),
                heading_index=heading_index,
                end_index=end_index,
                items=_phase_items(lines, num, heading_index, end_index),
            )
        )

    if contracted:
        seen: set[str] = set()
        for phase in phases:
            if not phase.contracted:
                continue
            for item in phase.items:
                if not item.item_id:
                    issues.append("ITEM_ID_INVALID")
                    continue
                if item.item_id in seen:
                    issues.append("ITEM_ID_DUPLICATE")
                seen.add(item.item_id)
                id_match = ITEM_ID_RE.fullmatch(item.item_id)
                if not id_match or int(id_match.group(1)) != phase.num:
                    issues.append("ITEM_PHASE_MISMATCH")
                if item.evidence_index is None:
                    issues.append("ITEM_EVIDENCE_MISSING")
                if item.checked and item.evidence.strip().lower() in PLACEHOLDER_EVIDENCE:
                    issues.append("CHECKED_ITEM_EVIDENCE_PENDING")

        all_settled = bool(phases) and all(phase.status in SETTLED for phase in phases)
        if all_settled and active_item:
            issues.append("ACTIVE_ITEM_INVALID")
        elif active_item:
            active = next((item for phase in phases for item in phase.items if item.item_id == active_item), None)
            if not active or active.checked or current_phase != active.phase_num:
                issues.append("ACTIVE_ITEM_INVALID")
        elif current_phase is not None:
            phase = next((candidate for candidate in phases if candidate.num == current_phase), None)
            if phase and phase.status == "in_progress" and any(not item.checked for item in phase.items):
                issues.append("ACTIVE_ITEM_REQUIRED")

    return PlanState(
        path=path,
        lines=lines,
        contracted=contracted,
        current_phase=current_phase,
        active_item=active_item,
        phases=phases,
        issues=list(dict.fromkeys(issues)),
    )


def progress_fingerprint(state: PlanState) -> str:
    canonical: list[str] = [f"current={state.current_phase or ''}", f"active={state.active_item or ''}"]
    for phase in state.phases:
        canonical.append(f"phase={phase.num}:{phase.status}")
        for item in phase.items:
            canonical.append(
                "item={}:{:d}:{}:{}".format(
                    item.item_id or f"legacy@{item.line_index}",
                    int(item.checked),
                    item.text,
                    item.evidence,
                )
            )
    blocker_sections = _section_indices(state.lines, "## Resume Checkpoint")
    if len(blocker_sections) == 1:
        for line in _visible_body(state.lines, blocker_sections[0], _section_end(state.lines, blocker_sections[0])):
            if line.startswith("- **Blocker:**") or line.startswith("- **Next action:**"):
                canonical.append(line)
    return hashlib.sha256("\n".join(canonical).encode()).hexdigest()[:16]


def first_unchecked(state: PlanState) -> Item | None:
    phase = state.phase(state.current_phase) if state.current_phase is not None else None
    return next((item for item in (phase.items if phase else []) if not item.checked), None)


def context_payload(state: PlanState) -> dict[str, object]:
    active = state.item(state.active_item) if state.active_item else None
    first = first_unchecked(state)
    return {
        "contracted": state.contracted,
        "current_phase": state.current_phase,
        "active_item": state.active_item,
        "active_text": active.text if active else "",
        "active_evidence": active.evidence if active else "",
        "first_unchecked_item": first.item_id if first else None,
        "first_unchecked_text": first.text if first else "",
        "fingerprint": progress_fingerprint(state),
        "issue": state.issues[0] if state.issues else "",
    }


# One line of self-sufficient prose per code that can appear in state.issues /
# finalizability_issues() — so an assert-finalizable/checkpoint caller never
# has to read this file to learn what a bare code means. Codes computed only
# on the bash side (SECTION_LAYOUT_INVALID, PHASE_HEADING_INVALID, NO_PHASES,
# PHASE_STATUS_INVALID, BLOCKED_NO_REASON, DEFERRED_NO_REASON,
# PROFILE_MISSING, PROFILE_UNFILLED) never reach this Python path and are not
# listed here; see common.sh's task_plan_format_message for those.
ISSUE_EXPLANATIONS: dict[str, str] = {
    "ACTIVE_ITEM_SECTION_INVALID": (
        '"## Active Item" must appear exactly once, after "## Current Phase" and before '
        '"## Phases", with a body that is empty or exactly one existing "P<phase>.<n>" / '
        '"V<phase>.<n>" ID'
    ),
    "ACTIVE_ITEM_REQUIRED": (
        "Current Phase is in_progress with an unchecked item, but Active Item is empty — "
        "set it to exactly one unchecked P/V ID from that phase"
    ),
    "ACTIVE_ITEM_INVALID": (
        "Active Item names an ID that does not exist, is already checked, or belongs to a "
        "different phase than Current Phase — or every phase is settled while Active Item "
        "is still non-empty; clear it once settled, otherwise point it at a valid unchecked ID"
    ),
    "ITEM_ID_INVALID": (
        "a checkbox in a contracted phase has no [P<phase>.<n>] / [V<phase>.<n>] ID right "
        "after the checkbox mark"
    ),
    "ITEM_ID_DUPLICATE": "the same P/V ID is used on more than one checkbox — every ID must be unique",
    "ITEM_PHASE_MISMATCH": (
        "a checkbox ID's phase number does not match the ### Phase heading it is written under"
    ),
    "ITEM_EVIDENCE_MISSING": (
        'a checkbox in a contracted phase has no indented "  - Evidence: ..." line beneath it'
    ),
    "CHECKED_ITEM_EVIDENCE_PENDING": (
        'an item is checked "[x]" but its Evidence line is still a placeholder '
        "(empty/pending/none/n-a/todo/tbd) — replace it with concrete evidence or uncheck the item"
    ),
    "PHASES_ACTIONABLE": "at least one phase is not yet complete, blocked, or deferred",
    "STATUS_LIES": "a phase is marked complete but still has an unchecked item beneath it",
    "POINTER_ACTIVE": (
        ".plan-with-files still names this task — pass --deactivate-pointer on the final "
        "`complete` call (or clear .plan-with-files directly) before this plan can finalize"
    ),
}


def explain_issue(code: str) -> str:
    explanation = ISSUE_EXPLANATIONS.get(code)
    return f"{code} ({explanation})" if explanation else code


def explain_issues(codes: Iterable[str]) -> str:
    return "; ".join(explain_issue(code) for code in codes)


def finalizability_issues(state: PlanState, project_root: Path | None = None) -> list[str]:
    issues = list(state.issues)
    if not state.phases or any(phase.status not in SETTLED for phase in state.phases):
        issues.append("PHASES_ACTIONABLE")
    if any(phase.status == "complete" and any(not item.checked for item in phase.items) for phase in state.phases):
        issues.append("STATUS_LIES")
    if state.active_item:
        issues.append("ACTIVE_ITEM_INVALID")
    if project_root:
        pointer = project_root / ".plan-with-files"
        if pointer.is_file() and pointer.read_text(encoding="utf-8").strip() == state.path.parent.name:
            issues.append("POINTER_ACTIVE")
    return list(dict.fromkeys(issues))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("validate", "fingerprint", "context", "assert-finalizable"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("plan", type=Path)
        if command == "assert-finalizable":
            subparser.add_argument("--project-root", type=Path)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    state = parse_plan(args.plan)
    if args.command == "validate":
        # Deliberately single-code, unlike assert-finalizable below: common.sh's
        # planning_item_contract_issue() passes this line straight into a bash
        # `case` match against exact issue-code literals. Printing more than one
        # code here would break that match silently (no case would fire), so
        # keep validate() reporting only the first issue.
        if state.issues:
            print(state.issues[0])
            return 2
        return 0
    if args.command == "fingerprint":
        print(progress_fingerprint(state))
        return 0
    if args.command == "context":
        print(json.dumps(context_payload(state), separators=(",", ":")))
        return 0
    issues = finalizability_issues(state, args.project_root)
    if issues:
        print(explain_issues(issues))
        return 2
    print("FINALIZABLE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
