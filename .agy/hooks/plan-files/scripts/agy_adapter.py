#!/usr/bin/env python3
"""Antigravity CLI (agy) adapter: agy hook envelopes in, shared plan-files cores, agy envelopes out.

Usage: agy_adapter.py PreInvocation|PreToolUse|PostToolUse|Stop  (agy hook JSON on stdin)

agy has no prompt-submit event and cannot inject context from PostToolUse.
The first PreInvocation of a turn (invocationNum 0) stands in for the prompt
hook, and PostToolUse context waits for the next PreInvocation of the turn.
A background command gets its PostToolUse only when it finishes; until then
Stop reports fullyIdle false, and agy then starts a turn with the same
lastUserInput, which is a wake-up rather than a new prompt.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ADAPTER_DIR = Path(__file__).resolve().parent
REPO_ROOT = ADAPTER_DIR.parents[3]
SCRIPTS = REPO_ROOT / "skills/plan-files/scripts"
BIND_TOOL = ADAPTER_DIR / "bind-session.sh"
PROVIDER = "agy"
SESSION_VARIABLE = "ANTIGRAVITY_CONVERSATION_ID"
CORES = {
    "PreInvocation": ["hook-user-prompt-submit.sh", PROVIDER, str(REPO_ROOT), str(BIND_TOOL)],
    "PreToolUse": ["pre-tool-gate.sh", PROVIDER, str(BIND_TOOL), "Antigravity"],
    "PostToolUse": ["hook-post-tool-use.sh", PROVIDER, str(REPO_ROOT), str(BIND_TOOL)],
    "Stop": ["hook-agent-stop.sh", PROVIDER, str(REPO_ROOT), "1", "top", str(BIND_TOOL)],
}
# agy names tool arguments in PascalCase; the shared cores read Claude's names.
# edit_file's `Target` is old text, which the cores would otherwise read as a path.
ARGUMENT_NAMES = {"CommandLine": "command", "Cwd": "cwd", "Path": "file_path", "Content": "content",
                  "Target": "old_string", "Replacement": "new_string"}

sys.path.insert(0, str(SCRIPTS))
from feedback_transport import feedback_path, private_directory, valid_file  # noqa: E402


def tool_fields(tool_call: dict) -> dict:
    name = str(tool_call.get("name") or "")
    args = tool_call.get("args")
    if not isinstance(args, dict):
        args = {}
    fields = {"tool_use_id": tool_call.get("id")}
    if name == "call_mcp_tool":
        # The cores classify an MCP call by its mcp__<server>__<tool> name.
        fields["tool_name"] = f"mcp__{args.get('ServerName', '')}__{args.get('ToolName', '')}"
        fields["tool_input"] = args.get("Arguments")
        return fields
    fields["tool_name"] = name
    fields["tool_input"] = {ARGUMENT_NAMES.get(key, key): value for key, value in args.items()}
    return fields


def from_provider_input(event: str, payload: dict) -> dict:
    request = {"session_id": payload["conversationId"], "cwd": payload["cwd"], "hook_event_name": event}
    if event == "PreInvocation":
        request["hook_event_name"] = "UserPromptSubmit"
        request["prompt"] = payload.get("lastUserInput") or ""
    elif event in ("PreToolUse", "PostToolUse"):
        tool_call = payload.get("toolCall")
        request.update(tool_fields(tool_call if isinstance(tool_call, dict) else {}))
        if event == "PostToolUse" and payload.get("error"):
            request["hook_event_name"] = "PostToolUseFailure"
            request["error"] = payload["error"]
    elif event == "Stop" and payload.get("fullyIdle") is False:
        request["host_background_running"] = True
    return request


def additional_context(response: dict) -> str:
    specific = response.get("hookSpecificOutput")
    if not isinstance(specific, dict):
        return ""
    context = specific.get("additionalContext")
    return context if isinstance(context, str) else ""


def to_provider_output(event: str, response: dict, context: str = "") -> dict | None:
    """agy's envelope for a core response; None means print nothing."""
    decision = response.get("decision")
    reason = response.get("reason") or ""
    if event == "PreToolUse":
        if decision in ("block", "deny"):
            return {"decision": "deny", "reason": reason}
        if decision == "ask":
            return {"decision": "ask", "reason": reason}
        # agy denies a PreToolUse output without a decision, even `{}`.
        return None
    if event == "Stop":
        return {"decision": "continue", "reason": reason} if decision == "block" else {}
    if event == "PreInvocation" and context:
        return {"injectSteps": [{"systemMessage": {"systemMessage": context}}]}
    return {}


def pending_context_file(session: str) -> Path:
    return feedback_path(f"{PROVIDER}-context:{session}")


def save_pending_context(session: str, context: str) -> None:
    if not private_directory(create=True):
        return
    path = pending_context_file(session)
    path.unlink(missing_ok=True)
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
        output.write(context)


def take_pending_context(session: str) -> str:
    path = pending_context_file(session)
    if not valid_file(path):
        return ""
    context = path.read_text()
    path.unlink()
    return context


def awaiting_file(session: str) -> Path:
    return feedback_path(f"{PROVIDER}-awaiting:{session}")


def prompt_digest(payload: dict) -> str:
    return hashlib.sha256(str(payload.get("lastUserInput") or "").encode()).hexdigest()


def remember_awaiting(session: str, payload: dict) -> None:
    """Record the prompt of a turn that ended while background work still runs."""
    path = awaiting_file(session)
    path.unlink(missing_ok=True)
    if payload.get("fullyIdle") is not False or not private_directory(create=True):
        return
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
        output.write(prompt_digest(payload))


def woken_by_background(session: str, payload: dict) -> bool:
    """A turn that agy started for finished background work, not for a new prompt."""
    path = awaiting_file(session)
    if not valid_file(path):
        return False
    digest = path.read_text()
    path.unlink()
    return digest == prompt_digest(payload)


def project_root(cwd: str) -> str:
    result = subprocess.run(["bash", str(SCRIPTS / "resolve-project-root.sh"), cwd],
                            text=True, capture_output=True, check=True)
    return result.stdout.strip() or cwd


def run_core(event: str, request: dict) -> dict:
    script, *arguments = CORES[event]
    # An agy started from another agent's shell inherits that agent's planning identity.
    env = {key: value for key, value in os.environ.items() if not key.startswith("PWF_SESSION_")}
    result = subprocess.run(["bash", str(SCRIPTS / script), *arguments], input=json.dumps(request),
                            text=True, capture_output=True, cwd=project_root(request["cwd"]), env=env)
    sys.stderr.write(result.stderr)
    try:
        response = json.loads(result.stdout or "{}")
    except ValueError:
        return {}
    return response if isinstance(response, dict) else {}


def verified(payload: object) -> bool:
    if not isinstance(payload, dict):
        return False
    session = payload.get("conversationId")
    cwd = payload.get("cwd")
    return (isinstance(session, str) and session == os.environ.get(SESSION_VARIABLE)
            and isinstance(cwd, str) and os.path.isdir(cwd))


def handle(event: str, payload: dict) -> dict | None:
    session = payload["conversationId"]
    if event == "Stop" and payload.get("terminationReason") != "NO_TOOL_CALL":
        # Cancel, error and invocation limits are not a turn the agent chose to end.
        return {}
    if event == "Stop":
        remember_awaiting(session, payload)
    if event == "PreInvocation":
        if payload.get("invocationNum") != 0 or woken_by_background(session, payload):
            return to_provider_output(event, {}, take_pending_context(session))
        take_pending_context(session)  # A new turn drops the last turn's undelivered context.
    response = run_core(event, from_provider_input(event, payload))
    if event == "PostToolUse":
        context = additional_context(response)
        if context:
            save_pending_context(session, context)
        return {}
    return to_provider_output(event, response, additional_context(response))


def main() -> int:
    event = sys.argv[1] if len(sys.argv) == 2 else ""
    if event not in CORES:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        payload = None
    output = to_provider_output(event, {})
    if verified(payload):
        try:
            output = handle(event, payload)
        except (OSError, subprocess.CalledProcessError) as error:
            print(f"plan-files agy adapter: {error}", file=sys.stderr)
    if output is not None:
        print(json.dumps(output, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
