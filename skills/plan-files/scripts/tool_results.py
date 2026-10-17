"""Normalize host-written terminal events; never interpret tool output as events.

Claude does not emit PostToolUseFailure for calls rejected by another PreTool
hook or a permission rule. Its transcript contains a correlated, typed error
result even in that case. It also reports background completion as a queued
notification prompt whose origin only the transcript records. Other providers
keep their native completion paths.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys


TRANSCRIPT_LIMIT = 16 * 1024 * 1024
NOTIFICATION_RE = re.compile(r"<task-notification>(.*?)</task-notification>", re.S)


def transcript_records(session: str, path: str, start: int | None = None) -> list[tuple[int, dict]]:
    """(byte offset, record) for complete main-thread records of this session.

    Reads a bounded tail, or from `start` when that fits within the same bound.
    """
    if not isinstance(path, str) or not path:
        return []
    transcript = Path(path)
    try:
        if not transcript.is_absolute() or not transcript.is_file():
            return []
        with transcript.open("rb") as stream:
            size = stream.seek(0, 2)
            partial = start is None and size > TRANSCRIPT_LIMIT
            if start is None:
                start = max(0, size - TRANSCRIPT_LIMIT)
            elif size - start > TRANSCRIPT_LIMIT:
                return []
            stream.seek(start)
            data = stream.read(TRANSCRIPT_LIMIT)
    except OSError:
        return []
    position = start
    if partial:
        # The first line may have been cut in half by the bounded read.
        cut, _, data = data.partition(b"\n")
        position += len(cut) + 1
    records = []
    for line in data.splitlines(keepends=True):
        offset = position
        position += len(line)
        if not line.endswith(b"\n"):
            continue  # Writer has not committed this record yet.
        try:
            record = json.loads(line)
        except (ValueError, UnicodeError):
            continue
        if isinstance(record, dict) and record.get("sessionId") == session and not record.get("isSidechain"):
            records.append((offset, record))
    return records


def notification_field(block: str, name: str) -> str:
    match = re.search(f"<{name}>([^<]+)</{name}>", block)
    return match[1].strip() if match else ""


def queued_prompt(record: dict) -> dict:
    attachment = record.get("attachment")
    if record.get("type") != "attachment" or not isinstance(attachment, dict):
        return {}
    if attachment.get("type") != "queued_command":
        return {}
    return attachment


def prompt_notice(payload: dict) -> str:
    """"<enqueue offset>:<prompt digest>" for a prompt made only of task notifications.

    The host logs a task notification's enqueue before UserPromptSubmit and its
    delivery after. A typed prompt is screened before its enqueue is logged, so
    only an enqueue still awaiting delivery can belong to this prompt.
    """
    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or not NOTIFICATION_RE.search(prompt) or NOTIFICATION_RE.sub("", prompt).strip():
        return ""
    offset = None
    for position, record in transcript_records(str(payload.get("session_id", "")), payload.get("transcript_path")):
        if (record.get("type") == "queue-operation" and record.get("operation") == "enqueue"
                and record.get("content") == prompt):
            offset = position
        elif queued_prompt(record).get("prompt") == prompt:
            offset = None  # Already delivered; it cannot be the prompt being submitted now.
    if offset is None:
        return ""
    return f"{offset}:{hashlib.sha256(prompt.encode()).hexdigest()}"


def host_notified(provider: str, session: str, path: str, notice: str) -> bool:
    """Whether the host delivered the queue entry a notice names as its own notification.

    Users can type the same text; the host records typed prompts with
    commandMode "prompt" and its own with "task-notification".
    """
    offset, _, digest = notice.partition(":")
    if provider != "claude" or not offset.isdigit() or not digest:
        return False
    for _, record in transcript_records(session, path, int(offset)):
        attachment = queued_prompt(record)
        if attachment and hashlib.sha256(str(attachment.get("prompt", "")).encode()).hexdigest() == digest:
            return attachment.get("commandMode") == "task-notification"
    return False


def finished_tasks(provider: str, session: str, path: str) -> set[str]:
    """Background task ids with a terminal host notification."""
    if provider != "claude":
        return set()
    tasks = set()
    for _, record in transcript_records(session, path):
        attachment = queued_prompt(record)
        if attachment.get("commandMode") != "task-notification":
            continue
        for block in NOTIFICATION_RE.findall(str(attachment.get("prompt", ""))):
            if notification_field(block, "status") in {"completed", "failed", "killed", "stopped"}:
                tasks.add(notification_field(block, "task-id"))
    return tasks


def terminal_error_keys(provider: str, session: str, path: str, pending: set[str]) -> set[str]:
    """Read a bounded tail of the current host's transcript, failing closed.

    Only complete JSONL records for this session with a native error flag count.
    Successful results can represent background dispatch and are deliberately not
    reconciled here. Missing/changed formats require native completion or reclaim.
    """
    if provider != "claude" or not pending:
        return set()
    finished = set()
    for _, record in transcript_records(session, path):
        if record.get("type") != "user":
            continue
        message = record.get("message")
        if not isinstance(message, dict) or message.get("role") != "user":
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if (not isinstance(block, dict) or block.get("type") != "tool_result"
                    or block.get("is_error") is not True):
                continue
            call = block.get("tool_use_id")
            if isinstance(call, str) and call:
                key = hashlib.sha256(call.encode()).hexdigest()
                if key in pending:
                    finished.add(key)
    return finished


if __name__ == "__main__":
    if sys.argv[1:] == ["notice"]:
        print(prompt_notice(json.load(sys.stdin)), end="")
