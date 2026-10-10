"""Normalize host-written terminal errors; never interpret tool output as events.

Claude does not emit PostToolUseFailure for calls rejected by another PreTool
hook or a permission rule. Its transcript contains a correlated, typed error
result even in that case. Other providers keep their native completion paths.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path


TRANSCRIPT_LIMIT = 16 * 1024 * 1024


def terminal_error_keys(provider: str, session: str, path: str, pending: set[str]) -> set[str]:
    """Read a bounded tail of the current host's transcript, failing closed.

    Only complete JSONL records for this session with a native error flag count.
    Successful results can represent background dispatch and are deliberately not
    reconciled here. Missing/changed formats require native completion or reclaim.
    """
    if provider != "claude" or not isinstance(path, str) or not path or not pending:
        return set()
    transcript = Path(path)
    try:
        if not transcript.is_absolute() or not transcript.is_file():
            return set()
        with transcript.open("rb") as stream:
            size = stream.seek(0, 2)
            start = max(0, size - TRANSCRIPT_LIMIT)
            stream.seek(start)
            data = stream.read(TRANSCRIPT_LIMIT)
    except OSError:
        return set()
    if start:
        # The first line may have been cut in half by the bounded read.
        data = data.partition(b"\n")[2]
    finished = set()
    for line in data.splitlines(keepends=True):
        if not line.endswith(b"\n"):
            continue  # Writer has not committed this record yet.
        try:
            record = json.loads(line)
        except (ValueError, UnicodeError):
            continue
        if (not isinstance(record, dict) or record.get("type") != "user"
                or record.get("sessionId") != session or record.get("isSidechain")):
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
