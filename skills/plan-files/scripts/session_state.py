#!/usr/bin/env python3
"""Provider-neutral session routing and exclusive plan ownership.

The per-session .state files are authoritative. The workspace marker never
selects a task. Routing changes take an exclusive lock; plan transactions take
its shared side before the per-plan lock, so a handoff cannot overtake a write.
"""
from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar
import fcntl
from functools import wraps
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

from feedback_transport import feedback_path, valid_file
from plan_paths import PLAN_FILENAMES, conflicting_plan_files, resolve_plan_file

SCRIPTS = Path(__file__).resolve().parent
STATUSES = {"pending", "owned", "creating", "waiting", "discussing", "idle", "inactive", "disabled"}
TASK_RE = re.compile(r"[A-Za-z0-9._-]+\Z")
PROVIDER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
SESSION_RE = re.compile(r"[A-Za-z0-9._:-]{1,240}\Z")


class SessionError(ValueError):
    pass


def valid_task(task: str) -> bool:
    return bool(TASK_RE.fullmatch(task)) and task not in {".", ".."}


def project_root(start: Path | None = None) -> Path:
    origin = start or Path(os.environ.get("PWF_PROJECT_ROOT", os.getcwd()))
    result = subprocess.run(["bash", str(SCRIPTS / "resolve-project-root.sh"), str(origin)],
                            text=True, capture_output=True, check=True)
    return Path(result.stdout.strip() or origin).resolve()


def planning_root(root: Path) -> Path:
    return root / "tmp/plan-files"


def identity() -> tuple[str, str] | None:
    provider, session = os.environ.get("PWF_SESSION_ADAPTER"), os.environ.get("PWF_SESSION_ID")
    if provider or session:
        if not (provider and session):
            raise SessionError("incomplete planning session identity")
        candidates = [(provider, session)]
    else:
        candidates = [(name, os.environ[key]) for name, key in (
            ("codex", "CODEX_THREAD_ID"), ("claude", "CLAUDE_SESSION_ID"),
            ("copilot", "COPILOT_AGENT_SESSION_ID"), ("grok", "GROK_SESSION_ID")) if os.environ.get(key)]
    if not candidates:
        return None
    if len(candidates) != 1:
        raise SessionError("ambiguous host identity; use the provider's session adapter")
    provider, session = candidates[0]
    if not PROVIDER_RE.fullmatch(provider) or not SESSION_RE.fullmatch(session):
        raise SessionError("invalid planning session identity")
    return provider, session


def atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class SessionStore:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.plans = planning_root(self.root)
        self.sessions = self.plans / ".sessions"

    def accepts_state(self) -> bool:
        return any(p.exists() for p in (self.root / ".plan-files", self.root / ".git", self.plans))

    def enabled(self) -> None:
        if os.environ.get("PLANNING_DISABLED") == "1" or (self.root / ".plan-files-skip").exists():
            raise SessionError("plan-files is disabled for this project or session")

    def route(self, provider: str, session: str) -> Path:
        if not PROVIDER_RE.fullmatch(provider) or not SESSION_RE.fullmatch(session):
            raise SessionError("invalid planning session identity")
        key = hashlib.sha256(f"{provider}:{session}".encode()).hexdigest()
        return self.sessions / provider / f"{key}.state"

    def task_path(self, task: str, *, exists: bool = True) -> Path:
        if not valid_task(task):
            raise SessionError("invalid planning task id")
        path = self.plans / task
        if path.resolve().parent != self.plans.resolve():
            raise SessionError("planning task resolves outside this project's plan root")
        if exists and not resolve_plan_file(path).is_file():
            raise SessionError(f"invalid or missing planning task: {task}")
        return path

    def read(self, file: Path) -> dict[str, str]:
        try:
            text = file.read_text()
        except FileNotFoundError:
            return {}
        row = {}
        for line in text.splitlines():
            key, separator, value = line.partition("=")
            if not separator or key in row:
                raise SessionError("invalid session state; diagnose the session before writing")
            row[key] = value
        if row.get("status") not in STATUSES or row.get("schema", "1") not in {"1", "2", "3"}:
            raise SessionError("invalid or unsupported session state")
        if row.get("generation") and not re.fullmatch(r"[0-9a-f]{32}", row["generation"]):
            raise SessionError("invalid session generation")
        for key in ("task", "candidate", "last_task", "associated"):
            if row.get(key) and not valid_task(row[key]):
                raise SessionError("invalid task in session state")
        if row["status"] in {"owned", "creating"} and not row.get("task"):
            raise SessionError("session state is missing its owned task")
        if row["status"] in {"discussing", "idle"} and not (row.get("task") or row.get("associated")):
            raise SessionError("session state is missing its associated task")
        return row

    @contextmanager
    def lock(self, *, shared: bool = False, preview: bool = False):
        path = self.sessions / ".routing.lock"
        if preview and not path.exists():
            yield
            return
        if not preview:
            if not self.accepts_state():
                raise SessionError("root has no planning workspace marker")
            self.sessions.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(path, os.O_RDONLY if preview else os.O_CREAT | os.O_RDWR, 0o600)
        with os.fdopen(fd, "r" if preview else "r+") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_SH if shared or preview else fcntl.LOCK_EX)
            yield

    def excludes(self) -> None:
        if not (self.root / ".git").is_dir():
            return
        try:
            path = self.root / ".git/info/exclude"
            path.parent.mkdir(exist_ok=True)
            existing = path.read_text() if path.exists() else ""
            missing = [v for v in ("tmp/*", ".plan-files") if v not in existing.splitlines()]
            if missing:
                with path.open("a") as output:
                    output.write(("\n" if existing and not existing.endswith("\n") else "")
                                 + "\n".join(missing) + "\n")
        except OSError:
            pass

    def write(self, file: Path, status: str, **fields: str) -> None:
        self.excludes()
        row = {"schema": "3", "status": status, "generation": uuid.uuid4().hex,
               "updated": str(time.time()),
               **{key: value for key, value in fields.items() if value}}
        atomic_text(file, "".join(f"{key}={value}\n" for key, value in row.items()))
        feedback = feedback_path(str(file))
        if valid_file(feedback):
            feedback.unlink(missing_ok=True)
        file.with_suffix(".routing-required").unlink(missing_ok=True)
        for suffix in (".hook-state", ".hook-state.stop"):
            file.with_suffix(suffix).unlink(missing_ok=True)
        for cache in file.parent.glob(file.stem + ".*.hook-state*"):
            if not cache.name.endswith(".lock"):
                cache.unlink(missing_ok=True)
        # Preserve existing legacy content; this file is only a root marker.
        marker = self.root / ".plan-files"
        if not marker.exists():
            marker.touch()

    def owners(self, task: str) -> list[Path]:
        return [file for file in self.sessions.glob("*/*.state")
                if self.read(file).get("task") == task]

    def tools(self, file: Path) -> dict:
        path = file.with_suffix(".tools")
        try:
            value = json.loads(path.read_text()) if path.exists() else {}
        except (OSError, ValueError) as error:
            raise SessionError("invalid tool receipts; diagnose outstanding writers before recovery") from error
        if not isinstance(value, dict) or any(not isinstance(item, (str, list)) for item in value.values()):
            raise SessionError("invalid tool receipts; diagnose outstanding writers before recovery")
        return value

    def busy(self, file: Path) -> bool:
        return bool(self.tools(file))

    def snapshot(self, task: str) -> str:
        directory = self.task_path(task)
        digest = hashlib.sha256()
        for path in (resolve_plan_file(directory), directory / "decisions.md", directory / "findings.md"):
            digest.update(path.name.encode())
            digest.update(path.read_bytes() if path.is_file() else b"<missing>")
        return digest.hexdigest()

    def remember_read(self, file: Path, task: str) -> None:
        """Caller holds routing lock; updating a read receipt never changes authority."""
        row = self.read(file)
        if task not in {row.get("task"), row.get("associated")}:
            return
        row["seen"] = self.snapshot(task)
        atomic_text(file, "".join(f"{key}={value}\n" for key, value in row.items()))

    def require_fresh(self, row: dict, task: str) -> None:
        if row.get("seen") and row["seen"] != self.snapshot(task):
            plan = resolve_plan_file(self.task_path(task))
            raise SessionError(f"plan changed since your last read; run python3 {SCRIPTS / 'plan_state.py'} overview {plan} before writing")

    def current_view(self, task: str) -> str:
        # Acquiring authority always returns the bounded state it authorizes.
        # Invalid plans still need to be readable and repairable.
        from plan_state import overview_payload
        return json.dumps(overview_payload(resolve_plan_file(self.task_path(task)), 800, 4096), separators=(",", ":"))

    def recover_dead(self, task: str) -> None:
        """Only a verified dead local runtime with no unfinished tools is reclaimable."""
        from session_runtime import runtime_dead
        for other in self.owners(task):
            row = self.read(other)
            if runtime_dead(row) and not self.busy(other):
                self.write(other, "idle", associated=task, last_task=task)

    def event(self, provider: str, session: str, event: str, *, record: bool) -> bool:
        """Bounded receipts fence identifiable late PostTool events by generation."""
        if not event:
            return True  # Older hosts have no correlation id; creation still needs a reservation.
        file = self.route(provider, session)
        path = file.with_suffix(".events")
        key = hashlib.sha256(event.encode()).hexdigest()
        with self.lock(shared=not record):
            generation = self.read(file).get("generation", "legacy")
            receipts = json.loads(path.read_text()) if path.exists() else {}
            if record:
                receipts.pop(key, None)
                receipts[key] = generation
                atomic_text(path, json.dumps(dict(list(receipts.items())[-128:])))
                return True
            return receipts.get(key) == generation

    def holders(self, file: Path | None, task: str) -> list[Path]:
        return [other for other in self.owners(task) if other != file]

    def holder_summary(self, holders: list[Path]) -> str:
        """Count and newest activity only; holder identities stay private."""
        stamps = [max(path.stat().st_mtime for path in other.parent.glob(other.stem + ".*"))
                  for other in holders]
        hours = (time.time() - max(stamps)) / 3600
        return f"{len(holders)} other session(s), most recent activity {hours:.1f}h ago"

    def exclusive(self, file: Path, task: str) -> None:
        holders = self.holders(file, task)
        if holders:
            raise SessionError(
                f"task '{task}' is reserved by {self.holder_summary(holders)}; its owner must handoff first. "
                "Do not retry bind. If those sessions may be closed, ask the user; only with their "
                f"authorization run the bind adapter with: reclaim {task} --reason \"user confirmed the other sessions are closed\"")

    def pending(self, provider: str, session: str, preferred: str = "", turn: str = "") -> str:
        file = self.route(provider, session)
        with self.lock():
            row = self.read(file)
            candidate = row.get("task") or row.get("candidate") or row.get("associated", "")
            if not candidate and preferred:
                self.task_path(preferred)
                candidate = preferred
            # Even an empty pending row identifies a prompt without opting in.
            self.write(file, "pending", task=row.get("task", ""), candidate=candidate,
                       associated=candidate, turn=turn or row.get("turn", ""),
                       **{key: row[key] for key in ("runtime", "seen") if key in row})
            return candidate

    def claim(self, provider: str, session: str, task: str, *, preview: bool = False,
              creating: bool = False, finalize: bool = False, event: str = "") -> str:
        self.enabled()
        directory = self.task_path(task, exists=not creating)
        event = hashlib.sha256(event.encode()).hexdigest() if event else ""
        file = self.route(provider, session)
        with self.lock(preview=preview):
            row = self.read(file)
            if finalize:
                if row.get("status") != "creating" or row.get("task") != task:
                    raise SessionError("no matching creation reservation; delayed PostTool cannot claim a plan")
                if row.get("event") and row["event"] != event:
                    raise SessionError("creation event does not match this reservation")
            else:
                if row.get("status") in {"discussing", "waiting", "disabled", "idle", "inactive"}:
                    raise SessionError("planning lease is not claimable; resolve the current prompt first")
                current = row.get("task") or row.get("candidate")
                if current and current != task:
                    raise SessionError(f"planning lease conflicts with task: {current}")
                if row.get("status") == "pending" and row.get("task"):
                    raise SessionError("owned task requires explicit bind on the new prompt")
            if not preview:
                self.recover_dead(task)
            self.exclusive(file, task)
            if not preview and not (row.get("status") == "owned" and row.get("task") == task):
                from session_runtime import runtime_identity
                self.write(file, "creating" if creating else "owned", task=task, associated=task,
                           event=event, runtime=runtime_identity(), turn=row.get("turn", ""))
            return str(directory)

    def resolve(self, provider: str, session: str) -> str:
        file = self.route(provider, session)
        row = self.read(file)
        if row.get("status") not in {"owned", "discussing"}:
            return ""
        task = row.get("task") or row.get("associated")
        if not task:
            return ""
        if row.get("task"):
            self.exclusive(file, task)
        return str(self.task_path(task))

    def bind(self, provider: str, session: str, task: str, reason: str = "") -> str:
        self.enabled()
        self.task_path(task)
        file = self.route(provider, session)
        with self.lock():
            row = self.read(file)
            current = row.get("task") or row.get("candidate") or row.get("associated")
            if current and current != task:
                raise SessionError("this session must release/handoff its existing task before binding another")
            if row.get("status") == "discussing" and not reason.strip():
                raise SessionError('planning lease is still "discussing": bind the same task with --reason "user authorization"')
            if row.get("status") in {"owned", "creating"}:
                raise SessionError("planning lease is already owned; use resolve instead of binding again")
            if self.busy(file):
                from tool_recovery import recovery_guidance
                guidance = ("; if Claude already delivered automatic completion, let Stop reconcile its native "
                            "background registry, then follow the new routing guidance" if provider == "claude" else "")
                raise SessionError("collect unfinished tools before binding a new execution generation" + guidance
                                   + recovery_guidance(self, provider, task))
            self.recover_dead(task)
            self.exclusive(file, task)
            from session_runtime import runtime_identity
            view = self.current_view(task)
            self.write(file, "owned", task=task, associated=task, seen=self.snapshot(task),
                       runtime=runtime_identity(), turn=row.get("turn", ""))
        return f"planning task bound for this prompt: {task}\nCurrent plan (read before acting):\n{view}"

    def reclaim(self, provider: str, session: str, task: str, reason: str) -> str:
        """User-authorized recovery of a task whose other owners are no longer running."""
        self.enabled()
        self.task_path(task)
        if not reason.strip():
            raise SessionError('reclaim requires --reason "<user authorization>"')
        file = self.route(provider, session)
        with self.lock():
            row = self.read(file)
            current = row.get("task") or row.get("candidate") or row.get("associated")
            if current and current != task:
                raise SessionError("this session must release/handoff its existing task before reclaiming another")
            holders = self.holders(file, task)
            for other in holders:
                # Explicit recovery confirms the previous writers have stopped;
                # retire orphaned receipts as well as authority, fence late posts.
                atomic_text(other.with_suffix(".tools"), "{}")
                self.write(other, "inactive", last_task=task, associated=task)
            atomic_text(file.with_suffix(".tools"), "{}")
            from session_runtime import runtime_identity
            self.write(file, "owned", task=task, associated=task, seen=self.snapshot(task),
                       runtime=runtime_identity(), turn=row.get("turn", ""))
            view = self.current_view(task)
        return f"planning task reclaimed for this prompt: {task}; {len(holders)} other lease(s) made inactive\nCurrent plan:\n{view}"

    def transition(self, provider: str, session: str, verb: str, task: str,
                   generation: str | None = None) -> str:
        file = self.route(provider, session)
        if not valid_task(task):
            raise SessionError("invalid planning task id")
        with self.lock():
            row = self.read(file)
            current = row.get("task") or row.get("candidate") or row.get("associated")
            if generation is not None and row.get("generation", "legacy") != generation:
                return ""
            if verb == "finish" and (row.get("status") != "owned" or row.get("task") != task):
                return ""
            if verb == "finish":
                if generation is not None and row.get("generation", "legacy") != generation:
                    return ""
                # The exclusive routing lock waits for every helper transaction.
                # Revalidate here so a reopen cannot race the earlier Stop read.
                from plan_state import parse_plan, finalizability_issues
                state = parse_plan(resolve_plan_file(self.task_path(task)))
                if not state.phases or any(phase.status != "complete" for phase in state.phases):
                    raise SessionError("plan changed before finalization; restore its current state")
                if finalizability_issues(state):
                    raise SessionError("plan is not finalizable; repair its current state")
            if current != task:
                raise SessionError(f"session is not associated with task: {task}")
            if verb in {"release", "clarify"} and row.get("status") not in {"pending", "waiting"}:
                raise SessionError("planning lease is not pending; use handoff to relinquish owned work")
            if verb == "discuss":
                if self.busy(file):
                    raise SessionError("unfinished tools must complete before entering discussion")
                view = self.current_view(task)
                self.write(file, "discussing", associated=task, seen=self.snapshot(task), turn=row.get("turn", ""))
                return f"planning discussion only: {task}; execution needs a new prompt bind or bind --reason\nCurrent plan:\n{view}"
            if verb == "clarify":
                self.write(file, "waiting", task=row.get("task", ""), candidate=task,
                           associated=task, turn=row.get("turn", ""))
                return f"planning candidate preserved: {task}; ask the user now, then wait for their answer."
            if verb == "handoff" and row.get("task") != task:
                raise SessionError("only the owning session can handoff a task")
            if self.busy(file):
                from tool_recovery import recovery_guidance
                raise SessionError("unfinished tools must complete before relinquishing this task"
                                   + recovery_guidance(self, provider, task))
            self.write(file, "inactive", last_task=task,
                       associated=task if verb == "handoff" else "")
            # Never unlink lock files; another process may still hold that inode.
            return f"planning session {verb}: {task}; other sessions and workspace marker unchanged"

    def yield_turn(self, provider: str, session: str, generation: str, *, ending: bool = False,
                   turn: str = "", observed: float | None = None) -> None:
        """Release only the inspected generation; never edit plan progress."""
        file = self.route(provider, session)
        if not file.exists():
            return
        with self.lock():
            row = self.read(file)
            if not row or row.get("generation", "legacy") != generation:
                return
            if row.get("status") == "idle":
                return
            if turn and row.get("turn") and row["turn"] != turn:
                return
            if observed is not None and observed < float(row.get("updated", "0")):
                return  # A delayed event created before the current generation.
            if self.busy(file):
                from tool_recovery import recovery_guidance
                raise SessionError("unfinished tools still hold execution authority; collect their results before stopping"
                                   + recovery_guidance(self, provider, row.get("task", "")))
            task = row.get("task") or row.get("candidate") or row.get("associated")
            if not task:
                return
            if not ending and row.get("status") in {"owned", "creating"}:
                from plan_state import parse_plan
                state = parse_plan(resolve_plan_file(self.task_path(task)))
                unstarted = not state.current_phase and all(p.status == "pending" for p in state.phases)
                if state.issues or (not unstarted and any(p.status not in {"complete", "blocked", "deferred"} for p in state.phases)):
                    raise SessionError("plan changed before yielding; restore and continue its actionable work")
            self.write(file, "idle", associated=task, last_task=task)


_transactions: ContextVar[frozenset[Path]] = ContextVar("plan_transactions", default=frozenset())

RECORD_FILES = {"decisions.md", "findings.md", "history.md"}
EDIT_RECORD_OPS = {"decision-supersede", "decisions-compact", "decisions-consolidate", "archive-phase", "compact-oldest", "archive-entry"}
EDIT_FILE_OPS = {"entry-append", "entry-replace", "entry-remove", "section-replace"}
EDIT_ADVANCE_OPS = {"phase-add", "phase-update", "phase-move", "phase-remove",
                    "item-add", "item-update", "item-move", "item-remove",
                    "reopen", "resume", "pause", "handoff-write", "handoff-clear"}


def edit_operation_class(command: str, file: str = "", dry_run: bool = False) -> str:
    if dry_run:
        return "read"
    if command in EDIT_RECORD_OPS or (command in EDIT_FILE_OPS and file in RECORD_FILES):
        return "record"
    return "advance"


def authorize_edit(plan: Path, command: str, file: str = "", dry_run: bool = False) -> None:
    who = identity()
    if who and edit_operation_class(command, file, dry_run) == "advance":
        store = store_for_plan(plan)
        if store.read(store.route(*who)).get("status") == "discussing":
            raise SessionError("discussion does not authorize execution edits; bind with --reason")


def store_for_plan(plan: Path) -> SessionStore:
    """Use a declared workspace only when this plan actually belongs to it."""
    hint = os.environ.get("PWF_PROJECT_ROOT")
    if hint:
        store = SessionStore(project_root(Path(hint)))
        if plan.name in PLAN_FILENAMES and (store.plans / plan.parent.name / plan.name).resolve() == plan.resolve():
            return store
    return SessionStore(project_root(plan.parent))


@contextmanager
def plan_transaction(plan: Path):
    """Lock and authorize a complete read/modify/write, including direct callers."""
    plan = plan.resolve()
    held = _transactions.get()
    if plan in held:
        yield
        return
    store = store_for_plan(plan)
    who = identity()
    file = store.route(*who) if who else None
    before = store.read(file) if file else {}
    with store.lock(shared=True):
        plan.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(plan.parent / ".plan-edit.lock", os.O_CREAT | os.O_RDWR, 0o600)
        with os.fdopen(fd, "r+") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            if conflicting_plan_files(plan):
                raise SessionError("PLAN_FILENAME_CONFLICT: preserve and reconcile plan.md and tasks.md before writing")
            row = store.read(file) if file else {}
            if {k: v for k, v in before.items() if k != "seen"} != {k: v for k, v in row.items() if k != "seen"}:
                raise SessionError("session ownership changed while waiting; re-read the current prompt and plan")
            owners = store.owners(plan.parent.name)
            if owners and (file is None or owners != [file]):
                raise SessionError("plan is reserved by another session; explicit --plan does not grant ownership")
            if row.get("task") and (row.get("task") != plan.parent.name
                                    or row.get("status") not in {"owned", "discussing"}):
                raise SessionError("bind the current prompt before modifying its plan")
            if row.get("candidate") and not row.get("task"):
                raise SessionError("resolve the pending candidate before modifying a plan")
            if row.get("status") in {"inactive", "disabled"}:
                raise SessionError("this session relinquished its plan; explicitly bind before writing again")
            if row.get("status") == "idle":
                raise SessionError("execution authority was yielded; explicitly bind and read the current plan before writing")
            if row.get("associated") and row["associated"] != plan.parent.name:
                raise SessionError("this plan is outside the current discussion or execution scope")
            store.require_fresh(row, plan.parent.name)
            token = _transactions.set(held | {plan})
            try:
                yield
                if file:
                    store.remember_read(file, plan.parent.name)
            finally:
                _transactions.reset(token)


def guarded(operation):
    @wraps(operation)
    def wrapped(plan, *args, **kwargs):
        with plan_transaction(Path(plan)):
            who = identity()
            if who:
                store = store_for_plan(Path(plan))
                if store.read(store.route(*who)).get("status") == "discussing":
                    raise SessionError("discussion does not authorize execution checkpoints; bind with --reason")
            return operation(plan, *args, **kwargs)
    return wrapped


def active_plan(root: Path | None = None) -> Path:
    who = identity()
    if who is None:
        raise SessionError("no planning session identity; pass an explicit --plan for an unowned offline plan")
    directory = SessionStore(root or project_root()).resolve(*who)
    if not directory:
        raise SessionError("this session owns no plan for this prompt; bind its task or pass an explicit --plan")
    return resolve_plan_file(Path(directory))


def candidate_context(store: SessionStore, task: str, adapter: str, compact: bool) -> str:
    plan = resolve_plan_file(store.task_path(task))
    content = re.sub(r"<!--.*?-->", "", plan.read_text(), flags=re.S)
    def section(name):
        found = re.search(r"^## " + re.escape(name) + r"\s*\n(.*?)(?=^## |\Z)", content, re.M | re.S)
        return found.group(1).strip()[:700] if found else ""
    goal, task_identity = section("Goal"), section("Task Identity")
    # Match the stable shell cores' printf %q commands exactly, including roots
    # with spaces/quotes. Arguments travel as argv, never interpolated code.
    quoted = subprocess.run(["bash", "-c", 'printf "%q\\0" "$@"', "quote",
                             str(store.root), adapter, str(SCRIPTS.parent / "SKILL.md"),
                             str(SCRIPTS / "plan_state.py"), str(plan)],
                            text=True, capture_output=True, check=True).stdout.split("\0")
    root_arg, adapter_arg, skill, state, target = quoted[:5]
    command = f"PWF_PROJECT_ROOT={root_arg} bash {adapter_arg}"
    # Bind cannot succeed while another lease holds the task; say so up front
    # instead of offering a bind the agent would retry forever.
    who = identity()
    from session_runtime import runtime_dead
    holders = [holder for holder in store.holders(store.route(*who), task)
               if not (runtime_dead(store.read(holder)) and not store.busy(holder))] if who else []
    reserved = (f"RESERVED: task '{task}' is held by {store.holder_summary(holders)}, so bind will fail; do not retry it. "
                f"For SAME, run `{command} clarify {task}` and ask the user whether those sessions are closed. Only with their authorization run "
                f"`{command} reclaim {task} --reason \"user confirmed the other sessions are closed\"`, which makes the other leases inactive and binds this session.\n"
                if holders else "")
    if compact:
        return (f"[plan-files] Candidate task '{task}'; text-only chat may yield without routing. Before tools, read {skill} and classify the request.\n{reserved}"
                f"Run {command} <verb> {task}: SAME=bind, DIFFERENT=release, AMBIGUOUS=clarify, DISCUSSION ONLY=discuss. Never release continuing work.\nGoal: {goal[:180]}")
    return ("[plan-files] OWNERSHIP ACTION REQUIRED for this prompt. Continue/implement this plan = SAME, even after research. Resolve ownership before other tools; this is not an external blocker.\n"
            f"{reserved}"
            f"- SAME: run `{command} bind {task}`.\n"
            f"- DIFFERENT: first run `{command} release {task}` only for a separate goal. This releases only your session.\n"
            f"- AMBIGUOUS: run `{command} clarify {task}`, then ask and wait. This keeps the candidate and blocks work; do not release it.\n"
            f"- DISCUSSION ONLY (a question about this plan, this workflow, or your own behavior, with no implementation): run `{command} discuss {task}`. This answers and stops cleanly while keeping execution gated.\n"
            f"Read {skill} once in this session before operational work — required even if its rules are already in your context, because the gate observes tool calls. Reading it is allowed before bind.\n"
            f"After bind: run `python3 {state} overview {target}`, then only needed targeted reads. If restore.ok is false, use `python3 {state} restore-check {target}`. Reconcile user-authorized scope changes before implementation. After release: continue separately. Never release merely to bypass a gate.\n\n"
            f"Candidate task '{task}' is not owned for this prompt. A previous prompt's bind does not carry forward. Non-goals still apply unless the user supersedes them.\n\n"
            f"## Task Identity\n{task_identity}\n\n## Goal\n{goal}")


def main(argv=None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        raise SessionError("usage: session-state.sh <operation> [arguments]")
    op, *args = args
    if op in {"session-id", "event-id"}:
        value = json.load(sys.stdin)
        keys = ("session_id", "sessionId") if op == "session-id" else ("tool_use_id", "toolUseId", "tool_call_id", "toolCallId")
        value = next((value[k] for k in keys if isinstance(value, dict) and value.get(k)), "")
        if not isinstance(value, str) or (op == "session-id" and not SESSION_RE.fullmatch(value)):
            return 1
        print(value, end="")
        return 0
    store = SessionStore(project_root())
    output = ""
    if op == "candidate-context":
        output = candidate_context(store, args[0], args[1], "--compact" in args)
    elif op in {"tools", "ack-rejected"}:
        import argparse
        from tool_recovery import recover
        parser = argparse.ArgumentParser(prog=op)
        parser.add_argument("task")
        parser.add_argument("--command", required=True)
        if op == "ack-rejected":
            for option in ("receipt", "generation", "reason"):
                parser.add_argument("--" + option, required=True)
        options = vars(parser.parse_args(args))
        who = identity()
        if who is None:
            raise SessionError("no verified planning session identity is available")
        output = recover(store, *who, **options)
    elif op in {"bind", "reclaim", "release", "clarify", "discuss", "handoff"}:
        who = identity()
        if who is None:
            raise SessionError("no verified planning session identity is available")
        reason = args[2] if len(args) == 3 and args[1] == "--reason" else ""
        output = (store.bind(*who, args[0], reason) if op == "bind"
                  else store.reclaim(*who, args[0], reason) if op == "reclaim"
                  else store.transition(*who, op, args[0]))
    else:
        provider, session = args[:2]
        file = store.route(provider, session)
        if op == "pending":
            output = store.pending(provider, session, args[2] if len(args) > 2 else "", os.environ.get("PWF_TURN_ID", ""))
        elif op in {"claim", "reserve", "created"}:
            output = store.claim(provider, session, args[2], preview="--dry-run" in args,
                                 creating=op == "reserve", finalize=op == "created",
                                 event=args[args.index("--event") + 1] if "--event" in args else "")
        elif op == "resolve":
            output = store.resolve(provider, session)
        elif op == "finish":
            store.transition(provider, session, "finish", args[2], args[3] if len(args) > 3 else None)
        elif op in {"yield", "end-session"}:
            store.yield_turn(provider, session, args[2], ending=op == "end-session", turn=os.environ.get("PWF_TURN_ID", ""))
        elif op == "health":
            row = store.read(file)
            if row.get("task"):
                store.exclusive(file, row["task"])
                store.task_path(row["task"], exists=row["status"] in {"owned", "discussing"})
        elif op == "route-status":
            output = store.read(file).get("status", "")
        elif op == "generation":
            output = store.read(file).get("generation", "legacy")
        elif op == "event-current":
            row = store.read(file)
            turn = os.environ.get("PWF_TURN_ID", "")
            return 1 if turn and row.get("turn") and turn != row["turn"] else 0
        elif op == "owned-task":
            output = store.read(file).get("task", "")
        elif op == "repair-path":
            row = store.read(file)
            if row.get("task") and row["status"] in {"owned", "discussing", "creating"}:
                store.exclusive(file, row["task"])
                output = str(store.task_path(row["task"], exists=False))
        elif op == "pending-candidate":
            row = store.read(file)
            output = (row.get("candidate") or row.get("associated", "")) if row.get("status") in {"pending", "waiting", "idle"} else ""
        elif op == "cache":
            row = store.read(file)
            if row.get("status") == "owned":
                generation = row.get("generation")
                output = str(file.with_suffix(f".{generation}.hook-state" if generation else ".hook-state"))
        elif op in {"event-record", "event-check"}:
            return 0 if store.event(provider, session, args[2], record=op == "event-record") else 1
        elif op == "feedback-file":
            output = str(feedback_path(str(file)))
        elif op in {"skill-loaded", "routing-required"}:
            marker, mode = file.with_suffix(f".{op}"), args[2] if len(args) > 2 else "check"
            if mode == "check":
                return 0 if marker.is_file() else 1
            with store.lock():
                if mode == "mark":
                    if op == "routing-required" and not file.is_file():
                        return 1
                    marker.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    marker.touch(mode=0o600)
                elif mode == "clear":
                    marker.unlink(missing_ok=True)
                else:
                    raise SessionError("invalid marker operation")
        else:
            raise SessionError(f"unknown session operation: {op}")
    if output:
        print(output, end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SessionError, OSError, ValueError, IndexError, subprocess.SubprocessError) as error:
        print(f"plan-files: {error}", file=sys.stderr)
        raise SystemExit(2)
