#!/usr/bin/env python3
"""Deterministic planning-memory evaluation on isolated local fixtures."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
import tempfile
from pathlib import Path
from typing import Iterable

from plan_state import overview_payload, parse_plan, restore_payload, section_text


SCHEMA_VERSION = 1
FIXTURE_VERSION = "long-run-v2"
REQUIRED_RESTORE_FIELDS = {
    "goal": ("tasks.md", "Goal"),
    "task_identity": ("tasks.md", "Task Identity"),
    "resume_checkpoint": ("tasks.md", "Resume Checkpoint"),
    "open_decision_questions": ("decisions.md", "Open Decision Questions"),
    "findings_summary": ("findings.md", "Current Summary"),
}


def _write_fixture(project: Path) -> Path:
    task_dir = project / "tmp/plan-files/eval-task"
    task_dir.mkdir(parents=True)
    phases = []
    for number in range(1, 12):
        phases.extend(
            [
                f"### Phase {number}: Completed fixture {number}",
                "- **Status:** complete",
                "",
            ]
        )
    phases.extend(
        [
            "### Phase 12: Resume frontier",
            "- [ ] [P12.1] Restore the exact next action after a new session.",
            "  - Evidence: pending",
            "- **Status:** in_progress",
        ]
    )
    tasks = "\n".join(
        [
            "# Tasks: Behavioral Evaluation",
            "",
            "## Goal",
            "Preserve exact resumable state with bounded context.",
            "",
            "## Task Identity",
            "- Deliverable: deterministic evaluation report",
            "- Anchors: behavioral-eval",
            "- Non-goals: production mutation",
            "",
            "## Current Phase",
            "Phase 12",
            "",
            "## Active Item",
            "P12.1",
            "",
            "## Workflow Profile",
            "**Profile:** C",
            "",
            "## Resume Checkpoint",
            "- **Next action:** Complete P12.1: restore the exact next action after a new session",
            "- **Blocker:** none",
            "- **Details:** exact deterministic fixture state",
            "",
            "## Phases",
            *phases,
            "",
            "## Verification",
            "- " + "v" * 700,
            "",
            "## Errors Encountered",
            "- " + "e" * 3000,
            "",
            "## Files Touched",
            "- " + "f" * 1000,
            "",
        ]
    )
    (task_dir / "tasks.md").write_text(tasks, encoding="utf-8")
    (task_dir / "decisions.md").write_text(
        "# Decisions\n\n## Active Decisions\n- "
        + "d" * 3000
        + "\n\n## Superseded Decisions\n- None.\n\n## Open Decision Questions\n- None.\n",
        encoding="utf-8",
    )
    (task_dir / "findings.md").write_text(
        "# Findings\n\n## Current Summary\n- "
        + "s" * 3000
        + "\n\n## Discoveries\n- fixture\n",
        encoding="utf-8",
    )
    (project / ".plan-files").write_text("eval-task\n", encoding="utf-8")
    return task_dir / "tasks.md"


def _run(
    command: list[str], *, env: dict[str, str] | None = None, cwd: Path | None = None
) -> str:
    result = subprocess.run(command, check=True, capture_output=True, text=True, env=env, cwd=cwd)
    return result.stdout.strip()


def _rollover_and_resume(project: Path, plan: Path, scripts: Path) -> dict[str, object]:
    old_sha = hashlib.sha256(plan.read_bytes()).hexdigest()
    edit_payload = json.loads(
        _run(
            [
                "python3",
                str(scripts / "plan_edit.py"),
                "--plan",
                str(plan),
                "--expected-fingerprint",
                old_sha,
                "phase-add",
                "--title",
                "Post-resume continuation",
                "--after",
                "12",
                "--expected-history-fingerprint",
                "missing",
            ]
        )
    )
    state_tool = scripts / "session-state.sh"
    scope_env = os.environ.copy()
    scope_env["PWF_PROJECT_ROOT"] = str(project)
    _run([str(state_tool), "pending", "eval", "session-1"], env=scope_env)
    bind_env = scope_env | {"PWF_SESSION_ADAPTER": "eval", "PWF_SESSION_ID": "session-1"}
    _run([str(state_tool), "bind", "eval-task"], env=bind_env)
    _run([str(state_tool), "pending", "eval", "session-1"], env=scope_env)
    _run([str(state_tool), "bind", "eval-task"], env=bind_env)
    resolved = _run([str(state_tool), "resolve", "eval", "session-1"], env=scope_env)
    state = parse_plan(plan)
    history = plan.parent / "history.md"
    return {
        "archived_phase": edit_payload["archived_phase"],
        "hot_phases": len(state.phases),
        "phase_high_water": 13,
        "history_written": history.is_file() and "Phase 1" in history.read_text(encoding="utf-8"),
        "session_resolved": Path(resolved).resolve() == plan.parent.resolve(),
        "current_phase": state.current_phase,
    }


def _restorability(plan: Path, packet: dict[str, object], metadata: bool) -> tuple[int, list[str]]:
    restored: list[str] = []
    targets: dict[str, object] = {}
    if metadata:
        view_meta = packet.get("view_meta")
        if isinstance(view_meta, dict):
            next_read = view_meta.get("next_read")
            if isinstance(next_read, dict) and isinstance(next_read.get("targets"), dict):
                targets = next_read["targets"]
    for key, (file_name, heading) in REQUIRED_RESTORE_FIELDS.items():
        source = plan.parent / file_name
        original = section_text(source, heading)
        returned = packet.get(key)
        if returned == original or key in targets:
            restored.append(key)
    return len(restored), restored


def _additional_context(payload: str) -> str:
    parsed = json.loads(payload or "{}")
    hook = parsed.get("hookSpecificOutput") if isinstance(parsed, dict) else None
    if isinstance(hook, dict) and isinstance(hook.get("additionalContext"), str):
        return hook["additionalContext"]
    return ""


def _hook_probe(project: Path, scripts: Path) -> dict[str, object]:
    repo = scripts.parents[2]
    state_tool = scripts / "session-state.sh"
    scope_env = os.environ.copy() | {"PWF_PROJECT_ROOT": str(project)}
    _run([str(state_tool), "pending", "codex", "eval-hook-session"], env=scope_env)
    bind_env = scope_env | {"PWF_SESSION_ADAPTER": "codex", "PWF_SESSION_ID": "eval-hook-session"}
    _run([str(state_tool), "bind", "eval-task"], env=bind_env)
    post_hook = repo / ".codex/hooks/plan-files/scripts/post-tool-use.sh"
    stop_hook = repo / ".codex/hooks/plan-files/scripts/agent-stop.sh"
    policy_env = os.environ.copy() | {"PWF_ITEM_NUDGE_DEBOUNCE_SECS": "0"}

    def post(payload: dict[str, object]) -> str:
        output = subprocess.run(
            [str(post_hook)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            check=True,
            cwd=project,
            env=policy_env,
        ).stdout.strip()
        return _additional_context(output)

    read_payload = {
        "session_id": "eval-hook-session",
        "hook_event_name": "PostToolUse",
        "tool_name": "Read",
        "tool_input": {"file_path": "README.md"},
    }
    read_contexts = [post(read_payload) for _ in range(6)]
    evidence_payload = {
        "session_id": "eval-hook-session",
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": "pytest -q"},
    }
    evidence_contexts = [post(evidence_payload) for _ in range(2)]
    contexts = read_contexts + evidence_contexts
    stop_payload = json.dumps(
        {"session_id": "eval-hook-session", "hook_event_name": "Stop", "stop_hook_active": False}
    )
    stop_output = subprocess.run(
        [str(stop_hook)], input=stop_payload, capture_output=True, text=True, check=True, cwd=project
    ).stdout.strip()
    stop_result = json.loads(stop_output)
    handoff = project / "tmp/plan-files/eval-task/handoff.md"
    handoff.write_text("# Handoff\n\nUpdated: stale fixture\n", encoding="utf-8")
    os.utime(handoff, (1, 1))
    warning_env = os.environ.copy() | {
        "COMMON": str(repo / ".codex/hooks/plan-files/scripts/common.sh"),
        "PLAN_DIR": str(handoff.parent),
    }
    stale_warning = _run(
        ["bash", "-c", 'source "$COMMON"; planning_handoff_warning "$PLAN_DIR"'],
        env=warning_env,
        cwd=project,
    )
    handoff.unlink()
    return {
        "post_calls": len(contexts),
        "injections": sum(bool(context) for context in contexts),
        "injected_context_chars": sum(len(context) for context in contexts),
        "redundant_reminders": max(0, sum(bool(context) for context in read_contexts) - 1),
        "read_only_false_reminders": sum(bool(context) for context in read_contexts[1:]),
        "legacy_read_only_false_reminders": len(read_contexts) - 1,
        "missed_checkpoint_detected": any(
            "STALE ITEM STATE" in context for context in evidence_contexts
        ),
        "actionable_finalization_blocked": stop_result.get("decision") == "block",
        "stale_state_detected": "STALE HANDOFF" in stale_warning,
    }


def evaluate() -> dict[str, object]:
    scripts = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="pwf-behavioral-eval-") as directory:
        project = Path(directory)
        plan = _write_fixture(project)
        lifecycle = _rollover_and_resume(project, plan, scripts)
        restored_after_compaction = restore_payload(plan)
        original_plan = plan.read_text(encoding="utf-8")
        plan.write_text(
            original_plan.replace(
                "- **Next action:** Complete P12.1: restore the exact next action after a new session",
                "- **Next action:** [exact next action]",
            ),
            encoding="utf-8",
        )
        broken_restore = restore_payload(plan)
        plan.write_text(original_plan, encoding="utf-8")
        broken_issues = broken_restore["issues"]
        assert isinstance(broken_issues, list)
        restore_probe = {
            "after_compaction_ok": restored_after_compaction["ok"],
            "after_compaction_checks": restored_after_compaction["checks"],
            "broken_ok": broken_restore["ok"],
            "broken_issues": broken_issues,
        }
        hook_probe = _hook_probe(project, scripts)
        legacy = overview_payload(plan, 2 * 1024, 0)
        legacy.pop("view_meta", None)
        revised = overview_payload(plan, 2 * 1024, 4 * 1024)
        legacy_text = json.dumps(legacy, ensure_ascii=False, separators=(",", ":"))
        revised_text = json.dumps(revised, ensure_ascii=False, separators=(",", ":"))
        legacy_count, legacy_fields = _restorability(plan, legacy, False)
        revised_count, revised_fields = _restorability(plan, revised, True)
        total = len(REQUIRED_RESTORE_FIELDS)
        policies = {
            "disabled": {
                "packet_chars": 0,
                "restorable_context": 0,
                "restorable_context_total": total,
                "wrong_task_guard": False,
                "wrong_task_use_risk": True,
                "rollover_resume": False,
                "missing_restore_fields": sorted(REQUIRED_RESTORE_FIELDS),
            },
            "current": {
                "packet_chars": len(legacy_text),
                "restorable_context": legacy_count,
                "restorable_fields": legacy_fields,
                "restorable_context_total": total,
                "wrong_task_guard": lifecycle["session_resolved"],
                "wrong_task_use_risk": not lifecycle["session_resolved"],
                "rollover_resume": all(lifecycle.values()),
                "missing_restore_fields": sorted(set(REQUIRED_RESTORE_FIELDS) - set(legacy_fields)),
            },
            "revised": {
                "packet_chars": len(revised_text),
                "restorable_context": revised_count,
                "restorable_fields": revised_fields,
                "restorable_context_total": total,
                "wrong_task_guard": lifecycle["session_resolved"],
                "wrong_task_use_risk": not lifecycle["session_resolved"],
                "rollover_resume": all(lifecycle.values()),
                "missing_restore_fields": sorted(set(REQUIRED_RESTORE_FIELDS) - set(revised_fields)),
                "truncated_sections": sorted(revised["view_meta"]["truncated_sections"]),
            },
        }
        return {
            "schema_version": SCHEMA_VERSION,
            "fixture_version": FIXTURE_VERSION,
            "pinned": {
                "model": "none-deterministic",
                "python": platform.python_version(),
                "overview_total_chars": 4096,
                "hot_phase_limit": 12,
            },
            "metric_note": "restorable_context is a structural recovery proxy, not model-semantic recall",
            "lifecycle": lifecycle,
            "restore_probe": restore_probe,
            "hook_probe": hook_probe,
            "policies": policies,
            "checks": {
                "revised_packet_bounded": len(revised_text) <= 4096,
                "revised_context_restorable": revised_count == total,
                "history_first_rollover": lifecycle["archived_phase"] == 1 and lifecycle["history_written"],
                "new_session_resume": lifecycle["session_resolved"] and lifecycle["current_phase"] == 12,
                "forced_compaction_restore": restored_after_compaction["ok"],
                "precise_restore_diagnosis": (
                    not broken_restore["ok"]
                    and any(
                        issue.get("code") == "RESTORE_NEXT_ACTION_MISSING"
                        and issue.get("source") == "tasks.md"
                        and issue.get("heading") == "Resume Checkpoint"
                        and bool(issue.get("repair"))
                        for issue in broken_issues
                        if isinstance(issue, dict)
                    )
                ),
                "actionable_finalization_blocked": hook_probe["actionable_finalization_blocked"],
                "debounce_avoids_redundant_reminder": hook_probe["redundant_reminders"] == 0,
                "read_only_noise_reduced": hook_probe["read_only_false_reminders"]
                < hook_probe["legacy_read_only_false_reminders"],
                "missed_checkpoint_detected": hook_probe["missed_checkpoint_detected"],
                "stale_state_detected": hook_probe["stale_state_detected"],
            },
        }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    payload = evaluate()
    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    else:
        print(f"Fixture: {payload['fixture_version']} (schema {payload['schema_version']})")
        print(payload["metric_note"])
        for name, metrics in payload["policies"].items():
            print(
                f"- {name}: packet={metrics['packet_chars']} chars; "
                f"restorable={metrics['restorable_context']}/{metrics['restorable_context_total']}; "
                f"wrong-task-guard={metrics['wrong_task_guard']}; rollover-resume={metrics['rollover_resume']}"
            )
        for name, passed in payload["checks"].items():
            print(f"- {'PASS' if passed else 'FAIL'} {name}")
        probe = payload["hook_probe"]
        print(
            f"Hook probe: {probe['injections']} injection(s)/{probe['injected_context_chars']} chars; "
            f"redundant={probe['redundant_reminders']}; stale-detected={probe['stale_state_detected']}; "
            f"read-noise={probe['read_only_false_reminders']}/"
            f"{probe['legacy_read_only_false_reminders']} legacy; "
            f"missed-checkpoint={probe['missed_checkpoint_detected']}; "
            f"actionable-stop-blocked={probe['actionable_finalization_blocked']}"
        )
    return 0 if all(payload["checks"].values()) else 2


if __name__ == "__main__":
    raise SystemExit(main())
