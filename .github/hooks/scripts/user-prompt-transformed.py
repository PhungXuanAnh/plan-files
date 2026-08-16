#!/usr/bin/env python3
"""Adapt userPromptTransformed by appending candidate planning context."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


def run_prompt_candidate(
    tool: Path, root: Path, bind_tool: Path, payload: str
) -> str:
    env = {**os.environ, "PWF_PROJECT_ROOT": str(root)}
    try:
        result = subprocess.run(
            [str(tool), "copilot", str(bind_tool)],
            cwd=root,
            env=env,
            input=payload,
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError:
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def main() -> None:
    log_file = Path("tmp/hook-logs/plan-with-files/user-prompt-submit.log")
    log_file.parent.mkdir(parents=True, exist_ok=True)
    def log(message: str) -> None:
        try:
            with log_file.open("a", encoding="utf-8") as handle:
                handle.write(f"[{__import__('datetime').datetime.utcnow().isoformat()}Z] {message}\n")
        except OSError:
            pass

    log("event=UserPromptSubmit provider=copilot")
    try:
        raw_payload = sys.stdin.read()
        payload = json.loads(raw_payload)
    except (json.JSONDecodeError, OSError):
        print("{}")
        return
    if not isinstance(payload, dict):
        print("{}")
        return

    cwd = payload.get("cwd")
    if cwd is not None and not isinstance(cwd, str):
        print("{}")
        return
    root = Path(cwd or os.getcwd()).resolve()
    if os.environ.get("PLANNING_DISABLED") == "1" or (root / ".plan-with-files-skip").exists():
        print("{}")
        return

    session_id = payload.get("sessionId") or payload.get("session_id")
    transformed = payload.get("transformedPrompt")
    if not isinstance(session_id, str) or not isinstance(transformed, str):
        print("{}")
        return

    repo_root = Path(__file__).resolve().parents[3]
    prompt_tool = repo_root / "skills/planning-with-files/scripts/prompt-candidate.sh"
    bind_tool = repo_root / ".github/hooks/scripts/bind-session.sh"
    context = run_prompt_candidate(prompt_tool, root, bind_tool, raw_payload)
    if not context:
        log("candidate=none")
        print("{}")
        return

    log("candidate_context=emitted")
    print(json.dumps({"modifiedTransformedPrompt": f"{transformed}\n\n{context}"}))


if __name__ == "__main__":
    main()
