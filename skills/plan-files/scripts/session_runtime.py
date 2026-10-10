"""Runtime identity and correlated in-flight tools for the shared session store.

No timeout is evidence of a dead writer. Linux process identities include host,
boot and process start time; providers without such evidence retain manual recovery.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys


def process_identity(pid: int) -> tuple[str, str]:
    data = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
    return data[19], data[0]  # starttime, state; pid reuse is not the same runtime


def host_identity() -> tuple[str, str]:
    machine = Path("/etc/machine-id").read_text().strip()
    return hashlib.sha256(machine.encode()).hexdigest(), Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def runtime_identity() -> str:
    try:
        machine, boot = host_identity()
        executables = {str(Path(path).resolve()) for name in ("codex", "claude", "copilot")
                       if (path := shutil.which(name))}
        pid = os.getppid()
        for _ in range(32):
            if pid <= 1:
                break
            base = Path(f"/proc/{pid}")
            argv = base.joinpath("cmdline").read_bytes().split(b"\0")
            executable = Path(os.fsdecode(argv[0])).name
            script = os.fsdecode(argv[1]) if len(argv) > 1 else ""
            agent = executable in {"codex", "claude", "copilot"}
            agent |= str(base.joinpath("exe").resolve()) in executables
            agent |= executable in {"node", "bun"} and "/@github/copilot/" in script
            if agent:
                start, _ = process_identity(pid)
                return f"{machine}:{boot}:{pid}:{start}"
            pid = int(base.joinpath("stat").read_text().rsplit(") ", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return ""


def runtime_dead(row: dict) -> bool:
    try:
        machine, boot, pid, start = row.get("runtime", "").split(":")
        local_machine, local_boot = host_identity()
        if machine != local_machine:
            return False
        if boot != local_boot:
            return True
        try:
            actual, state = process_identity(int(pid))
        except FileNotFoundError:
            return True
        return actual != start or state == "Z"
    except (OSError, ValueError, IndexError):
        return False


def classifier():
    name = "planning_tool_classifier"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name("maintenance-tool-allowed.py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


def event_id(payload: dict) -> str:
    return next((str(payload[key]) for key in ("tool_use_id", "toolUseId", "tool_call_id", "toolCallId") if payload.get(key)), "")


def turn_id(payload: dict) -> str:
    raw = payload.get("turn_id") or payload.get("turnId")
    return hashlib.sha256(str(raw).encode()).hexdigest() if raw else ""


def tool_key(payload: dict) -> str:
    event = event_id(payload)
    if event:
        return hashlib.sha256(event.encode()).hexdigest()
    if not payload.get("timestamp"):
        return ""  # Legacy hosts lacking both correlation and lifecycle metadata.
    module = classifier()
    value = [payload.get("tool_name") or payload.get("toolName"), module.payload_tool_input(payload)]
    return "anonymous:" + hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def is_helper(payload: dict) -> bool:
    module = classifier()
    for segment in module.planning_helper_segments(module.shell_command_text(module.payload_tool_input(payload))):
        if any(Path(word).name in {"session-state.sh", "session_state.py", "bind-session.sh",
                                  "plan_edit.py", "plan_checkpoint.py", "plan_state.py"}
               for word in segment.argv):
            return module.shell_runs_planning_helper(module.payload_tool_input(payload))
    return False


def background_result(payload: dict) -> tuple[str, bool]:
    """Recognize native asynchronous shell handles; never infer completion from age."""
    name = str(payload.get("tool_name") or payload.get("toolName") or "").rsplit(".", 1)[-1].lower()
    args = classifier().payload_tool_input(payload)
    if name not in {"exec_command", "write_stdin", "bash", "read_bash", "taskoutput"}:
        return "", False
    result = payload.get("tool_response", payload.get("tool_result", payload.get("toolResult", {})))
    if isinstance(result, str):
        try:
            result = json.loads(result)
        except ValueError:
            pass
    # Structured native status wins; stdout may itself contain status-like text.
    text = result if isinstance(result, str) else ""
    handle = ""
    running = False
    if isinstance(result, dict):
        state = result.get("task", result)
        if not isinstance(state, dict):
            state = result
        handle = state.get("session_id") or state.get("shellId") or state.get("backgroundTaskId") or state.get("task_id") or ""
        running = bool(handle) and state.get("exit_code", state.get("exitCode")) is None
    match = re.search(r"(?:Process running with session ID|Shell ID|Background task ID)[: ]+(\S+)", text)
    if match:
        handle, running = match[1], True
    if name in {"write_stdin", "read_bash", "taskoutput"} and isinstance(args, dict):
        handle = args.get("session_id") or args.get("shellId") or args.get("task_id") or handle
    terminal = (isinstance(result, dict) and (state.get("exit_code", state.get("exitCode")) is not None
                or state.get("status") in {"completed", "failed", "killed"})) or bool(
        re.search(r"(?:Process exited with code|Exit code:|exited with exit code)\s*-?\d+", text))
    if not handle or not (running or terminal):
        return "", False
    family = "shell" if name in {"bash", "read_bash", "taskoutput"} else "exec"
    return "background:" + hashlib.sha256(f"{family}:{handle}".encode()).hexdigest(), running and not terminal


def reconcile_background(store, provider: str, session: str, payload: dict) -> None:
    """Reconcile native Stop's in-flight registry, never command output or age.

    Claude versions without TaskOutput report shell completion through their
    task registry. Missing/invalid registries convey no completion evidence.
    Native tool ids are unique within a session, including across prompts.
    """
    from session_state import atomic_text
    tasks = payload.get("background_tasks")
    if provider != "claude" or not isinstance(tasks, list) or any(
            not isinstance(task, dict) or not isinstance(task.get("id"), str) for task in tasks):
        return
    live = {"background:" + hashlib.sha256(f"shell:{task['id']}".encode()).hexdigest() for task in tasks}
    file = store.route(provider, session)
    if not file.exists():
        return
    with store.lock():
        row = store.read(file)
        turn = turn_id(payload)
        if turn and row.get("turn") and row["turn"] != turn:
            return
        runtime = runtime_identity()
        if row.get("runtime") and runtime and row["runtime"] != runtime:
            return
        pending = store.tools(file)
        remaining = {key: value for key, value in pending.items()
                     if not key.startswith("background:") or key in live}
        if remaining != pending:
            atomic_text(file.with_suffix(".tools"), json.dumps(remaining))


def reconcile_tool_results(store, provider: str, session: str, payload: dict) -> None:
    """Retire only correlated terminal receipts, without granting authority.

PreTool records an attempted call, not proof that all other hooks allowed it.
Read host evidence outside the routing lock, then compare receipts again so a
concurrent reclaim/new generation cannot be modified by this reconciliation.
"""
    from session_state import SessionError, atomic_text
    from tool_results import terminal_error_keys
    if provider != "claude" or not payload.get("transcript_path"):
        return
    file = store.route(provider, session)
    if not file.exists():
        return
    try:
        with store.lock():
            snapshot = store.tools(file)
    except (SessionError, OSError):
        # Preserve the existing read-only diagnosis/explicit recovery routes.
        # Normal execution and yield still reject invalid receipt state.
        return
    keys = {key for key, generation in snapshot.items()
            if ":" not in key and isinstance(generation, str)}
    finished = terminal_error_keys(provider, session, payload["transcript_path"], keys)
    if not finished:
        return
    try:
        with store.lock():
            pending = store.tools(file)
            remaining = {key: generation for key, generation in pending.items()
                         if key not in finished or generation != snapshot.get(key)}
            if remaining != pending:
                atomic_text(file.with_suffix(".tools"), json.dumps(remaining))
    except (SessionError, OSError):
        return


def begin_collection(store, provider: str, session: str, payload: dict, *, preview: bool = False) -> bool:
    """Read results of this session's existing job even across prompt routing.

    This cannot launch work, send stdin, read an unknown handle, or acquire a
    task. The receipt retains its original generation until PostTool drains it.
    """
    from session_state import atomic_text
    name = str(payload.get("tool_name") or payload.get("toolName") or "").rsplit(".", 1)[-1].lower()
    if name not in {"write_stdin", "read_bash", "taskoutput"}:
        return False
    args = classifier().payload_tool_input(payload)
    if not isinstance(args, dict) or args.get("chars"):
        return False
    handle = args.get({"write_stdin": "session_id", "read_bash": "shellId", "taskoutput": "task_id"}[name])
    key = tool_key(payload)
    if not handle or not key:
        return False
    family = "exec" if name == "write_stdin" else "shell"
    background = "background:" + hashlib.sha256(f"{family}:{handle}".encode()).hexdigest()
    file = store.route(provider, session)
    with store.lock(preview=preview):
        row = store.read(file)
        pending = store.tools(file)
        if not row.get("task") or background not in pending:
            return False
        store.exclusive(file, row["task"])
        if not preview:
            if key.startswith("anonymous:"):
                pending.setdefault(key, []).append(pending[background])
            else:
                pending[key] = pending[background]
            atomic_text(file.with_suffix(".tools"), json.dumps(pending))
        return True


def begin_tool(store, provider: str, session: str, payload: dict, *, preview: bool = False) -> None:
    from session_state import SessionError, atomic_text
    module = classifier()
    poll = str(payload.get("tool_name") or payload.get("toolName") or "").rsplit(".", 1)[-1].lower() in {"write_stdin", "read_bash", "taskoutput"}
    if (module.is_read_only_call(payload) and not poll) or is_helper(payload):
        return
    file = store.route(provider, session)
    with store.lock(preview=preview):
        row = store.read(file)
        task = row.get("task") or row.get("associated")
        if not task or row.get("status") not in {"owned", "discussing", "creating"}:
            return
        args = module.payload_tool_input(payload)
        command = module.shell_command_text(args)
        # Shell detachment has no completion event. Use the host's tracked async
        # tool instead; its returned handle remains outstanding until collected.
        if command and any(segment.terminator == "&" or {"nohup", "setsid"}.intersection(segment.argv)
                           for segment in (module.shell_segments(command) or [])):
            raise SessionError("untracked shell detachment cannot safely yield execution; use a native asynchronous tool and collect its result")
        turn = turn_id(payload)
        if turn and row.get("turn") and turn != row["turn"]:
            raise SessionError("tool belongs to an earlier turn; bind and restore the current prompt")
        if row["status"] == "discussing":
            if module.plan_op_class(payload, store.task_path(task)) != "record":
                return
            store.exclusive(file, task)
        store.require_fresh(row, task)
        if preview:
            return
        if not row.get("task"):
            row.update(task=task, runtime=runtime_identity())
            atomic_text(file, "".join(f"{key}={value}\n" for key, value in row.items()))
        key = tool_key(payload)
        if key:
            pending = store.tools(file)
            from tool_recovery import remember_attempt
            remember_attempt(file, pending, key, row.get("generation", "legacy"), command)
            if key.startswith("anonymous:"):
                pending.setdefault(key, []).append(row.get("generation", "legacy"))
            else:
                pending[key] = row.get("generation", "legacy")
            atomic_text(file.with_suffix(".tools"), json.dumps(pending))


def end_tool(store, provider: str, session: str, payload: dict) -> bool:
    from session_state import atomic_text
    file = store.route(provider, session)
    if not file.exists():
        return True
    with store.lock():
        row = store.read(file)
        task = row.get("task") or row.get("associated")
        pending = store.tools(file)
        key = tool_key(payload)
        generation = pending.get(key)
        if isinstance(generation, list):
            generation = generation.pop(0)
            if not pending[key]:
                pending.pop(key)
        else:
            pending.pop(key, None)
        background, running = background_result(payload)
        if background:
            if running and generation is not None:
                pending[background] = generation
            elif not running and generation is not None and pending.get(background) == generation:
                pending.pop(background, None)
        if generation is not None or background:
            atomic_text(file.with_suffix(".tools"), json.dumps(pending))
        if generation == row.get("generation", "legacy") and task:
            if store.task_path(task, exists=False).exists():
                store.remember_read(file, task)
        return generation is None or generation == row.get("generation", "legacy")
