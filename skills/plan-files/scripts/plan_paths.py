"""The authoritative plan filename, with temporary legacy compatibility."""

from pathlib import Path
import sys


PLAN_FILENAME = "plan.md"
LEGACY_PLAN_FILENAME = "tasks.md"
PLAN_FILENAMES = (PLAN_FILENAME, LEGACY_PLAN_FILENAME)


def resolve_plan_file(directory: Path) -> Path:
    """Select an existing plan without renaming it; new plans use plan.md."""
    for name in PLAN_FILENAMES:
        path = directory / name
        if path.is_file():
            return path
    return directory / PLAN_FILENAME


def conflicting_plan_files(plan: Path) -> bool:
    """A task must have one authoritative filename, including file aliases."""
    if plan.name not in PLAN_FILENAMES:
        return False  # Temporary candidates used for validation are not plans.
    canonical, legacy = (plan.parent / name for name in PLAN_FILENAMES)
    return canonical.is_file() and legacy.is_file()


if __name__ == "__main__":
    print(resolve_plan_file(Path(sys.argv[1])), end="")
