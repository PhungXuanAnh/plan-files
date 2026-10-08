"""Session routing invariants, with real competing processes and isolated files."""
import concurrent.futures
import json
import multiprocessing
from multiprocessing.managers import SyncManager
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills/plan-files/scripts"))
from session_state import SessionError, SessionStore, identity, plan_transaction


def claim_together(root, provider, session, task, barrier):
    barrier.wait(timeout=10)
    try:
        return SessionStore(Path(root)).claim(provider, session, task)
    except SessionError:
        return "conflict"


def crash_before_rename(root, ready):
    import session_state
    def paused_replace(*args):
        ready.set()
        multiprocessing.Event().wait(30)
        raise RuntimeError("parent did not terminate the fixture")
    session_state.os.replace = paused_replace
    SessionStore(Path(root)).claim("codex", "crashing", "task-a")


def held_transaction(root, task, entered, release):
    with patch.dict(os.environ, {"PWF_PROJECT_ROOT": root, "PWF_SESSION_ADAPTER": "codex", "PWF_SESSION_ID": task}):
        with plan_transaction(Path(root) / "tmp/plan-files" / task / "plan.md"):
            entered.set()
            if not release.wait(10):
                raise RuntimeError("transaction barrier timed out")


class SessionIsolation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="session-state-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = SessionStore(self.root)
        for task in ("task-a", "task-b"):
            self.make_task(task)
        (self.root / ".plan-files").write_text("task-a\n")

    def make_task(self, task):
        path = self.store.plans / task
        path.mkdir(parents=True, exist_ok=True)
        (path / "plan.md").write_text(f"# {task}\n")

    def test_participation_prompt_and_handoff(self):
        self.assertEqual(self.store.pending("codex", "a"), "")
        self.assertEqual(self.store.resolve("codex", "a"), "")
        self.store.bind("codex", "a", "task-a")
        self.store.bind("claude", "b", "task-b")
        self.assertEqual(self.store.pending("claude", "reader"), "")
        self.assertEqual(self.store.pending("codex", "a"), "task-a")
        self.assertEqual(self.store.resolve("codex", "a"), "")
        with self.assertRaises(SessionError):
            self.store.bind("grok", "c", "task-a")
        self.store.transition("codex", "a", "clarify", "task-a")
        self.store.transition("codex", "a", "discuss", "task-a")
        with self.assertRaises(SessionError):
            self.store.bind("codex", "a", "task-a")
        self.store.bind("codex", "a", "task-a", "user approved execution")
        self.store.transition("codex", "a", "handoff", "task-a")
        self.store.bind("grok", "c", "task-a")
        with self.assertRaises(SessionError):
            self.store.claim("codex", "a", "task-a")
        self.assertTrue(self.store.resolve("claude", "b").endswith("task-b"))
        self.store.pending("claude", "b")
        self.store.transition("claude", "b", "release", "task-b")
        self.assertEqual(self.store.pending("claude", "b"), "")
        self.assertEqual((self.root / ".plan-files").read_text(), "task-a\n")

    def test_creation_late_events_and_legacy_conflicts(self):
        self.store.claim("codex", "a", "new", creating=True, event="first")
        with self.assertRaises(SessionError):
            self.store.claim("claude", "b", "new", creating=True)
        self.make_task("new")
        with self.assertRaises(SessionError):
            self.store.claim("codex", "a", "new", finalize=True, event="late")
        self.store.claim("codex", "a", "new", finalize=True, event="first")
        self.store.pending("codex", "a")
        self.store.transition("codex", "a", "release", "new")
        with self.assertRaises(SessionError):
            self.store.claim("codex", "a", "new", finalize=True, event="first")
        first = self.store.route("codex", "legacy")
        second = self.store.route("claude", "legacy")
        for path in (first, second):
            path.parent.mkdir(exist_ok=True)
            path.write_text("status=owned\ntask=task-a\n")
        with self.assertRaises(SessionError):
            self.store.resolve("codex", "legacy")
        self.store.transition("claude", "legacy", "handoff", "task-a")
        self.assertTrue(self.store.resolve("codex", "legacy").endswith("task-a"))
        first.write_text("status=owned\ntask=../../escape\n")
        with self.assertRaises(SessionError):
            self.store.resolve("codex", "legacy")

    def test_process_claims_and_provider_namespaces(self):
        context = multiprocessing.get_context("fork")
        # A TCP manager avoids the Unix socket path limit for long workspace TMPDIRs.
        with SyncManager(address=("127.0.0.1", 0), ctx=context) as manager, concurrent.futures.ProcessPoolExecutor(2, mp_context=context) as pool:
            for n in range(20):
                task = f"race-{n}"
                self.make_task(task)
                barrier = manager.Barrier(2)
                futures = [pool.submit(claim_together, str(self.root), provider, f"race-{n}", task, barrier)
                           for provider in ("codex", "claude")]
                values = [future.result(timeout=15) for future in futures]
                self.assertEqual(values.count("conflict"), 1, values)
                self.assertEqual(len(self.store.owners(task)), 1)
            barrier = manager.Barrier(2)
            futures = [pool.submit(claim_together, str(self.root), provider, "same-id", task, barrier)
                       for provider, task in (("codex", "task-a"), ("claude", "task-b"))]
            self.assertTrue(all(f.result(timeout=15) != "conflict" for f in futures))
        self.assertNotEqual(self.store.route("codex", "same-id"), self.store.route("claude", "same-id"))

    def test_identity_and_preview(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(identity())
            os.environ["CODEX_THREAD_ID"] = "a"
            self.assertEqual(identity(), ("codex", "a"))
            os.environ["GROK_SESSION_ID"] = "b"
            with self.assertRaises(SessionError):
                identity()
            os.environ.update(PWF_SESSION_ADAPTER="grok", PWF_SESSION_ID="b")
            self.assertEqual(identity(), ("grok", "b"))
        self.store.claim("codex", "preview", "task-a", preview=True)
        self.assertFalse(self.store.sessions.exists())

    def test_crash_releases_lock_and_independent_plans_do_not_serialize(self):
        context = multiprocessing.get_context("fork")
        ready = context.Event()
        worker = context.Process(target=crash_before_rename, args=(str(self.root), ready))
        worker.start()
        try:
            self.assertTrue(ready.wait(10))
            self.assertEqual(self.store.read(self.store.route("codex", "crashing")), {})
        finally:
            worker.terminate()
            worker.join(10)
        self.store.claim("codex", "task-a", "task-a")
        self.store.claim("codex", "task-b", "task-b")
        release = context.Event()
        entered = [context.Event(), context.Event()]
        workers = [context.Process(target=held_transaction, args=(str(self.root), task, event, release))
                   for task, event in zip(("task-a", "task-b"), entered)]
        try:
            for worker in workers:
                worker.start()
            # Both reach the inside of their transaction before either releases.
            self.assertTrue(all(event.wait(10) for event in entered))
        finally:
            release.set()
            for worker in workers:
                worker.join(10)
                if worker.is_alive():
                    worker.terminate()
                    worker.join()
                self.assertEqual(worker.exitcode, 0)

    def test_roots_disable_and_stop_lifecycle(self):
        other = SessionStore(self.root / "nested")
        path = other.plans / "task-a"
        path.mkdir(parents=True)
        (path / "plan.md").write_text("# independent")
        other.claim("codex", "same", "task-a")
        self.store.claim("codex", "same", "task-a")
        self.assertNotEqual(other.route("codex", "same"), self.store.route("codex", "same"))
        for flag in ("env", "file"):
            with self.subTest(disabled=flag), patch.dict(os.environ, {"PLANNING_DISABLED": "1" if flag == "env" else "0"}):
                if flag == "file":
                    (self.root / ".plan-files-skip").touch()
                with self.assertRaises(SessionError):
                    self.store.bind("claude", "disabled", "task-b")
                (self.root / ".plan-files-skip").unlink(missing_ok=True)
        self.store.transition("codex", "same", "handoff", "task-a")
        for provider in ("codex", "claude", "copilot", "grok"):
            task = f"settled-{provider}"
            self.make_task(task)
            tasks = self.store.plans / task / "plan.md"
            tasks.write_text("""## Task Identity
Verify lifecycle in an isolated fixture.
## Goal
Verify completion preserves other sessions.
## Workflow Profile
**Profile:** C
## Current Phase
Phase 1
## Active Item
## Phases
### Phase 1: Verify
- [x] [P1.1] Verified artifact.
  - Evidence: fixture artifact checked
- **Status:** complete
""")
            for status in ("deferred (user postponed)", "blocked (external service)", "complete"):
                content = tasks.read_text()
                import re
                content = re.sub(r"- \*\*Status:\*\* .*", f"- **Status:** {status}", content)
                tasks.write_text(content)
                self.store.claim(provider, "lifecycle", task)
                output = self.hook(provider, "lifecycle", "agent-stop.sh", task=task)
                self.assertEqual(output, {}, (provider, status, output))
                row = self.store.read(self.store.route(provider, "lifecycle"))
                self.assertEqual(row["status"], "inactive" if status == "complete" else "owned")
            self.assertEqual((self.root / ".plan-files").read_text(), "task-a\n")

    def test_obsolete_paths_are_ignored_and_current_state_remains_authoritative(self):
        import runpy
        from plan_state import plan_root, pointer_path
        from observe import _resolve_plan
        classifier = runpy.run_path(str(Path(__file__).resolve().parents[1]
                                       / "skills/plan-files/scripts/maintenance-tool-allowed.py"))
        root = self.root / "obsolete"
        old = root / "tmp/plan-with-files/task-a/plan.md"
        old.parent.mkdir(parents=True)
        old.write_text("# Obsolete plan\n")
        (root / ".plan-with-files").write_text("task-a\n")
        (root / ".plan-with-files-skip").touch()
        store = SessionStore(root)
        current = root / "tmp/plan-files"
        self.assertEqual((store.plans, plan_root(root), pointer_path(root)),
                         (current, current, root / ".plan-files"))
        self.assertFalse(store.accepts_state())
        with patch.dict(os.environ, {"PLANNING_DISABLED": "0"}):
            store.enabled()
        with self.assertRaises(SessionError):
            store.task_path("task-a")
        self.assertIsNone(classifier["plan_id_for_path"](str(old), root))
        self.assertEqual(list(classifier["_plan_file_arguments"]([str(old)])), [])
        self.assertTrue(classifier["outside_every_plan"]({"file_path": str(old)}, root))
        self.assertIsNone(_resolve_plan(root, None))
        tasks = current / "task-a/plan.md"
        tasks.parent.mkdir(parents=True)
        tasks.write_text("# Current plan\n")
        store.claim("codex", "current", "task-a")
        with patch.dict(os.environ, {"PWF_SESSION_ADAPTER": "codex", "PWF_SESSION_ID": "current"}):
            self.assertEqual(_resolve_plan(root, None), tasks.resolve())
        self.assertEqual(classifier["plan_id_for_path"](str(tasks), root), "task-a")
        self.assertFalse(classifier["outside_every_plan"]({"file_path": str(tasks)}, root))
        self.assertEqual(old.read_text(), "# Obsolete plan\n")

    def hook(self, provider, session, event, *, task="new", event_id="first", tool="Write", tool_input=None, disabled=False):
        repo = Path(__file__).resolve().parents[1]
        adapter = repo / (".github/hooks/scripts" if provider == "copilot"
                          else f".{provider}/hooks/plan-files/scripts")
        env = {**os.environ, "PWF_PROJECT_ROOT": str(self.root), "GROK_SESSION_ID": session}
        env.pop("PLANNING_DISABLED", None)
        if disabled:
            env["PLANNING_DISABLED"] = "1"
        target = self.store.plans / task / "plan.md"
        payload = {"session_id": session, "sessionId": session, "reason": "end_turn",
                   "tool_name": tool, "toolName": tool,
                   "tool_use_id": event_id, "toolUseId": event_id,
                   "tool_input": {"file_path": str(target), "content": "# plan"},
                   "toolInput": {"file_path": str(target), "content": "# plan"}}
        if tool_input is not None:
            payload["tool_input"] = payload["toolInput"] = tool_input
        result = subprocess.run(["bash", str(adapter / event)], input=json.dumps(payload),
                                env=env, cwd=self.root, text=True, capture_output=True, check=True)
        return json.loads(result.stdout)

    def test_health_recovery_and_generation_fences(self):
        for provider in ("codex", "claude", "copilot", "grok"):
            task = f"health-{provider}"
            self.make_task(task)
            self.store.bind(provider, "health", task)
            file = self.store.route(provider, "health")
            saved = file.read_bytes()
            self.assertEqual(self.hook(provider, "health", "agent-stop.sh", disabled=True), {})
            self.assertEqual(file.read_bytes(), saved)
            (self.root / ".plan-files-skip").touch()
            self.assertEqual(self.hook(provider, "health", "agent-stop.sh"), {})
            (self.root / ".plan-files-skip").unlink()
            self.assertEqual(file.read_bytes(), saved)
            stopped = self.hook(provider, "health", "agent-stop.sh")
            self.assertEqual(stopped.get("hookSpecificOutput", stopped).get("decision"), "block")
            generation = self.store.read(file)["generation"]
            self.store.event(provider, "health", "old-event", record=True)
            self.store.pending(provider, "health")
            self.store.bind(provider, "health", task)
            row = file.read_bytes()
            late = self.hook(provider, "health", "post-tool-use.sh", task=task, event_id="old-event")
            self.assertEqual(late, {})
            self.store.transition(provider, "health", "finish", task, generation)
            self.assertEqual(file.read_bytes(), row)
            foreign = self.store.route(provider, "duplicate")
            foreign.write_text(f"status=owned\ntask={task}\n")
            self.assertIn(self.hook(provider, "health", "pre-tool-use.sh", task=task).get("decision"), {"block", "deny"})
            self.assertEqual(foreign.read_text(), f"status=owned\ntask={task}\n")
            self.store.transition(provider, "duplicate", "handoff", task)
            self.assertTrue(self.store.resolve(provider, "health").endswith(task))
            file.write_text("invalid state\n")
            self.assertIn(self.hook(provider, "health", "pre-tool-use.sh", task=task).get("decision"), {"block", "deny"})
            allowed = self.hook(provider, "health", "pre-tool-use.sh", tool="Bash",
                                tool_input={"command": "git status --short"})
            self.assertNotIn(allowed.get("decision"), {"block", "deny"})
            file.write_bytes(row)

    def test_adapters_reserve_before_creation_and_ignore_delayed_post(self):
        for provider in ("codex", "claude", "copilot", "grok"):
            task = f"new-{provider}"
            with self.subTest(provider=provider):
                allowed = self.hook(provider, "creator", "pre-tool-use.sh", task=task)
                self.assertNotIn(allowed.get("decision"), {"block", "deny"})
                self.assertEqual(len(self.store.owners(task)), 1)
                rejected = self.hook(provider, "competitor", "pre-tool-use.sh", task=task)
                self.assertIn(rejected.get("decision"), {"block", "deny"})
                self.make_task(task)
                self.hook(provider, "creator", "post-tool-use.sh", task=task, event_id="old")
                self.assertEqual(self.store.resolve(provider, "creator"), "")
                self.hook(provider, "creator", "post-tool-use.sh", task=task)
                self.assertTrue(self.store.resolve(provider, "creator").endswith(task))
                self.store.pending(provider, "creator")
                self.hook(provider, "creator", "post-tool-use.sh", task=task)
                self.assertEqual(self.store.resolve(provider, "creator"), "")
                self.store.transition(provider, "creator", "release", task)
                self.hook(provider, "creator", "post-tool-use.sh", task=task)
                self.assertEqual(self.store.resolve(provider, "creator"), "")
                self.store.bind(provider, "competitor", task)
                rejected = self.hook(provider, "creator", "pre-tool-use.sh", task=task)
                self.assertIn(rejected.get("decision"), {"block", "deny"})

    def test_nonparticipant_hooks_do_not_adopt_another_plan(self):
        self.store.claim("codex", "owner", "task-a")
        self.store.claim("claude", "second-owner", "task-b")
        saved = {path: path.read_bytes() for path in self.store.sessions.glob("*/*.state")}
        repo = Path(__file__).resolve().parents[1]
        for provider in ("codex", "claude", "copilot", "grok"):
            adapter = repo / (".github/hooks/scripts" if provider == "copilot"
                              else f".{provider}/hooks/plan-files/scripts")
            env = {**os.environ, "PWF_PROJECT_ROOT": str(self.root),
                   "PWF_SESSION_ADAPTER": provider, "PWF_SESSION_ID": "reader",
                   "GROK_SESSION_ID": "reader", "CODEX_THREAD_ID": "reader",
                   "COPILOT_AGENT_SESSION_ID": "reader"}
            env.pop("PLANNING_DISABLED", None)
            for event in ("user-prompt-submit.sh", "pre-tool-use.sh", "post-tool-use.sh", "agent-stop.sh"):
                if provider == "copilot" and event == "user-prompt-submit.sh":
                    event = "user-prompt-transformed.py"
                payload = {"session_id": "reader", "sessionId": "reader", "reason": "end_turn",
                           "prompt": "Read the repository status", "transformedPrompt": "Read the repository status",
                           "tool_name": "Bash", "toolName": "run_terminal_cmd",
                           "tool_input": {"command": "git status --short"},
                           "toolInput": {"command": "git status --short"}}
                result = subprocess.run(["python3" if event.endswith(".py") else "bash", str(adapter / event)],
                                        input=json.dumps(payload), text=True, capture_output=True,
                                        env=env, cwd=self.root, check=True)
                output = json.loads(result.stdout)
                if provider == "copilot" and event.endswith(".py"):
                    self.assertNotIn("Candidate task", result.stdout)
                else:
                    expected = {"decision": "allow"} if provider == "grok" and event == "pre-tool-use.sh" else {}
                    self.assertEqual(output, expected, (provider, event, result.stdout))
            # A third session can write ordinary files while both plans remain
            # owned, with hooks enabled and no release of either owner's task.
            for event in ("pre-tool-use.sh", "post-tool-use.sh", "agent-stop.sh"):
                payload["tool_input"] = payload["toolInput"] = {"command": "printf separate > standalone.txt"}
                result = subprocess.run(["bash", str(adapter / event)], input=json.dumps(payload),
                                        text=True, capture_output=True, env=env, cwd=self.root, check=True)
                self.assertNotIn(json.loads(result.stdout).get("decision"), {"block", "deny"})
                if event == "pre-tool-use.sh":
                    subprocess.run(["bash", "-c", "printf separate > standalone.txt"], env=env, cwd=self.root, check=True)
            self.assertEqual((self.root / "standalone.txt").read_text(), "separate")
            self.assertTrue(all(path.read_bytes() == content for path, content in saved.items()))
            self.assertEqual(self.store.read(self.store.route(provider, "reader")).get("task"), None)
            if provider == "copilot":
                result = subprocess.run(["bash", str(adapter / "error-occurred.sh")],
                                        input=json.dumps({"sessionId": "reader", "error": "fixture"}),
                                        text=True, capture_output=True, env=env, cwd=self.root, check=True)
                self.assertEqual(json.loads(result.stdout), {})
                self.make_task("error-task")
                self.store.bind("copilot", "reader", "error-task")
                result = subprocess.run(["bash", str(adapter / "error-occurred.sh")],
                                        input=json.dumps({"sessionId": "reader", "error": "fixture"}),
                                        text=True, capture_output=True, env=env, cwd=self.root, check=True)
                self.assertIn("error-task/plan.md", result.stdout)
                self.assertNotIn("task-a/plan.md", result.stdout)
        env_file = self.root / "claude-env"
        result = subprocess.run(["bash", str(repo / ".claude/hooks/plan-files/scripts/session-start.sh")],
                                input=json.dumps({"session_id": "verified"}), text=True, capture_output=True,
                                env={**os.environ, "CLAUDE_ENV_FILE": str(env_file)}, cwd=self.root, check=True)
        self.assertEqual(json.loads(result.stdout), {})
        self.assertEqual(env_file.read_text(), "export PWF_SESSION_ADAPTER=claude\nexport PWF_SESSION_ID=verified\n")
        self.assertTrue(self.store.resolve("codex", "owner").endswith("task-a"))
        self.assertEqual((self.root / ".plan-files").read_text(), "task-a\n")


if __name__ == "__main__":
    unittest.main()
