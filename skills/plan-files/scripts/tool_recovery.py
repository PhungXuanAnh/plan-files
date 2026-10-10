"""Explicit, single-receipt recovery when a host omits rejected-call events.

This is an agent attestation of a received pre-execution denial, not automatic
host evidence. Never use it for a running, timed-out, or unknown-outcome call.
Metadata is diagnostic only; .tools remains the authority for outstanding work.
"""
from __future__ import annotations

import hashlib
import json


def command_hash(command: str) -> str:
    return hashlib.sha256(command.encode()).hexdigest()


def metadata(file) -> dict:
    try:
        value = json.loads(file.with_suffix(".attempts").read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def remember_attempt(file, pending: dict, key: str, generation: str, command: str) -> None:
    from session_state import atomic_text
    data = {k: v for k, v in metadata(file).items()
            if isinstance(v, dict) and pending.get(k) == v.get("generation")}
    if command and not key.startswith(("anonymous:", "background:")):
        data[key] = {"generation": generation, "command_sha256": command_hash(command)}
    atomic_text(file.with_suffix(".attempts"), json.dumps(data))


def recover(store, provider: str, session: str, task: str, command: str, *,
            receipt: str = "", generation: str = "", reason: str = "") -> str:
    """Inspect exact-command candidates, or acknowledge one received rejection.

    The caller supplies both tokens from inspection; concurrent completion,
    reclaim, a repeated command, or a background conversion invalidates them.
    This never binds a prompt, refreshes a snapshot, or touches another session.
    """
    from session_state import SessionError, atomic_text
    store.enabled()
    file = store.route(provider, session)
    with store.lock():
        row = store.read(file)
        if not command or (row.get("task") or row.get("candidate") or row.get("associated")) != task:
            raise SessionError("rejection recovery requires this session's task and the exact rejected command")
        pending = store.tools(file)
        digest = command_hash(command)
        attempts = metadata(file)
        matches = [{"receipt": key, "generation": value}
                   for key, value in pending.items() if isinstance(value, str)
                   and ":" not in key and attempts.get(key) == {
                       "generation": value, "command_sha256": digest}]
        if not receipt:
            return json.dumps({"schema_version": 1, "matches": matches[:16],
                               "match_count": len(matches), "command_sha256": digest,
                               "instruction": "Only after receiving a native pre-execution denial for this exact call, use ack-rejected with its receipt, generation, command and a concrete reason. Running, timed-out or unknown calls must be collected or investigated; absence of a file is not evidence."})
        if not reason.strip() or len(matches) != 1 or matches[0] != {"receipt": receipt, "generation": generation}:
            raise SessionError("rejected receipt is missing, changed or ambiguous; inspect again and verify the native denial")
        pending.pop(receipt)
        atomic_text(file.with_suffix(".tools"), json.dumps(pending))
        return json.dumps({"acknowledged_rejection": True, "remaining_tools": len(pending),
                           "authority_changed": False})


def recovery_guidance(store, provider: str, task: str) -> str:
    import shlex
    from pathlib import Path
    repo = Path(__file__).resolve().parents[3]
    directory = ".github/hooks/scripts" if provider == "copilot" else f".{provider}/hooks/plan-files/scripts"
    command = f"PWF_PROJECT_ROOT={shlex.quote(str(store.root))} bash {shlex.quote(str(repo / directory / 'bind-session.sh'))}"
    return (f"; for an already received pre-execution denial, inspect only that command with `{command} tools {task} --command '<exact rejected command>'`, "
            f"then follow {repo / 'skills/plan-files/references/routing-and-hooks.md'} (Rejected-call recovery). "
            "Never acknowledge a running, timed-out or unknown call; do not clear .tools or reclaim other sessions")
