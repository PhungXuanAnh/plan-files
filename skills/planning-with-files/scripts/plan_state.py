#!/usr/bin/env python3
"""Parse and validate planning-with-files outcome-item state."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


PHASE_RE = re.compile(r"^### Phase\s+(\d+):\s+(.+?)(?:\s+\[(complete|in_progress|pending)\])?\s*$")
CHECKBOX_RE = re.compile(r"^- \[([ xX])\](?: \[([PV]\d+\.\d+)\])?\s+(.+)$")
ITEM_ID_RE = re.compile(r"^[PV](\d+)\.(\d+)$")
EVIDENCE_RE = re.compile(r"^  - Evidence:\s*(.*)$")
STATUS_RE = re.compile(r"^- \*\*Status:\*\*\s+(complete|in_progress|pending|blocked|deferred)(?:\s+\((.+)\))?\s*$")
SETTLED = {"complete", "blocked", "deferred"}
PLACEHOLDER_EVIDENCE = {"", "pending", "none", "n/a", "todo", "tbd"}
PLACEHOLDER_TEXT = {"", "-", "pending", "todo", "tbd", "n/a", "na", "unknown"}
FILE_BUDGETS: dict[str, tuple[int, int]] = {
    "tasks.md": (300, 24 * 1024),
    "findings.md": (250, 32 * 1024),
    "decisions.md": (150, 12 * 1024),
    "handoff.md": (50, 6 * 1024),
}
TASKS_PHASE_LIMIT = 12
TASKS_ITEM_LIMIT = 100
CURRENT_PHASE_ITEM_LIMIT = 15
CURRENT_PHASE_BYTE_LIMIT = 4 * 1024
DEFAULT_VIEW_CHARS = 4 * 1024
DEFAULT_OVERVIEW_CHARS = 4 * 1024
MIN_OVERVIEW_CHARS = 2 * 1024
ACTIVE_TEXT_CHARS = 300
ACTIVE_EVIDENCE_CHARS = 500
EXTERNAL_STATE_RE = re.compile(
    r"\[external-state\s+observed=([^\s\]]+)\s+reverify-after=([^\s\]]+)\]",
    re.IGNORECASE,
)


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


def file_fingerprint(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _bounded_text(text: str, max_chars: int) -> tuple[str, bool]:
    if max_chars <= 0 or len(text) <= max_chars:
        return text, False
    return text[:max_chars], True


def section_text(path: Path, heading: str) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    label = heading if heading.startswith("## ") else f"## {heading}"
    indices = _section_indices(lines, label)
    if len(indices) != 1:
        raise ValueError(f"expected exactly one {label} section in {path}")
    return "\n".join(_visible_body(lines, indices[0], _section_end(lines, indices[0])))


def _field_value(text: str, label: str) -> str:
    pattern = re.compile(rf"^- (?:\*\*)?{re.escape(label)}:(?:\*\*)?\s*(.*)$", re.IGNORECASE)
    values = [match.group(1).strip() for line in text.splitlines() if (match := pattern.match(line))]
    return values[0] if len(values) == 1 else ""


def _placeholder(value: str, *, allow_none: bool = False) -> bool:
    normalized = re.sub(r"[`*_]", "", value).strip().lower().rstrip(".")
    if allow_none and normalized in {"none", "no blocker", "no active decisions"}:
        return False
    if normalized in PLACEHOLDER_TEXT or normalized == "none":
        return True
    placeholder_candidate = re.sub(r"^[-*]\s+", "", normalized).strip()
    if re.fullmatch(r"\[[^\]]+\]", placeholder_candidate) or re.fullmatch(
        r"<[^>]+>", placeholder_candidate
    ):
        return True
    return not bool(re.search(r"[a-z0-9]", normalized))


def _section_or_empty(path: Path, heading: str) -> str:
    try:
        return section_text(path, heading)
    except (OSError, ValueError):
        return ""


def _aware_datetime(value: str) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def handoff_metadata(text: str) -> tuple[datetime | None, datetime | None]:
    updated = re.findall(r"^Updated:\s*(.+?)\s*$", text, re.MULTILINE)
    reverify = re.findall(r"^Reverify after:\s*(.+?)\s*$", text, re.MULTILINE)
    if len(updated) != 1 or len(reverify) != 1:
        return None, None
    return _aware_datetime(updated[0]), _aware_datetime(reverify[0])


def handoff_freshness_payload(plan_dir: Path, now: datetime | None = None) -> dict[str, object]:
    handoff = plan_dir / "handoff.md"
    if not handoff.is_file():
        return {"present": False, "state": "absent", "requires_reverification": False, "reasons": []}
    text = handoff.read_text(encoding="utf-8")
    updated, reverify = handoff_metadata(text)
    reasons: list[str] = []
    if updated is None or reverify is None:
        reasons.append("HANDOFF_FRESHNESS_METADATA_INVALID")
    elif reverify <= updated:
        reasons.append("HANDOFF_FRESHNESS_WINDOW_INVALID")
    current = now or datetime.now(timezone.utc)
    if reverify is not None and current >= reverify:
        reasons.append("HANDOFF_EXPIRED")
    newer_files = [
        name
        for name in ("tasks.md", "findings.md", "decisions.md")
        if (plan_dir / name).is_file() and (plan_dir / name).stat().st_mtime_ns > handoff.stat().st_mtime_ns
    ]
    if newer_files:
        reasons.append("HANDOFF_DEPENDENCY_NEWER")
    return {
        "present": True,
        "state": "stale" if reasons else "fresh",
        "updated_at": updated.isoformat() if updated else None,
        "reverify_after": reverify.isoformat() if reverify else None,
        "newer_files": newer_files,
        "requires_reverification": bool(reasons),
        "reasons": reasons,
    }


def external_evidence_freshness(plan: Path, now: datetime | None = None) -> dict[str, object]:
    verification = _section_or_empty(plan, "Verification")
    current = now or datetime.now(timezone.utc)
    entries: list[dict[str, object]] = []
    issues: list[str] = []
    for offset, line in enumerate(verification.splitlines(), start=1):
        if "[external-state" not in line.lower():
            continue
        match = EXTERNAL_STATE_RE.search(line)
        if not match:
            issues.append("EXTERNAL_EVIDENCE_FRESHNESS_METADATA_INVALID")
            entries.append({"line": offset, "state": "invalid"})
            continue
        observed = _aware_datetime(match.group(1))
        reverify = _aware_datetime(match.group(2))
        if observed is None or reverify is None or reverify <= observed:
            issues.append("EXTERNAL_EVIDENCE_FRESHNESS_METADATA_INVALID")
            entries.append({"line": offset, "state": "invalid"})
            continue
        stale = current >= reverify
        if stale:
            issues.append("EXTERNAL_EVIDENCE_STALE")
        entries.append(
            {
                "line": offset,
                "state": "stale" if stale else "fresh",
                "observed_at": observed.isoformat(),
                "reverify_after": reverify.isoformat(),
            }
        )
    return {
        "entries": entries,
        "state": "stale" if issues else ("fresh" if entries else "absent"),
        "requires_reverification": bool(issues),
        "reasons": list(dict.fromkeys(issues)),
    }


def _view_payload(path: Path, selector: dict[str, object], text: str, max_chars: int) -> dict[str, object]:
    bounded, truncated = _bounded_text(text, max_chars)
    return {
        "file": str(path),
        **selector,
        "fingerprint": file_fingerprint(path),
        "text": bounded,
        "chars": len(text),
        "bytes": len(text.encode("utf-8")),
        "truncated": truncated,
    }


def budget_payload(plan: Path) -> dict[str, object]:
    plan_dir = plan.parent
    state = parse_plan(plan)
    files: dict[str, object] = {}
    over: list[str] = []
    for name, (line_limit, byte_limit) in FILE_BUDGETS.items():
        path = plan_dir / name
        if not path.is_file():
            continue
        raw = path.read_bytes()
        lines = raw.count(b"\n") + (1 if raw and not raw.endswith(b"\n") else 0)
        entry = {
            "lines": lines,
            "line_limit": line_limit,
            "bytes": len(raw),
            "byte_limit": byte_limit,
            "over": lines > line_limit or len(raw) > byte_limit,
        }
        files[name] = entry
        if entry["over"]:
            over.append(name)

    current = state.phase(state.current_phase) if state.current_phase is not None else None
    current_text = ""
    if current:
        current_text = "\n".join(state.lines[current.heading_index : current.end_index])
    structure = {
        "phases": len(state.phases),
        "phase_limit": TASKS_PHASE_LIMIT,
        "items": sum(len(phase.items) for phase in state.phases),
        "item_limit": TASKS_ITEM_LIMIT,
        "current_phase_items": len(current.items) if current else 0,
        "current_phase_item_limit": CURRENT_PHASE_ITEM_LIMIT,
        "current_phase_bytes": len(current_text.encode("utf-8")),
        "current_phase_byte_limit": CURRENT_PHASE_BYTE_LIMIT,
    }
    if structure["phases"] > TASKS_PHASE_LIMIT:
        over.append("tasks.md:phases")
    if structure["items"] > TASKS_ITEM_LIMIT:
        over.append("tasks.md:items")
    if structure["current_phase_items"] > CURRENT_PHASE_ITEM_LIMIT:
        over.append("tasks.md:current-phase-items")
    if structure["current_phase_bytes"] > CURRENT_PHASE_BYTE_LIMIT:
        over.append("tasks.md:current-phase-bytes")
    return {
        "plan": str(plan),
        "fingerprint": file_fingerprint(plan),
        "files": files,
        "structure": structure,
        "over": over,
        "ok": not over,
    }


def budget_warning(plan: Path) -> str:
    payload = budget_payload(plan)
    if payload["ok"]:
        return ""
    parts: list[str] = []
    for name, values in payload["files"].items():
        if values["over"]:
            parts.append(
                f"{name}={values['lines']}/{values['line_limit']} lines;"
                f"{values['bytes']}/{values['byte_limit']} bytes"
            )
    structure = payload["structure"]
    labels = {
        "tasks.md:phases": ("phases", "phase_limit", "phase entries"),
        "tasks.md:items": ("items", "item_limit", "item entries"),
        "tasks.md:current-phase-items": (
            "current_phase_items",
            "current_phase_item_limit",
            "current-phase items",
        ),
        "tasks.md:current-phase-bytes": (
            "current_phase_bytes",
            "current_phase_byte_limit",
            "current-phase bytes",
        ),
    }
    for issue in payload["over"]:
        if issue not in labels:
            continue
        actual_key, limit_key, label = labels[issue]
        parts.append(f"tasks.md={structure[actual_key]}/{structure[limit_key]} {label}")
    detail = ", ".join(parts)
    return (
        f"[planning-with-files] COMPACTION NEEDED (actual/target): {detail}. "
        "Keep hot current state; use targeted plan operations to archive completed phases, completed "
        "verification, and resolved errors to history.md; consolidate findings/decisions by lifecycle; "
        "overwrite handoff.md instead of appending. Split independent follow-up work into another task. "
        "Never raw-truncate."
    )


def compact_budget_payload(plan: Path) -> dict[str, object]:
    """Return resume-relevant usage; the `budgets` command keeps full limits."""
    payload = budget_payload(plan)
    structure = payload["structure"]
    assert isinstance(structure, dict)
    files = payload["files"]
    assert isinstance(files, dict)
    return {
        "ok": payload["ok"],
        "over": payload["over"],
        "files": {
            name: [values["lines"], values["bytes"]]
            for name, values in files.items()
            if isinstance(values, dict)
        },
        "structure": {
            "phases": structure["phases"],
            "items": structure["items"],
            "current_phase_items": structure["current_phase_items"],
            "current_phase_bytes": structure["current_phase_bytes"],
        },
        "details": "plan_state.py budgets PLAN",
    }


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
    active_text, _ = _bounded_text(active.text if active else "", ACTIVE_TEXT_CHARS)
    active_evidence, _ = _bounded_text(active.evidence if active else "", ACTIVE_EVIDENCE_CHARS)
    first_text, _ = _bounded_text(first.text if first else "", ACTIVE_TEXT_CHARS)
    return {
        "contracted": state.contracted,
        "current_phase": state.current_phase,
        "active_item": state.active_item,
        "active_text": active_text,
        "active_evidence": active_evidence,
        "first_unchecked_item": first.item_id if first else None,
        "first_unchecked_text": first_text,
        "total_phases": len(state.phases),
        "total_items": sum(len(phase.items) for phase in state.phases),
        "file_fingerprint": file_fingerprint(state.path),
        "fingerprint": progress_fingerprint(state),
        "issue": state.issues[0] if state.issues else "",
    }


def _active_decisions_ready(text: str) -> bool:
    for line in text.splitlines():
        stripped = line.strip()
        normalized = re.sub(r"[`*_]", "", stripped).strip().lower().rstrip(".")
        if normalized in {"- none", "none", "- no active decisions", "no active decisions"}:
            return True
        if stripped.startswith("|") and stripped.endswith("|"):
            cells = [cell.strip() for cell in stripped.strip("|").split("|")]
            if len(cells) >= 2 and cells[0].lower() != "id" and not set(cells[0]) <= {"-", ":"}:
                if not _placeholder(cells[1]):
                    return True
        elif stripped.startswith(('- ', '* ')) and not _placeholder(stripped[2:]):
            return True
    return False


def restore_payload(plan: Path) -> dict[str, object]:
    """Validate that bounded hot state is semantically sufficient to resume."""
    state = parse_plan(plan)
    issues: list[dict[str, str]] = []
    checks: dict[str, bool] = {}

    def record(
        field: str,
        ok: bool,
        code: str,
        source: Path,
        heading: str,
        repair: str,
    ) -> None:
        checks[field] = ok
        if not ok:
            issues.append(
                {
                    "code": code,
                    "field": field,
                    "source": source.name,
                    "heading": heading,
                    "repair": repair,
                }
            )

    goal = _section_or_empty(plan, "Goal")
    record(
        "goal",
        not _placeholder(goal),
        "RESTORE_GOAL_MISSING",
        plan,
        "Goal",
        "replace Goal with one concise, specific end state",
    )

    identity = _section_or_empty(plan, "Task Identity")
    identity_fields = {
        "deliverable": ("Deliverable", False),
        "anchors": ("Anchors", True),
        "non_goals": ("Non-goals", True),
    }
    for field, (label, allow_none) in identity_fields.items():
        value = _field_value(identity, label)
        record(
            f"identity_{field}",
            not _placeholder(value, allow_none=allow_none),
            f"RESTORE_IDENTITY_{field.upper()}_MISSING",
            plan,
            "Task Identity",
            f"set '- {label}:' to a concrete value" + (" or explicit none" if allow_none else ""),
        )

    resume = _section_or_empty(plan, "Resume Checkpoint")
    next_action = _field_value(resume, "Next action")
    next_action_ok = not _placeholder(next_action, allow_none=not state.active_item)
    if state.active_item and state.active_item.lower() not in next_action.lower():
        next_action_ok = False
    record(
        "next_action",
        next_action_ok,
        "RESTORE_NEXT_ACTION_MISSING",
        plan,
        "Resume Checkpoint",
        "name the exact command/edit/outcome to do next and include the Active Item ID",
    )
    blocker = _field_value(resume, "Blocker")
    record(
        "blocker",
        not _placeholder(blocker, allow_none=True),
        "RESTORE_BLOCKER_MISSING",
        plan,
        "Resume Checkpoint",
        "set Blocker to 'none' or name the concrete external dependency",
    )

    actionable = any(phase.status not in SETTLED for phase in state.phases)
    active_ok = not state.contracted or not actionable or (
        state.active_item is not None
        and not any(issue in state.issues for issue in ("ACTIVE_ITEM_INVALID", "ACTIVE_ITEM_REQUIRED"))
    )
    record(
        "active_item",
        active_ok,
        "RESTORE_ACTIVE_ITEM_MISSING",
        plan,
        "Active Item",
        "set Active Item to exactly one unchecked P/V ID in Current Phase",
    )

    verification = _section_or_empty(plan, "Verification")
    record(
        "verification",
        not _placeholder(verification),
        "RESTORE_VERIFICATION_MISSING",
        plan,
        "Verification",
        "list the exact required checks and their latest relevant result",
    )

    decisions = plan.parent / "decisions.md"
    active_decisions = _section_or_empty(decisions, "Active Decisions")
    record(
        "active_decisions",
        _active_decisions_ready(active_decisions),
        "RESTORE_ACTIVE_DECISIONS_MISSING",
        decisions,
        "Active Decisions",
        "record current decision rows or the explicit bullet '- None.'",
    )

    findings = plan.parent / "findings.md"
    findings_summary = _section_or_empty(findings, "Current Summary")
    record(
        "findings_summary",
        not _placeholder(findings_summary),
        "RESTORE_FINDINGS_MISSING",
        findings,
        "Current Summary",
        "summarize the findings relevant to the next action or state explicitly that none are relevant",
    )
    handoff = handoff_freshness_payload(plan.parent)
    checks["handoff_freshness"] = not bool(handoff["requires_reverification"])
    for reason in handoff["reasons"]:
        issues.append(
            {
                "code": str(reason),
                "field": "handoff_freshness",
                "source": "handoff.md",
                "heading": "Handoff metadata",
                "repair": (
                    "ignore and clear the stale handoff, or re-verify volatile state and overwrite it "
                    "with current Updated/Reverify after ISO-8601 timestamps"
                ),
            }
        )
    external = external_evidence_freshness(plan)
    checks["external_evidence_freshness"] = not bool(external["requires_reverification"])
    for reason in external["reasons"]:
        issues.append(
            {
                "code": str(reason),
                "field": "external_evidence_freshness",
                "source": plan.name,
                "heading": "Verification",
                "repair": (
                    "re-run the external check and replace its marker with "
                    "[external-state observed=<ISO-8601> reverify-after=<ISO-8601>]"
                ),
            }
        )
    return {
        "schema_version": 1,
        "ok": not issues,
        "plan": str(plan),
        "active_item": state.active_item,
        "checks": checks,
        "freshness": {"handoff": handoff, "external_evidence": external},
        "issues": issues,
    }


def _overview_dump(payload: dict[str, object]) -> str:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def _overview_metadata(
    payload: dict[str, object],
    sections: dict[str, tuple[Path, str, str]],
    total_max_chars: int,
) -> dict[str, object]:
    truncated: dict[str, object] = {}
    targets: dict[str, list[str]] = {}
    for key, (path, heading, original) in sections.items():
        returned = str(payload.get(key, ""))
        if len(returned) >= len(original):
            continue
        truncated[key] = {
            "chars": len(original),
            "bytes": len(original.encode("utf-8")),
            "lines": len(original.splitlines()),
            "returned_chars": len(returned),
            "returned_lines": len(returned.splitlines()),
            "omitted": not returned,
        }
        targets[key] = [path.name, heading]
    return {
        "schema_version": 2,
        "total_limit_chars": total_max_chars,
        "serialized_chars": 0,
        "truncated_sections": truncated,
        "next_read": {
            "command": "plan_state.py section FILE HEADING --max-chars 0",
            "targets": targets,
        },
    }


def _render_overview(
    payload: dict[str, object],
    sections: dict[str, tuple[Path, str, str]],
    total_max_chars: int,
) -> str:
    payload["view_meta"] = _overview_metadata(payload, sections, total_max_chars)
    for _ in range(4):
        rendered = _overview_dump(payload)
        meta = payload["view_meta"]
        assert isinstance(meta, dict)
        if meta["serialized_chars"] == len(rendered):
            return rendered
        meta["serialized_chars"] = len(rendered)
    return _overview_dump(payload)


def overview_payload(plan: Path, max_chars: int, total_max_chars: int = DEFAULT_OVERVIEW_CHARS) -> dict[str, object]:
    state = parse_plan(plan)

    def optional_section(path: Path, heading: str) -> tuple[str, str]:
        if not path.is_file():
            return "", ""
        try:
            text = section_text(path, heading)
        except ValueError:
            return "", ""
        return text, _bounded_text(text, max_chars)[0]

    # The resume packet needs the current/actionable frontier, not a replay of
    # every completed hot heading. Counts preserve the full lifecycle summary;
    # targeted phase reads remain available for any omitted completed phase.
    overview_phases = [
        phase
        for phase in state.phases
        if phase.status not in SETTLED or phase.num == state.current_phase
    ]
    phases = [
        {
            "phase": phase.num,
            "title": phase.title,
            "status": phase.status,
            "items": len(phase.items),
            "unchecked": sum(not item.checked for item in phase.items),
        }
        for phase in overview_phases
    ]
    phase_counts = {
        status: sum(phase.status == status for phase in state.phases)
        for status in ("pending", "in_progress", "complete", "blocked", "deferred")
    }
    decisions = plan.parent / "decisions.md"
    findings = plan.parent / "findings.md"
    section_specs = {
        "goal": (plan, "Goal"),
        "task_identity": (plan, "Task Identity"),
        "resume_checkpoint": (plan, "Resume Checkpoint"),
        "verification": (plan, "Verification"),
        "errors": (plan, "Errors Encountered"),
        "files_touched": (plan, "Files Touched"),
        "active_decisions": (decisions, "Active Decisions"),
        "open_decision_questions": (decisions, "Open Decision Questions"),
        "findings_summary": (findings, "Current Summary"),
    }
    sections: dict[str, tuple[Path, str, str]] = {}
    section_values: dict[str, str] = {}
    for key, (path, heading) in section_specs.items():
        original, bounded = optional_section(path, heading)
        sections[key] = (path, heading, original)
        section_values[key] = bounded

    restore = restore_payload(plan)
    restore_issues = restore["issues"]
    assert isinstance(restore_issues, list)
    restore_summary = {
        "ok": restore["ok"],
        "issue_count": len(restore_issues),
        "issues": restore_issues[:3],
        "details": "plan_state.py restore-check PLAN",
    }

    payload: dict[str, object] = {
        **context_payload(state),
        "plan": str(plan),
        **section_values,
        "phases": phases,
        "phase_counts": phase_counts,
        "restore": restore_summary,
        "budgets": compact_budget_payload(plan),
        "fingerprints": {
            path.name: file_fingerprint(path)
            for path in sorted(plan.parent.glob("*.md"))
            if path.is_file()
        },
    }
    if total_max_chars == 0:
        _render_overview(payload, sections, total_max_chars)
        return payload
    if total_max_chars < MIN_OVERVIEW_CHARS:
        raise ValueError(
            f"overview total limit must be 0 (unbounded) or at least {MIN_OVERVIEW_CHARS} characters"
        )

    # Preserve restore-critical state first. Lower-value completed detail is
    # removed before active decisions, findings, identity, goal, open questions,
    # or the exact resume checkpoint. Metadata always tells the caller how to
    # recover every shortened section with one targeted read.
    trim_order = (
        "errors",
        "files_touched",
        "verification",
        "active_decisions",
        "findings_summary",
        "task_identity",
        "goal",
        "open_decision_questions",
        "resume_checkpoint",
    )
    rendered = _render_overview(payload, sections, total_max_chars)
    for key in trim_order:
        if len(rendered) <= total_max_chars:
            break
        value = str(payload[key])
        if not value:
            continue
        payload[key] = ""
        empty_rendered = _render_overview(payload, sections, total_max_chars)
        if len(empty_rendered) <= total_max_chars:
            low, high = 0, len(value)
            while low < high:
                middle = (low + high + 1) // 2
                payload[key] = value[:middle]
                if len(_render_overview(payload, sections, total_max_chars)) <= total_max_chars:
                    low = middle
                else:
                    high = middle - 1
            payload[key] = value[:low]
        rendered = _render_overview(payload, sections, total_max_chars)

    if len(rendered) > total_max_chars:
        raise ValueError(
            f"overview structural state needs {len(rendered)} characters, above total limit {total_max_chars}; "
            "raise --total-max-chars or reduce hot phase state"
        )
    return payload


def phase_payload(plan: Path, phase_num: int, max_chars: int) -> dict[str, object]:
    state = parse_plan(plan)
    phase = state.phase(phase_num)
    if not phase:
        raise ValueError(f"Phase {phase_num} does not exist")
    text = "\n".join(state.lines[phase.heading_index : phase.end_index]).strip()
    return _view_payload(
        plan,
        {
            "phase": phase.num,
            "title": phase.title,
            "status": phase.status,
            "items": len(phase.items),
            "unchecked": sum(not item.checked for item in phase.items),
        },
        text,
        max_chars,
    )


def item_payload(plan: Path, item_id: str, max_chars: int) -> dict[str, object]:
    state = parse_plan(plan)
    item = state.item(item_id)
    if not item:
        raise ValueError(f"item {item_id} does not exist")
    text = state.lines[item.line_index]
    if item.evidence_index is not None:
        text = f"{text}\n{state.lines[item.evidence_index]}"
    return _view_payload(
        plan,
        {
            "item": item.item_id,
            "phase": item.phase_num,
            "checked": item.checked,
            "evidence": item.evidence,
        },
        text,
        max_chars,
    )


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
    for command in ("validate", "fingerprint", "context", "restore-check", "assert-finalizable"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("plan", type=Path)
        if command == "assert-finalizable":
            subparser.add_argument("--project-root", type=Path)

    for command in ("overview", "resume-pack"):
        overview = subparsers.add_parser(command)
        overview.add_argument("plan", type=Path)
        overview.add_argument("--max-chars", type=int, default=2 * 1024)
        overview.add_argument("--total-max-chars", type=int, default=DEFAULT_OVERVIEW_CHARS)

    section = subparsers.add_parser("section")
    section.add_argument("file", type=Path)
    section.add_argument("heading")
    section.add_argument("--max-chars", type=int, default=DEFAULT_VIEW_CHARS)

    phase = subparsers.add_parser("phase")
    phase.add_argument("plan", type=Path)
    phase.add_argument("number", type=int)
    phase.add_argument("--max-chars", type=int, default=DEFAULT_VIEW_CHARS)

    item = subparsers.add_parser("item")
    item.add_argument("plan", type=Path)
    item.add_argument("item_id")
    item.add_argument("--max-chars", type=int, default=2 * 1024)

    budgets = subparsers.add_parser("budgets")
    budgets.add_argument("plan", type=Path)
    budget_message = subparsers.add_parser("budget-warning")
    budget_message.add_argument("plan", type=Path)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "section":
            text = section_text(args.file, args.heading)
            print(json.dumps(_view_payload(args.file, {"heading": args.heading}, text, args.max_chars), separators=(",", ":")))
            return 0
        if args.command == "budgets":
            print(json.dumps(budget_payload(args.plan), separators=(",", ":")))
            return 0
        if args.command == "budget-warning":
            print(budget_warning(args.plan), end="")
            return 0
        if args.command in {"overview", "resume-pack"}:
            payload = overview_payload(args.plan, args.max_chars, args.total_max_chars)
            print(_overview_dump(payload))
            return 0
        if args.command == "phase":
            print(json.dumps(phase_payload(args.plan, args.number, args.max_chars), separators=(",", ":")))
            return 0
        if args.command == "item":
            print(json.dumps(item_payload(args.plan, args.item_id, args.max_chars), separators=(",", ":")))
            return 0
        if args.command == "restore-check":
            payload = restore_payload(args.plan)
            print(json.dumps(payload, separators=(",", ":")))
            return 0 if payload["ok"] else 2
        state = parse_plan(args.plan)
    except (OSError, ValueError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, separators=(",", ":")))
        return 2
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
