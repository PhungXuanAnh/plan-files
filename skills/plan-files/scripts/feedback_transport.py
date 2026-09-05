#!/usr/bin/env python3
"""Deliver complete hook reasons through a private file for capped hosts."""

import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


def feedback_dir() -> Path:
    # Keep the advertised path short even when the workspace/install path is long.
    return Path("/tmp") / f"plan-files-feedback-{os.getuid()}"


def feedback_path(scope: str) -> Path:
    return feedback_dir() / (hashlib.sha256(scope.encode()).hexdigest() + ".md")


def private_directory(create: bool = False) -> bool:
    directory = feedback_dir()
    if create:
        directory.mkdir(mode=0o700, exist_ok=True)
    try:
        info = directory.lstat()
        return (stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
                and not stat.S_IMODE(info.st_mode) & 0o077)
    except OSError:
        return False


def valid_file(path: Path) -> bool:
    if path.parent != feedback_dir() or not private_directory():
        return False
    try:
        info = path.lstat()
        return (stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and not stat.S_IMODE(info.st_mode) & 0o077)
    except OSError:
        return False


def contains_path(value: object, path: str) -> bool:
    """The user-authorized gate exception is input-based, not tool-name-based."""
    if isinstance(value, str):
        return path in value
    if isinstance(value, list):
        return any(contains_path(item, path) for item in value)
    if isinstance(value, dict):
        return any(contains_path(key, path) or contains_path(item, path)
                   for key, item in value.items())
    return False


def render(path: Path, reason: str, limit: int) -> dict:
    if len(reason) <= limit:
        return {"decision": "block", "reason": reason}
    if path.parent != feedback_dir() or not private_directory(create=True):
        raise ValueError("feedback directory is not private")
    short = (f"[plan-files] Blocked. Read full instructions: `{path}`. "
             "Any tool with this path in its arguments is allowed. "
             "Follow the instructions, then retry.")
    if len(short) > limit:
        raise ValueError("feedback pointer exceeds host reason budget")
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".feedback-")
    try:
        with os.fdopen(fd, "w") as output:
            output.write(reason + "\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return {"decision": "block", "reason": short}


def main() -> int:
    operation, argument = sys.argv[1:3]
    if operation in {"path", "clear"}:
        path = feedback_path(argument)
        if operation == "path":
            print(path)
        elif valid_file(path):
            path.unlink()
        return 0
    path = Path(argument)
    if operation == "allows":
        return 0 if valid_file(path) and contains_path(json.load(sys.stdin), str(path)) else 1
    if operation == "render":
        print(json.dumps(render(path, sys.stdin.read(), int(sys.argv[3])), ensure_ascii=False))
        return 0
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, IndexError) as error:
        print(f"feedback transport: {error}", file=sys.stderr)
        sys.exit(1)
