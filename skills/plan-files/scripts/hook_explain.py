#!/usr/bin/env python3
"""Explain the shared PreTool decision without executing the proposed command or writing hook state."""

import argparse
import json
import os
from pathlib import Path
import subprocess


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=("codex", "claude", "copilot", "grok"), required=True)
    parser.add_argument("--session-id", default=os.environ.get("PWF_SESSION_ID"),
                        help="session to inspect; defaults to PWF_SESSION_ID or the provider environment")
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument("--command", required=True, help="shell command to classify, never execute")
    args = parser.parse_args()
    session_vars = {"codex": "CODEX_THREAD_ID", "claude": "CLAUDE_SESSION_ID",
                    "copilot": "COPILOT_AGENT_SESSION_ID", "grok": "GROK_SESSION_ID"}
    session = args.session_id or os.environ.get(session_vars[args.provider])
    if not session:
        parser.error("--session-id is required when no verified session environment is available")
    scripts = Path(__file__).resolve().parent
    repo = scripts.parents[2]
    adapters = {"copilot": repo / ".github/hooks/scripts"}
    adapter = adapters.get(args.provider, repo / f".{args.provider}/hooks/plan-files/scripts")
    payload = {"session_id": session, "tool_name": "Bash", "tool_input": {"command": args.command}}
    result = subprocess.run(
        ["bash", str(scripts / "pre-tool-gate.sh"), args.provider, str(adapter / "bind-session.sh"),
         args.provider, "0", "--explain"], input=json.dumps(payload), text=True, capture_output=True,
        cwd=args.project_root, env={**os.environ, "PWF_PROJECT_ROOT": str(args.project_root.resolve()),
                                   "PYTHONDONTWRITEBYTECODE": "1"})
    try:
        output = json.loads(result.stdout)
        if result.returncode or not isinstance(output, dict):
            raise ValueError("shared gate did not return a decision")
    except ValueError as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return 2
    rules = [line.removeprefix("rule=") for line in result.stderr.splitlines() if line.startswith("rule=")]
    reason = rules[-1] if rules else "shared gate allows the call"
    if reason == "allow":
        reason = "Owned task passed integrity, budget, restore, settled-state and skill-read gates."
    print(json.dumps({"schema_version": 1, "provider": args.provider,
                      "decision": output.get("decision", "allow"),
                      "reason": output.get("reason", reason),
                      "read_only": True}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
