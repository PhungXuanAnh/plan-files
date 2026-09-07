#!/usr/bin/env python3
"""Classify planning tool calls and extract deterministic plan targets.

Read operations may inspect the project. Plan maintenance is recognized from
the tool input itself rather than from a particular mutation tool name. The
optional extraction modes support prompt candidate routing and mutation-time
session ownership without trusting incidental plan prose.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import NamedTuple


QUESTION_TOOLS = {"askuserquestion", "ask_user_question", "request_user_input", "request_user_input_async"}


READ_TOOL_PREFIXES = (
    "read",
    "get_",
    "find_",
    "list_",
    "search_",
    "inspect_",
    "rg",
    "grep",
    "cat",
)
READ_COMMANDS = {
    "awk",
    "basename",
    "cat",
    "cd",
    "column",
    "cut",
    "date",
    "diff",
    "dirname",
    "du",
    "echo",
    "file",
    "grep",
    "head",
    "jq",
    "ls",
    "md5sum",
    "nl",
    "printf",
    "pwd",
    "readlink",
    "realpath",
    "rg",
    "sha256sum",
    "sort",
    "stat",
    "tail",
    "tr",
    "true",
    "uniq",
    "wc",
    "which",
}
# Read-only only when their mutating flags are absent.
GUARDED_READ_COMMANDS = {
    "find": ("-delete", "-exec", "-execdir", "-ok", "-okdir", "-fls", "-fprint", "-fprintf"),
    "sed": ("-i", "--in-place"),
}
# Redirections that cannot write observable state.
DISCARD_REDIRECTS = ("2>/dev/null", "2>&1", "&>/dev/null", ">/dev/null", "2> /dev/null", "> /dev/null")
# Control operators that separate one command from the next, recognized only
# outside quotes.
SEGMENT_OPERATOR_CHARS = "&|;\n"
READ_GIT_SUBCOMMANDS = {
    "diff",
    "grep",
    "log",
    "ls-files",
    "ls-tree",
    "rev-parse",
    "show",
    "status",
}
# Read intent anywhere in the name, not only at its start: `jira_search` and
# `get_pull_request` are reads that the prefix list alone classified as unknown
# writes, so every gated state refused them.
READ_TOOL_TOKENS = {
    "cat",
    "describe",
    "diff",
    "exists",
    "fetch",
    "find",
    "get",
    "grep",
    "inspect",
    "list",
    "load",
    "lookup",
    "ls",
    "peek",
    "query",
    "read",
    "rg",
    "search",
    "show",
    "stat",
    "summarize",
    "view",
}
MUTATION_TOOL_TOKENS = {
    "create",
    "delete",
    "edit",
    "insert",
    "move",
    "patch",
    "remove",
    "rename",
    "replace",
    "write",
}
# A write verb beside a read verb makes the call a write: `search_and_replace`
# and `create_from_search` must not read as reads. Kept separate from
# MUTATION_TOOL_TOKENS so widening the read veto cannot widen what the
# PostToolUse counters call an operational mutation.
READ_VETO_TOKENS = MUTATION_TOOL_TOKENS | {
    "add",
    "append",
    "apply",
    "close",
    "commit",
    "merge",
    "modify",
    "post",
    "publish",
    "push",
    "send",
    "set",
    "submit",
    "update",
    "upload",
}
SHELL_TOOL_NAMES = {
    "bash",
    "shell",
    "terminal",
    "exec",
    "exec_command",
    "run_command",
    "run_terminal_cmd",
    "run_terminal_command",
}
EVIDENCE_TOOL_TOKENS = {
    "check",
    "click",
    "monitor",
    "poll",
    "screenshot",
    "test",
    "verify",
    "wait",
}
EVIDENCE_COMMAND_RE = re.compile(
    r"(^|\s)(pytest|unittest|make\s+(?:test|check)|npm\s+(?:test|run\s+test)|"
    r"pnpm\s+(?:test|run\s+test)|yarn\s+test|cargo\s+test|go\s+test|"
    r"mvn\s+test|gradle\s+test)(\s|$)",
    re.IGNORECASE,
)
TASK_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
TEXT_PLAN_PATH_RE = re.compile(
    r"(?P<path>(?:[A-Za-z]:)?[^\s\"'`<>|]*?tmp[\\/]+plan(?:-with)?-files[\\/]"
    r"[A-Za-z0-9._-]+[\\/]+[^\s\"'`<>|]*?\.md)"
    r"(?=$|[\s\"'`<>|)\]},;:])"
)


def name_tokens(name: str) -> set[str]:
    """Every word in a tool name, split on separators and on camelCase."""
    tokens: set[str] = set()
    for part in re.split(r"[^A-Za-z0-9]+", name):
        if not part:
            continue
        tokens.add(part.lower())
        for piece in re.findall(r"[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+", part):
            tokens.add(piece.lower())
    return tokens


def names_read_tool(simple_name: str) -> bool:
    """True when the tool's own name states that it reads.

    A read token anywhere in the name counts, not only at its start, unless a
    write verb sits beside it. The veto also applies to the historical prefix
    list, which read `search_and_replace` and `get_and_delete` as reads.
    """
    tokens = name_tokens(simple_name)
    if tokens & READ_VETO_TOKENS:
        return False
    if any(simple_name.startswith(prefix) for prefix in READ_TOOL_PREFIXES):
        return True
    return bool(tokens & READ_TOOL_TOKENS)


def strings(value: object):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def inside(path: str, plan_dir: Path) -> bool:
    candidate = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
    candidate = os.path.realpath(candidate)
    root = str(plan_dir)
    return candidate == root or candidate.startswith(root + os.sep)


PATH_KEYS = {
    "path",
    "file",
    "file_path",
    "filepath",
    "relative_path",
    "target",
    "target_path",
}
PATH_LIST_KEYS = {"paths", "files", "targets", "target_paths"}


def explicit_paths(value: object) -> list[str]:
    """Return explicit path-like fields recursively, independent of tool name."""
    paths: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            key_lower = str(key).lower()
            if key_lower in PATH_KEYS and isinstance(child, str):
                paths.append(child)
            elif key_lower in PATH_LIST_KEYS and isinstance(child, list):
                paths.extend(item for item in child if isinstance(item, str))
            else:
                paths.extend(explicit_paths(child))
    elif isinstance(value, list):
        for child in value:
            paths.extend(explicit_paths(child))
    return paths


def patch_paths(tool_input: object) -> list[str]:
    """Find apply-patch target markers anywhere in the tool input strings."""
    paths: list[str] = []
    for text in strings(tool_input):
        paths.extend(
            path.strip()
            for path in re.findall(
                r"^\*\*\* (?:Update|Add|Delete) File: (.+)$", text, re.MULTILINE
            )
        )
    return paths


def mutation_targets(tool_input: object) -> list[str]:
    """Collect recognizable writable targets without depending on tool identity."""
    return list(dict.fromkeys(explicit_paths(tool_input) + patch_paths(tool_input)))


def text_plan_paths(value: object) -> list[str]:
    """Extract exact plan Markdown path tokens from strings in a payload."""
    paths: list[str] = []
    for text in strings(value):
        normalized = text.replace("\\", "/")
        paths.extend(match.group("path") for match in TEXT_PLAN_PATH_RE.finditer(normalized))
    return list(dict.fromkeys(paths))


REQUIRED_PLAN_FILES = {"tasks.md", "findings.md", "decisions.md"}


def plan_id_for_path(path: str, project_root: Path) -> str | None:
    """Resolve a path under this project's plan root and return its task id."""
    cleaned = path.strip().lstrip("([{=:").rstrip(")]},;:")
    candidate = Path(cleaned)
    if not candidate.is_absolute():
        candidate = project_root / candidate
    candidate = Path(os.path.realpath(candidate))
    # Match either layout so a pre-rename workspace is still recognized as
    # plan state rather than as unrelated files.
    plan_root = project_root / "tmp" / "plan-files"
    if not plan_root.is_dir() and (project_root / "tmp" / "plan-with-files").is_dir():
        plan_root = project_root / "tmp" / "plan-with-files"
    plan_root = Path(os.path.realpath(plan_root))
    try:
        relative = candidate.relative_to(plan_root)
    except ValueError:
        return None
    if len(relative.parts) < 2 or candidate.suffix.lower() != ".md":
        return None
    task_id = relative.parts[0]
    if not TASK_ID_RE.fullmatch(task_id) or task_id in {".", "..", ".sessions"}:
        return None
    # A task is a recognized mutation target once its tasks.md already
    # exists on disk, OR when this write is itself creating one of the three
    # required plan files for a brand-new task — tasks.md necessarily doesn't
    # exist yet precisely because this very call is the one creating it.
    # Without this second branch, a new plan's very first Write is never
    # auto-claimed (tasks.md can't already exist before it's written), so the
    # session stays unowned until some later edit happens to touch an
    # already-existing file — silently defeating auto-claim for exactly the
    # moment it matters most: task creation.
    if (plan_root / task_id / "tasks.md").is_file():
        return task_id
    if candidate.name.lower() in REQUIRED_PLAN_FILES:
        return task_id
    return None


def plan_ids(paths: list[str], project_root: Path) -> set[str]:
    return {
        task_id
        for path in paths
        if (task_id := plan_id_for_path(path, project_root)) is not None
    }


def shell_has_mutation_intent(tool_input: object) -> bool:
    command = ""
    if isinstance(tool_input, dict):
        command = tool_input.get("command") or tool_input.get("cmd") or ""
    elif isinstance(tool_input, str):
        command = tool_input
    if not isinstance(command, str):
        return False
    if patch_paths(tool_input):
        return True
    mutation_command = re.compile(
        r"(^|[;&|]\s*)(apply_patch|cp|install|mv|rm|touch|truncate|tee|chmod|chown)\b"
        r"|(^|[;&|]\s*)(sed|perl)\b[^\n;&|]*\s-[A-Za-z]*i[A-Za-z]*\b"
        r"|(^|[^<>])>{1,2}(?!=)",
        re.IGNORECASE,
    )
    return mutation_command.search(command) is not None


def is_mutation_tool(tool_name: str, tool_input: object) -> bool:
    simple_name = tool_name.lower().rsplit("__", 1)[-1]
    if simple_name in SHELL_TOOL_NAMES:
        return shell_has_mutation_intent(tool_input)
    tokens = set(re.split(r"[^a-z0-9]+", simple_name))
    return bool(tokens & MUTATION_TOOL_TOKENS)


def payload_tool_input(payload: dict) -> object:
    if "tool_input" in payload:
        return payload.get("tool_input")
    return payload.get("toolInput")


def print_single_plan_id(ids: set[str]) -> int:
    if len(ids) == 1:
        sys.stdout.write(next(iter(ids)))
        return 0
    return 2 if ids else 1


def extract_prompt_plan_id(payload: dict, project_root: Path) -> int:
    prompt_values = [
        payload.get("prompt"),
        payload.get("transformedPrompt"),
        payload.get("transformed_prompt"),
    ]
    paths = text_plan_paths([value for value in prompt_values if isinstance(value, str)])
    return print_single_plan_id(plan_ids(paths, project_root))


def extract_mutation_plan_id(payload: dict, project_root: Path) -> int:
    tool_name = str(payload.get("tool_name") or payload.get("toolName") or "")
    tool_input = payload_tool_input(payload)
    if not is_mutation_tool(tool_name, tool_input):
        return 1
    targets = mutation_targets(tool_input)
    if not targets:
        targets = text_plan_paths(tool_input)
    return print_single_plan_id(plan_ids(targets, project_root))


def tool_class(payload: dict, plan_dir: Path) -> dict[str, object]:
    tool_name = str(payload.get("tool_name") or payload.get("toolName") or "")
    simple_name = tool_name.lower().rsplit("__", 1)[-1]
    tool_input = payload_tool_input(payload)
    mutation = is_mutation_tool(tool_name, tool_input)
    targets = mutation_targets(tool_input)
    plan_maintenance = mutation and (
        (bool(targets) and all(inside(path, plan_dir) for path in targets))
        or (shell_runs_planning_helper(tool_input, plan_dir) if simple_name in SHELL_TOOL_NAMES
            else references_owned_plan(tool_input, plan_dir))
    )
    if plan_maintenance:
        category = "plan_maintenance"
        semantic_weight = 0
    elif simple_name.rsplit(".", 1)[-1] in QUESTION_TOOLS or names_read_tool(simple_name) or (
        simple_name in SHELL_TOOL_NAMES and bash_is_read_only(tool_input)
    ):
        category = "read_only_exploration"
        semantic_weight = 0
    else:
        command = ""
        if isinstance(tool_input, dict):
            command = tool_input.get("command") or tool_input.get("cmd") or ""
        elif isinstance(tool_input, str):
            command = tool_input
        tokens = set(re.split(r"[^a-z0-9]+", simple_name))
        if (isinstance(command, str) and EVIDENCE_COMMAND_RE.search(command)) or tokens & EVIDENCE_TOOL_TOKENS:
            category = "evidence_likely"
            semantic_weight = 2
        elif mutation:
            category = "operational_mutation"
            semantic_weight = 1
        else:
            category = "unknown"
            semantic_weight = 1
    return {
        "class": category,
        "semantic_weight": semantic_weight,
        "mutation": mutation,
        "plan_maintenance": plan_maintenance,
    }


def references_owned_plan(tool_input: object, plan_dir: Path) -> bool:
    """Fallback for unknown schemas: an argument that IS a path in the owned plan.

    A whole argument, never a path quoted inside a longer string. A tool whose
    arguments this gate cannot parse proves nothing by mentioning the plan: an
    unrelated call carrying `note: "see <plan>/tasks.md"` would otherwise read
    as plan maintenance and pass a closed gate on the strength of its prose.
    """
    roots = {str(plan_dir).replace("\\", "/")}
    try:
        relative = os.path.relpath(plan_dir, os.getcwd()).replace("\\", "/")
    except ValueError:
        relative = ""
    if relative and relative != ".":
        roots.add(relative.rstrip("/"))

    for value in strings(tool_input):
        normalized = value.strip().replace("\\", "/")
        for root in roots:
            if normalized == root or normalized.startswith(root + "/"):
                return True
    return False


def _is_redirect_ampersand(command: str, index: int) -> bool:
    """True for the `&` of `2>&1`, `>&2`, or `&>file`, which joins no commands."""
    previous = command[:index].rstrip()
    return previous.endswith(">") or command[index + 1 : index + 2] == ">"


SUBSTITUTION_MARK = "\x00substitution:%d\x00"
SUBSTITUTION_RE = re.compile(r"\x00substitution:(\d+)\x00")


def _strip_substitutions(command: str) -> tuple[str, list[str]] | None:
    """Replace every command substitution with a mark and return them separately.

    shlex cannot lex `"$(sha256sum 'a b' | cut -d' ' -f1)"`: quoting restarts
    inside a substitution, so read linearly the quotes never balance and the
    whole command looks malformed. A substitution is a command in its own right
    anyway -- lifting it out keeps the outer command lexable and lets the inner
    one be judged on its own terms. Nested substitutions stay inside the text
    they are lifted with; whoever reads that text judges it, or refuses to.

    Returns None when the command cannot be read at all, which callers must
    never treat as permission.
    """
    outer: list[str] = []
    inner: list[str] = []
    commands: list[str] = []
    quote: str | None = None
    stack: list[str | None] = []
    backtick = False
    index = 0
    while index < len(command):
        char = command[index]
        nested = bool(stack) or backtick
        if quote == "'":
            # Nothing is special inside single quotes, not even a backslash.
            (inner if nested else outer).append(char)
            if char == "'":
                quote = None
            index += 1
            continue
        if char == "\\" and index + 1 < len(command):
            (inner if nested else outer).extend(command[index : index + 2])
            index += 2
            continue
        if char in "\"'":
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
            (inner if nested else outer).append(char)
            index += 1
            continue
        if command.startswith("$((", index):
            return None  # arithmetic expansion, not a command this can vet
        if command.startswith("$(", index):
            if nested:
                inner.append("$(")
            else:
                outer.append(SUBSTITUTION_MARK % len(commands))
            stack.append(quote)
            quote = None
            index += 2
            continue
        if char == ")" and stack:
            quote = stack.pop()
            if stack or backtick:
                inner.append(char)
            else:
                commands.append("".join(inner))
                inner = []
            index += 1
            continue
        if char == "`":
            if backtick:
                backtick = False
                commands.append("".join(inner))
                inner = []
            elif stack:
                inner.append(char)
            else:
                backtick = True
                outer.append(SUBSTITUTION_MARK % len(commands))
            index += 1
            continue
        (inner if nested else outer).append(char)
        index += 1
    if quote or stack or backtick:
        return None
    return "".join(outer), commands


class Segment(NamedTuple):
    """One command in a compound command, with what it substitutes lifted out."""

    argv: list[str]
    terminator: str
    text: str
    substitutions: list[str]


def shell_segments(command: str) -> list[Segment] | None:
    """Split a command into segments at the control operators that separate them.

    Quote-aware, and that is the whole point. Splitting the raw text with a
    plain regex shattered any command carrying an operator inside a quoted
    argument -- every decisions.md table row holds three `|` -- into fragments
    with unbalanced quotes. Every fragment then failed to lex, the command
    matched no recognized shape, and the gate blocked the exact
    `plan_edit.py entry-append` its own message had just prescribed.

    Returns None when the command cannot be read at all.
    """
    stripped = _strip_substitutions(command)
    if stripped is None:
        return None
    lexable, substituted = stripped
    pieces: list[tuple[str, str]] = []
    current: list[str] = []
    quote: str | None = None
    index = 0
    while index < len(lexable):
        char = lexable[index]
        if quote == "'":
            current.append(char)
            if char == "'":
                quote = None
            index += 1
            continue
        if char == "\\" and index + 1 < len(lexable):
            current.extend(lexable[index : index + 2])
            index += 2
            continue
        if char in "\"'":
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
            current.append(char)
            index += 1
            continue
        if (quote is None and char in SEGMENT_OPERATOR_CHARS
                and not (char in "&|" and _is_redirect_ampersand(lexable, index))):
            operator = char
            while char in "&|" and index + 1 < len(lexable) and lexable[index + 1] == char:
                index += 1
                operator += char
            pieces.append(("".join(current), operator))
            current = []
            index += 1
            continue
        current.append(char)
        index += 1
    if quote:
        return None
    pieces.append(("".join(current), ""))

    segments: list[Segment] = []
    for text, terminator in pieces:
        if not text.strip():
            continue
        try:
            argv = shlex.split(text)
        except ValueError:
            return None
        if argv:
            segments.append(Segment(
                argv,
                terminator,
                text,
                # A forged mark in the original text indexes nothing real, so
                # bound the lookup rather than raising out of the gate.
                [substituted[index] for mark in SUBSTITUTION_RE.findall(text)
                 if (index := int(mark)) < len(substituted)],
            ))
    return segments


def bash_is_read_only(tool_input: object) -> bool:
    # A pipeline or a cd/echo prefix is still read-only when every segment is.
    # The previous all-or-nothing bail made ordinary exploration such as
    # `cd repo && grep -n foo bar.py` look like an operational mutation, which
    # inflated the post-tool stale-checkpoint counter with pure noise.
    segments = shell_segments(shell_command_text(tool_input))
    if not segments:
        return False
    return all(_segment_is_read_only(segment) for segment in segments)


ENV_WRAPPERS = {"env", "nohup", "setsid"}
HELP_FLAGS = {"--help", "-h", "--version", "-V"}


def _command_start(words: list[str]) -> int | None:
    """Index of the program a segment actually runs, past env assignments.

    `PLANE_INSECURE=1 cat file` runs cat. Reading argv[0] as the executable made
    any leading assignment unclassifiable, so a read-only query carrying one
    looked like an unknown mutation to every gate that asks -- which is how a
    discussion turn ended up refusing the read-only API calls it exists to allow.
    """
    return next((index for index, word in enumerate(words)
                 if "=" not in word and Path(word).name not in ENV_WRAPPERS), None)


def _segment_is_read_only(segment: Segment, allow_substitutions: bool = False) -> bool:
    if not segment.argv:
        return False
    # Command substitution can hide arbitrary mutation behind a read-only shape.
    # A caller with a reason to accept one -- `echo "pointer=$(cat .plan-files)"`
    # appended to a routing command -- still holds it to the same read-only test
    # as any other command, which is what allow_substitutions asks for.
    if segment.substitutions and not (allow_substitutions and _substitutions_are_read_only(segment)):
        return False
    # Strip redirections that only discard output, then reject any that remain:
    # a surviving > or < can write or consume real files.
    probe = segment.text
    for token in DISCARD_REDIRECTS:
        probe = probe.replace(token, " ")
    if ">" in probe or "<" in probe:
        return False
    start = _command_start(segment.argv)
    if start is None:
        return False
    executable = os.path.basename(segment.argv[start])
    operands = segment.argv[start + 1:]
    if executable in READ_COMMANDS:
        return True
    if executable in GUARDED_READ_COMMANDS:
        forbidden = GUARDED_READ_COMMANDS[executable]
        return not any(arg.startswith(flag) for arg in operands for flag in forbidden)
    if executable == "git" and operands and operands[0] in READ_GIT_SUBCOMMANDS:
        return True
    # A help or version probe on a planning helper writes nothing: these are the
    # argparse programs this repo owns, and they print usage and exit. It is not
    # generalized to any executable on purpose -- a shell script that ignores its
    # arguments would run its real work, and reading the script is the safe way
    # to learn an unknown program.
    call = _planning_helper_call(segment.argv)
    if call is not None and any(word in HELP_FLAGS for word in call[1]):
        return True
    return False


def load_payload() -> dict | None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


PLANNING_HELPERS = {"plan_state.py", "plan_edit.py", "plan_checkpoint.py", "session-state.sh",
                    "resolve-project-root.sh", "bind-session.sh"}


def shell_command_text(payload_or_input: object) -> str:
    args = payload_or_input
    command = (args.get("command") or args.get("cmd") or "") if isinstance(args, dict) else args
    return command if isinstance(command, str) else ""


def _planning_helper_call(words: list[str]) -> tuple[str, list[str]] | None:
    """The planning helper this segment runs and the operands it passes it.

    Inspects the program actually run, never an incidental argument: naming a
    helper or a plan path inside some other command grants nothing.
    """
    start = _command_start(words)
    if start is None:
        return None
    executable = Path(words[start]).name
    operands = words[start + 1:]
    if executable in {"python", "python3", "bash", "sh"}:
        if "-c" in operands or "-m" in operands:
            return None
        script = next((word for word in operands if not word.startswith("-")), "")
        name = Path(script).name
        if name not in PLANNING_HELPERS:
            return None
        return name, operands[operands.index(script) + 1:]
    if executable in PLANNING_HELPERS:
        return executable, operands
    return None


def _segment_runs_planning_helper(words: list[str]) -> bool:
    if _planning_helper_call(words) is not None:
        return True
    # Path discovery for a helper is read-only and counts as running one.
    start = _command_start(words)
    if start is None:
        return False
    if Path(words[start]).name in {"find", "rg", "ls", "readlink", "realpath"}:
        return any(Path(word).name in PLANNING_HELPERS for word in words[start + 1:])
    return False


def planning_helper_segments(command: str):
    """Yield the segments that run a planning helper.

    Each carries the control operator that ended it, so a caller can tell
    `helper &` from `helper && next` without lexing the text again.
    """
    for segment in shell_segments(command) or []:
        if _segment_runs_planning_helper(segment.argv):
            yield segment


PLAN_ROOT_MARKERS = ("tmp/plan-files/", "tmp/plan-with-files/")


def _plan_file_arguments(words: list[str]):
    """Yield the arguments that name a plan Markdown file.

    Tests each argument itself rather than scanning it for a path pattern: a
    lexed argument is already exact, while the prose scanner stops at the first
    space and would report a fragment of a path whose directory contains one.
    """
    for word in words:
        normalized = word.replace("\\", "/")
        if not normalized.endswith(".md"):
            continue
        if any(marker in normalized or normalized.startswith(marker) for marker in PLAN_ROOT_MARKERS):
            yield word


def _substitutions_are_read_only(segment: Segment) -> bool:
    """A repair may compute an argument; the command it runs to do so may not write.

    `--expected-fingerprint "$(sha256sum tasks.md | cut -d' ' -f1)"` is the
    documented way to produce that value, so substitution cannot simply be
    banned inside a repair. It does run a second command, which therefore faces
    the same read-only test as any other segment.
    """
    for command in segment.substitutions:
        inner = shell_segments(command)
        if not inner or not all(_segment_is_read_only(part) for part in inner):
            return False
    return True


def shell_runs_planning_helper(tool_input: object, plan_dir: Path | None = None) -> bool:
    """True when the whole command is owned-plan maintenance and nothing else.

    Every segment must run a planning helper or be demonstrably read-only. One
    qualifying segment used to be enough, which let any command launder itself
    through the allowance: `rm -rf src && plan_edit.py phase-add` passed a
    closed gate, and the rm ran. Chaining unrelated work onto a repair is not a
    capability the gate owes anyone -- send that work as its own call once the
    gate reopens.

    With a plan_dir, every plan path a helper names must also lie inside it: the
    allowance exists for maintaining the owned plan, so a helper aimed at a
    different task is not maintenance. A helper that names no plan path is still
    allowed; it resolves the owned plan from the pointer itself.
    """
    segments = shell_segments(shell_command_text(tool_input))
    if not segments:
        return False
    maintains = False
    for segment in segments:
        if _segment_runs_planning_helper(segment.argv):
            if plan_dir is not None and any(
                not inside(word, plan_dir) for word in _plan_file_arguments(segment.argv)
            ):
                return False
            if not _substitutions_are_read_only(segment):
                return False
            maintains = True
        elif not _segment_is_read_only(segment):
            return False
    return maintains


ROUTING_VERBS = {"bind", "release", "clarify", "discuss"}
# PWF_SESSION_ID would rewrite another session's lease and a foreign
# PWF_PROJECT_ROOT would route a different project, so the routing command
# carries at most the one assignment the gate's own message prescribes.
ROUTING_ENV_NAMES = {"PWF_PROJECT_ROOT"}
DETACH_COMMANDS = {"nohup", "setsid"}


def _routing_words(segment: Segment) -> list[str] | None:
    """Lex one segment with output-discarding redirections removed.

    `bind task-a 2>&1 | tail -3` runs the same routing action as the bare
    command: the redirection writes nothing, so it must not defeat recognition.
    A surviving > or < can write a real file, and a substitution can hide any
    command at all, so both refuse the segment instead.
    """
    if segment.substitutions:
        return None
    probe = segment.text
    for token in DISCARD_REDIRECTS:
        probe = probe.replace(token, " ")
    if ">" in probe or "<" in probe:
        return None
    try:
        return shlex.split(probe)
    except ValueError:
        return None


def _segment_routing_verb(segment: Segment, bind_tool: Path, project_root: Path,
                          task_id: str) -> str | None:
    """The routing verb this segment runs, or None for anything else.

    Recognized from the program the segment actually runs -- the bind adapter
    resolved through symlinks, so the same script reached through
    ~/.claude/hooks counts -- followed by exactly the verb and task id the
    gate's message prescribes. Naming the adapter inside some other command,
    detaching it, or aiming it at another task authorizes nothing.
    """
    words = _routing_words(segment)
    if not words or segment.terminator == "&":
        return None
    if any(Path(word).name in DETACH_COMMANDS for word in words):
        return None
    index = 0
    while index < len(words):
        word = words[index]
        if Path(word).name == "env":
            index += 1
            continue
        if "=" not in word or word.startswith("="):
            break
        name, _, value = word.partition("=")
        if name not in ROUTING_ENV_NAMES or os.path.realpath(value) != str(project_root):
            return None
        index += 1
    else:
        return None
    operands = words[index + 1:]
    if any(word.startswith("-") for word in operands):
        return None
    executable = Path(words[index]).name
    if executable in {"bash", "sh"}:
        if not operands:
            return None
        script, operands = operands[0], operands[1:]
    elif executable == bind_tool.name:
        script = words[index]
    else:
        return None
    if os.path.realpath(script) != str(bind_tool):
        return None
    if len(operands) != 2 or operands[0] not in ROUTING_VERBS or operands[1] != task_id:
        return None
    return operands[0]


def routing_verb(tool_input: object, bind_tool: Path, project_root: Path, task_id: str) -> str:
    """The routing verb a whole command runs, or "" when it runs anything else.

    Read-only decoration around the routing command has to pass. The gate
    prescribes one command, and an agent that pipes it to `tail -3` or appends
    `; echo "pointer=$(cat .plan-files)"` to read the result is running that
    same command -- byte-exact comparison refused every such variant and
    re-emitted the identical instruction, a loop with no exit the agent could
    find. Chaining anything that is not read-only still refuses the whole
    command, so `rm -rf src && bind task-a` cannot launder itself through this
    allowance, and two routing segments are ambiguous rather than permitted.
    """
    if not TASK_ID_RE.match(task_id or ""):
        return ""
    segments = shell_segments(shell_command_text(tool_input))
    if not segments:
        return ""
    verb = ""
    for segment in segments:
        found = _segment_routing_verb(segment, bind_tool, project_root, task_id)
        if found:
            if verb:
                return ""
            verb = found
        elif not _segment_is_read_only(segment, allow_substitutions=True):
            return ""
    return verb


def planning_background_warning(payload: dict) -> str:
    """Recognize explicit detachment of short planning helpers, not arbitrary jobs."""
    name = str(payload.get("tool_name") or payload.get("toolName") or "")
    if name.lower().rsplit("__", 1)[-1].rsplit(".", 1)[-1] not in SHELL_TOOL_NAMES:
        return ""
    args = payload_tool_input(payload)
    command = shell_command_text(args)
    if not command:
        return ""
    explicit = isinstance(args, dict) and any(
        args.get(key) is True for key in ("background", "is_background", "run_in_background")
    )
    for segment in planning_helper_segments(command):
        # Only an unquoted trailing ampersand is detachment; `&&` chains a
        # second foreground command and must not read as one.
        detached = segment.terminator == "&" or any(
            word in {"nohup", "setsid"} for word in segment.argv
        )
        if explicit or detached:
            return ("[plan-files] FOREGROUND PLANNING COMMAND REQUIRED. Run planning helpers and their "
                    "path discovery with background/is_background/run_in_background=false and without "
                    "shell detachment. Resolve scripts relative to the loaded SKILL.md; avoid home-wide find. "
                    "If the harness already returned a task id, wait/get its output in this turn before "
                    "dependent work; do not launch a duplicate or end the turn just to poll.")
    return ""


def is_read_only_call(payload: dict) -> bool:
    """Same read-only recognition the maintenance gate applies, reusable alone."""
    name = str(payload.get("tool_name") or payload.get("toolName") or "").lower()
    simple = name.rsplit("__", 1)[-1]
    tool_input = payload_tool_input(payload)
    if simple.rsplit(".", 1)[-1] in QUESTION_TOOLS or names_read_tool(simple):
        return True
    return simple in SHELL_TOOL_NAMES and bash_is_read_only(tool_input)


def names_skill_document(payload: dict, skill_md: str) -> bool:
    """Recognize a read-only read of the skill entrypoint, from tool input.

    Any tool that names the resolved SKILL.md path counts, so a harness with an
    unfamiliar reader schema can still satisfy the gate in one call. Requiring
    read-only means naming the path cannot smuggle an unrelated mutation past a
    gate that this same signal is allowed to open.
    """
    target = skill_md.replace("\\", "/")
    if not target:
        return False
    if not any(target in value.replace("\\", "/")
               for value in strings(payload_tool_input(payload))):
        return False
    return is_read_only_call(payload)


def outside_every_plan(tool_input: object, project_root: Path) -> bool:
    """True when every recognized write target lies outside the plan root.

    A discussion lease protects the plan, not the filesystem, so a report the
    user asked for may be written. Unrecognizable targets return False: a shell
    command's writes cannot be located, so it cannot be cleared this way.
    """
    targets = mutation_targets(tool_input)
    if not targets:
        return False
    roots = [Path(os.path.realpath(project_root / "tmp" / name))
             for name in ("plan-files", "plan-with-files")]
    return not any(inside(path, root) for path in targets for root in roots)


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "outside-every-plan":
        payload = load_payload()
        if payload is None:
            return 1
        return 0 if outside_every_plan(payload_tool_input(payload),
                                       Path(os.path.realpath(sys.argv[2]))) else 1
    if len(sys.argv) == 3 and sys.argv[1] == "names-skill-doc":
        payload = load_payload()
        print("1" if payload is not None and names_skill_document(payload, sys.argv[2]) else "", end="")
        return 0
    if len(sys.argv) == 2 and sys.argv[1] == "planning-background-warning":
        payload = load_payload()
        if payload is not None:
            print(planning_background_warning(payload), end="")
        return 0
    if len(sys.argv) == 2 and sys.argv[1] == "question-tool":
        payload = load_payload()
        if payload is None:
            return 1
        name = str(payload.get("tool_name") or payload.get("toolName") or "").lower()
        return 0 if name.rsplit("__", 1)[-1].rsplit(".", 1)[-1] in QUESTION_TOOLS else 1
    if len(sys.argv) == 3 and sys.argv[1] == "tool-class":
        payload = load_payload()
        if payload is None:
            return 1
        plan_dir = Path(os.path.realpath(sys.argv[2]))
        print(json.dumps(tool_class(payload, plan_dir), separators=(",", ":")))
        return 0
    if len(sys.argv) == 5 and sys.argv[1] == "routing-verb":
        payload = load_payload()
        if payload is None:
            return 1
        verb = routing_verb(payload_tool_input(payload),
                            Path(os.path.realpath(sys.argv[2])),
                            Path(os.path.realpath(sys.argv[3])), sys.argv[4])
        print(verb, end="")
        return 0 if verb else 1
    if len(sys.argv) == 3 and sys.argv[1] in {"prompt-plan-id", "mutation-plan-id"}:
        payload = load_payload()
        if payload is None:
            return 1
        project_root = Path(os.path.realpath(sys.argv[2]))
        if sys.argv[1] == "prompt-plan-id":
            return extract_prompt_plan_id(payload, project_root)
        return extract_mutation_plan_id(payload, project_root)

    if len(sys.argv) != 2:
        return 1
    plan_dir = Path(os.path.realpath(sys.argv[1]))
    payload = load_payload()
    if payload is None:
        return 1
    tool_name = str(payload.get("tool_name") or payload.get("toolName") or "").lower()
    simple_name = tool_name.rsplit("__", 1)[-1]
    tool_input = payload_tool_input(payload)

    if simple_name.rsplit(".", 1)[-1] in QUESTION_TOOLS or names_read_tool(simple_name):
        return 0
    if simple_name in SHELL_TOOL_NAMES:
        if bash_is_read_only(tool_input):
            return 0

    targets = mutation_targets(tool_input)
    if targets:
        return 0 if all(inside(path, plan_dir) for path in targets) else 1
    # A shell command's write targets are not parseable, so a plan path appearing
    # somewhere in it proves nothing about what it writes. Authorize it only when
    # it actually runs a planning helper; otherwise `<mutation>; cat <plan>/x.md`
    # would launder any mutation through the owned-plan allowance.
    if simple_name in SHELL_TOOL_NAMES:
        return 0 if shell_runs_planning_helper(tool_input, plan_dir) else 1
    if references_owned_plan(tool_input, plan_dir):
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
