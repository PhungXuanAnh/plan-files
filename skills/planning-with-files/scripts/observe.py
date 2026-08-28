#!/usr/bin/env python3
"""Report planning checkpoint and early-final signals from local logs."""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Iterable

from plan_state import context_payload, parse_plan


SCHEMA_VERSION = 1
STOP_RE = re.compile(
    r"progress fingerprint=(\S+) state=(\S+) no_progress_count=(\d+) active_item=(\S+) first_item=(\S+)"
)
POST_RE = re.compile(
    r"item_state fingerprint=(\S+) active_item=(\S+) plan_changed=(\S+) unchanged_tools=(\d+)"
    r"(?: risk=(\d+) tool_class=(\S+))? checkpoint_lag=(\d+)s stale=(\S+)"
)
SCOPE_RE = re.compile(r"scope provider=(\S+) task=(\S+) session=(\S+)")
INJECTION_RE = re.compile(
    r"injection emitted=(\S+) chars=(\d+) bytes=(\d+) full=(\S+) stale=(\S+) reason=(\S+)"
)
STOP_TELEMETRY_RE = re.compile(r"stop continuation=(\S+) output_chars=(\d+)")


def _scope(block: str) -> dict[str, str]:
    match = SCOPE_RE.search(block)
    if not match:
        return {"provider": "unknown", "task": "unknown", "session": "unknown"}
    provider, task, session = match.groups()
    return {"provider": provider, "task": task, "session": session}


def _blocks(path: Path, marker: str) -> list[str]:
    if not path.is_file():
        return []
    text = path.read_text(encoding="utf-8", errors="replace")
    return [marker + block for block in text.split(marker)[1:]]


def _hook_metrics(project_root: Path, plan: Path | None) -> dict[str, object]:
    log_root = project_root / "tmp/hook-logs/plan-with-files"
    plan_text = str(plan.resolve()) if plan else ""

    stop_records: list[dict[str, object]] = []
    for block in _blocks(log_root / "agent-stop.log", "=== agent-stop ==="):
        if plan_text and plan_text not in block:
            continue
        match = STOP_RE.search(block)
        telemetry = STOP_TELEMETRY_RE.search(block)
        if match or telemetry:
            record: dict[str, object] = {
                **_scope(block),
                "continuation": telemetry.group(1) == "true" if telemetry else False,
                "output_chars": int(telemetry.group(2)) if telemetry else 0,
            }
            if match:
                fingerprint, state, count, active, first = match.groups()
                record.update(
                    {
                    "fingerprint": fingerprint,
                    "state": state,
                    "no_progress_count": int(count),
                    "active_item": active,
                    "first_item": first,
                    }
                )
            else:
                record.update({"state": "settled", "no_progress_count": 0})
            stop_records.append(record)

    post_records: list[dict[str, object]] = []
    for block in _blocks(log_root / "post-tool-use.log", "=== post-tool-use ==="):
        if plan_text and plan_text not in block:
            continue
        match = POST_RE.search(block)
        injection = INJECTION_RE.search(block)
        if match or injection:
            record: dict[str, object] = {
                **_scope(block),
                "injection_emitted": injection.group(1) == "true" if injection else False,
                "injected_chars": int(injection.group(2)) if injection else 0,
                "injected_bytes": int(injection.group(3)) if injection else 0,
                "full_injection": injection.group(4) == "true" if injection else False,
                "injection_reason": injection.group(6) if injection else "unknown",
            }
            if match:
                fingerprint, active, changed, unchanged, risk, tool_class, lag, stale = match.groups()
                record.update(
                    {
                    "fingerprint": fingerprint,
                    "active_item": active,
                    "plan_changed": changed == "true",
                    "unchanged_tools": int(unchanged),
                    "risk_score": int(risk or 0),
                    "tool_class": tool_class or "legacy",
                    "checkpoint_lag_seconds": int(lag),
                    "stale": stale == "true",
                    }
                )
            else:
                record.update(
                    {
                        "plan_changed": False,
                        "unchanged_tools": 0,
                        "risk_score": 0,
                        "tool_class": "unknown",
                        "checkpoint_lag_seconds": 0,
                        "stale": injection.group(5) == "true" if injection else False,
                    }
                )
            post_records.append(record)

    return {
        "stop": {
            "events": len(stop_records),
            "progress_events": sum(record["state"] == "progress" for record in stop_records),
            "no_progress_events": sum(record["state"] == "no_progress" for record in stop_records),
            "continuations": sum(bool(record["continuation"]) for record in stop_records),
            "output_chars": sum(int(record["output_chars"]) for record in stop_records),
            "max_no_progress_streak": max((int(record["no_progress_count"]) for record in stop_records), default=0),
            "last": stop_records[-1] if stop_records else None,
        },
        "post_tool": {
            "events": len(post_records),
            "plan_changes": sum(bool(record["plan_changed"]) for record in post_records),
            "stale_events": sum(bool(record["stale"]) for record in post_records),
            "injections": sum(bool(record["injection_emitted"]) for record in post_records),
            "injected_chars": sum(int(record["injected_chars"]) for record in post_records),
            "injected_bytes": sum(int(record["injected_bytes"]) for record in post_records),
            "debounced_events": sum(record["injection_reason"] == "debounce" for record in post_records),
            "tool_classes": {
                category: sum(record["tool_class"] == category for record in post_records)
                for category in sorted({str(record["tool_class"]) for record in post_records})
            },
            "max_risk_score": max((int(record["risk_score"]) for record in post_records), default=0),
            "max_unchanged_tools": max((int(record["unchanged_tools"]) for record in post_records), default=0),
            "max_checkpoint_lag_seconds": max(
                (int(record["checkpoint_lag_seconds"]) for record in post_records), default=0
            ),
            "last": post_records[-1] if post_records else None,
        },
    }


def _timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _message_text(payload: dict[str, object]) -> str:
    content = payload.get("content")
    if not isinstance(content, list):
        return ""
    return "\n".join(
        str(block.get("text", ""))
        for block in content
        if isinstance(block, dict) and isinstance(block.get("text"), str)
    )


def _rollout_metrics(path: Path) -> list[dict[str, object]]:
    turns: list[dict[str, object]] = []
    current: dict[str, object] | None = None

    def finish() -> None:
        nonlocal current
        if not current:
            return
        start = current.pop("_start", None)
        first_final = current.pop("_first_final", None)
        last = current.pop("_last", None)
        current["first_final_seconds"] = (
            round((first_final - start).total_seconds(), 2)
            if isinstance(start, datetime) and isinstance(first_final, datetime)
            else None
        )
        current["duration_seconds"] = (
            round((last - start).total_seconds(), 2)
            if isinstance(start, datetime) and isinstance(last, datetime)
            else None
        )
        if current["final_answers"] or current["stop_continuations"] or current["tool_calls"]:
            turns.append(current)
        current = None

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        timestamp = _timestamp(event.get("timestamp"))
        if event.get("type") == "turn_context":
            finish()
            payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
            current = {
                "turn_id": payload.get("turn_id", "unknown"),
                "final_answers": 0,
                "stop_continuations": 0,
                "tool_calls": 0,
                "_start": timestamp,
                "_first_final": None,
                "_last": timestamp,
            }
            continue
        if not current:
            continue
        current["_last"] = timestamp or current["_last"]
        if event.get("type") != "response_item" or not isinstance(event.get("payload"), dict):
            continue
        payload = event["payload"]
        if payload.get("type") == "message":
            if payload.get("role") == "assistant" and payload.get("phase") == "final_answer":
                current["final_answers"] = int(current["final_answers"]) + 1
                current["_first_final"] = current["_first_final"] or timestamp
            elif payload.get("role") == "user":
                text = _message_text(payload)
                if "<hook_prompt" in text and "[planning-with-files]" in text:
                    current["stop_continuations"] = int(current["stop_continuations"]) + 1
        elif payload.get("type") in {"function_call", "custom_tool_call", "local_shell_call", "mcp_tool_call"}:
            current["tool_calls"] = int(current["tool_calls"]) + 1
    finish()
    return turns


def _resolve_plan(project_root: Path, explicit: Path | None) -> Path | None:
    if explicit:
        return explicit.resolve()
    pointer = project_root / ".plan-with-files"
    if not pointer.is_file():
        return None
    task_id = pointer.read_text(encoding="utf-8").strip()
    candidate = project_root / "tmp/plan-with-files" / task_id / "tasks.md"
    return candidate.resolve() if task_id and candidate.is_file() else None


def _assessment(hooks: dict[str, object]) -> list[str]:
    stop = hooks["stop"]
    post = hooks["post_tool"]
    lines: list[str] = []
    if int(stop["max_no_progress_streak"]) >= 2:
        lines.append("RED: repeated finals are cycling without structured plan progress.")
    elif int(stop["no_progress_events"]) > 0:
        lines.append("WATCH: at least one repeated final had no structured progress; the next continuation should change fingerprint.")
    else:
        lines.append("OK: no repeated no-progress Stop streak is recorded.")
    if int(post["stale_events"]) > 0:
        lines.append("WATCH: Active Item became stale; verify that evidence is checkpointed before switching work.")
    elif int(post["events"]) > 0:
        lines.append("OK: no stale Active Item event is recorded.")
    else:
        lines.append("INFO: no item-aware PostTool events are available yet.")
    return lines


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--rollout", type=Path)
    parser.add_argument("--json", action="store_true")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    project_root = args.project_root.resolve()
    plan = _resolve_plan(project_root, args.plan)
    hooks = _hook_metrics(project_root, plan)
    payload: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "project_root": str(project_root),
        "plan": context_payload(parse_plan(plan)) if plan and plan.is_file() else None,
        "hooks": hooks,
        "assessment": _assessment(hooks),
        "rollout_turns": _rollout_metrics(args.rollout) if args.rollout else [],
    }
    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    plan_state = payload["plan"] or {}
    print(f"Plan: {plan or 'none'}")
    if plan_state:
        print(
            f"Current Phase {plan_state['current_phase']}; Active Item {plan_state['active_item']}; "
            f"fingerprint {plan_state['fingerprint']}"
        )
    stop = hooks["stop"]
    post = hooks["post_tool"]
    print(
        "Stop: {events} event(s), {continuations} continuation(s), {progress_events} progress, "
        "{no_progress_events} no-progress, max streak {max_no_progress_streak}".format(**stop)
    )
    print(
        "PostTool: {events} event(s), {plan_changes} plan change(s), {stale_events} stale, "
        "{injections} injection(s)/{injected_chars} chars, {debounced_events} debounced, "
        "max unchanged {max_unchanged_tools}, max checkpoint lag {max_checkpoint_lag_seconds}s".format(**post)
    )
    for line in payload["assessment"]:
        print(line)
    if payload["rollout_turns"]:
        print("Rollout turns (first-final timing is diagnostic, not a completion criterion):")
        for turn in payload["rollout_turns"]:
            print(
                "- {turn_id}: first_final={first_final_seconds}s finals={final_answers} "
                "stop_continuations={stop_continuations} tool_calls={tool_calls} duration={duration_seconds}s".format(**turn)
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
