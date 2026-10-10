"""Shared correlated-tool lifecycle around the PreTool/PostTool policies."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
from datetime import datetime

from session_state import SessionError, SessionStore, project_root
from session_runtime import begin_collection, begin_tool, end_tool, reconcile_background, reconcile_tool_results, turn_id


def main() -> int:
    event, provider, *arguments = sys.argv[1:]
    raw = sys.stdin.read()
    payload = json.loads(raw or "{}")
    session = payload.get("session_id") or payload.get("sessionId")
    store = SessionStore(project_root())
    enabled = session and store.accepts_state() and os.environ.get("PLANNING_DISABLED") != "1" and not (store.root / ".plan-files-skip").exists()
    scripts = Path(__file__).resolve().parent
    env = {**os.environ, "PWF_TURN_ID": turn_id(payload), "PWF_LIFECYCLE_EVENT": event}
    if enabled and "--explain" not in arguments:
        reconcile_tool_results(store, provider, session, payload)
    if event == "end":
        if enabled:
            row = store.read(store.route(provider, session))
            from session_runtime import runtime_identity
            runtime = runtime_identity()
            if row.get("runtime") and runtime and row["runtime"] != runtime:
                print("{}")
                return 0
            timestamp = payload.get("timestamp")
            observed = (datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp()
                        if isinstance(timestamp, str) else timestamp / 1000
                        if isinstance(timestamp, (int, float)) else None)
            store.yield_turn(provider, session, row.get("generation", "legacy"), ending=True,
                             turn=turn_id(payload), observed=observed)
        print("{}")
        return 0
    if event == "post" and enabled:
        if not end_tool(store, provider, session, payload):
            print("{}")
            return 0
        if payload.get("hook_event_name") == "PermissionDenied":
            print("{}")  # Cleanup only; this event does not accept PostTool context.
            return 0
    if event == "stop" and enabled:
        reconcile_background(store, provider, session, payload)
    if event == "pre" and enabled and begin_collection(store, provider, session, payload, preview="--explain" in arguments):
        print("{}")
        return 0
    policy = {"pre": "pre-tool-gate.sh", "post": "hook-post-tool-use.sh", "stop": "hook-agent-stop.sh"}[event]
    result = subprocess.run(["bash", str(scripts / policy), provider, *arguments],
                            input=raw, text=True, capture_output=True, env=env)
    if event == "pre" and enabled and result.returncode == 0:
        response = json.loads(result.stdout or "{}")
        if response.get("decision") not in {"block", "deny"}:
            try:
                begin_tool(store, provider, session, payload, preview="--explain" in arguments)
            except SessionError as error:
                from feedback_transport import feedback_path
                reason = f"[plan-files] {error}"
                if "--explain" in arguments:
                    print(json.dumps({"decision": "block", "reason": reason}))
                else:
                    limit = arguments[2] if len(arguments) > 2 else "0"
                    rendered = subprocess.run([sys.executable, str(scripts / "feedback_transport.py"),
                                               "render", str(feedback_path(str(store.route(provider, session)))), limit],
                                              input=reason, text=True, capture_output=True)
                    print(rendered.stdout or json.dumps({"decision": "block", "reason": reason}), end="")
                return 0
    output = result.stdout
    if event == "post" and payload.get("hook_event_name") == "PostToolUseFailure":
        response = json.loads(output or "{}")
        if "hookSpecificOutput" in response:
            response["hookSpecificOutput"]["hookEventName"] = payload["hook_event_name"]
        output = json.dumps(response)
    print(output, end="")
    print(result.stderr, end="", file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SessionError, OSError, ValueError, IndexError) as error:
        if sys.argv[1:2] == ["pre"]:
            print(json.dumps({"decision": "block", "reason": f"[plan-files] lifecycle check failed: {error}"}))
        else:
            print("{}")
            print(f"plan-files lifecycle: {error}", file=sys.stderr)
