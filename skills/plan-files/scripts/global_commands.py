"""Short command names that `make install` links onto PATH, and how messages spell commands."""

from __future__ import annotations

import shutil
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
REPO = SCRIPTS.parents[2]
ADAPTER_DIRS = {"codex": ".codex/hooks/plan-files/scripts", "claude": ".claude/hooks/plan-files/scripts",
                "copilot": ".github/hooks/scripts", "grok": ".grok/hooks/plan-files/scripts"}
BIND_COMMANDS = {f"pwf-bind-{provider}" for provider in ADAPTER_DIRS}
HELPER_COMMANDS = {"plan_state.py", "plan_edit.py", "plan_checkpoint.py"}


def global_name(name: str, target: Path) -> str | None:
    """NAME when it is on PATH and runs exactly TARGET, so a look-alike earlier on PATH is never advertised."""
    found = shutil.which(name)
    if found is None or Path(found).resolve() != target.resolve():
        return None
    return name


def adapter_path(provider: str) -> Path:
    return REPO / ADAPTER_DIRS[provider] / "bind-session.sh"


def installed(name: str) -> bool:
    """True when the bare short NAME runs this checkout's own helper or bind adapter."""
    if name in HELPER_COMMANDS:
        return global_name(name, SCRIPTS / name) is not None
    if name in BIND_COMMANDS:
        return global_name(name, adapter_path(name.removeprefix("pwf-bind-"))) is not None
    return False


def helper_command(name: str, quoted_path: str) -> str:
    """A helper's global name when installed, otherwise python3 with its already-quoted path."""
    return global_name(name, SCRIPTS / name) or f"python3 {quoted_path}"


def bind_command(bind_tool: Path, quoted_path: str) -> str:
    """The provider's pwf-bind name when installed, otherwise bash with the adapter's already-quoted path."""
    for name in sorted(BIND_COMMANDS):
        if global_name(name, bind_tool):
            return name
    return f"bash {quoted_path}"
