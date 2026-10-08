"""The planning CLI completes a resumed task without intermediate-state repairs."""
import hashlib
import io
from contextlib import contextmanager, redirect_stdout
import json
import os
import multiprocessing
import shutil
from pathlib import Path
import runpy
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "skills/plan-files/scripts"
sys.path.insert(0, str(SCRIPTS))
from plan_state import parse_plan, restore_payload
from session_state import SessionStore, plan_transaction


def checkpoint_worker(plan, operation, ready, proceed, results):
    import plan_checkpoint
    import session_state
    if operation == "complete":
        original = plan_checkpoint._atomic_write
        def pause_write(path, lines):
            ready.set()
            if not proceed.wait(10):
                raise RuntimeError("write barrier timeout")
            original(path, lines)
        plan_checkpoint._atomic_write = pause_write
    else:
        original = session_state.fcntl.flock
        def signal_lock(fd, mode):
            if mode == session_state.fcntl.LOCK_EX:
                ready.set()
            return original(fd, mode)
        session_state.fcntl.flock = signal_lock
    try:
        if operation == "complete":
            plan_checkpoint.complete(Path(plan), "P3.1", "Completion preserved", None, False)
        elif operation == "progress":
            plan_checkpoint.progress(Path(plan), "P3.1", "Older progress")
        else:
            import plan_edit
            output = io.StringIO()
            with redirect_stdout(output):
                code = plan_edit.main(["--plan", plan, "--expected-fingerprint",
                                       hashlib.sha256(Path(plan).read_bytes()).hexdigest(),
                                       "phase-update", "3", "--title", "Older title"])
            results.put(output.getvalue() if code else operation)
            return
        results.put(operation)
    except (plan_checkpoint.CheckpointError, ValueError) as error:
        results.put(str(error))


def delayed_writer(plan, ready, proceed, results):
    import plan_checkpoint
    original = SessionStore.lock
    @contextmanager
    def pause_before_lock(store, **kwargs):
        ready.set()
        if not proceed.wait(10):
            raise RuntimeError("handoff barrier timed out")
        with original(store, **kwargs):
            yield
    SessionStore.lock = pause_before_lock
    try:
        plan_checkpoint.progress(Path(plan), "P3.1", "Obsolete authorization")
        results.put("unexpected write")
    except ValueError as error:
        results.put(str(error))


class PlanCommands(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="plan commands '")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        self.plan = self.project / "tmp/plan-files/work"
        self.plan.mkdir(parents=True)
        self.tasks = self.plan / "tasks.md"
        self.tasks.write_text("""# Tasks: Verification
## Goal
Verify the requested result.
## Task Identity
- Deliverable: Verified result
- Anchors: work
- Non-goals: production mutation
## Current Phase
Phase 1
## Active Item
## Workflow Profile
**Profile:** C
## Resume Checkpoint
- **Next action:** Wait for authorization for further work.
- **Blocker:** none
## Phases
### Phase 1: Completed verification
- [x] [P1.1] Original result verified.
  - Evidence: local check passed
- **Status:** complete
### Phase 2: Later followup
- [ ] [P2.1] External followup finished.
  - Evidence: pending
- **Status:** deferred (user assigned this to another owner)
## Verification
- Verify the local observable result.
""")
        (self.plan / "decisions.md").write_text(
            "## Active Decisions\n| ID | Decision | Rationale | Date |\n"
            "|----|----------|-----------|------|\n| D1 | Verify locally | User request | 2026-09-08 |\n"
            "## Superseded Decisions\n- None.\n## Open Decision Questions\n- None.\n")
        (self.plan / "findings.md").write_text("## Current Summary\n- Original result passed.\n")
        (self.project / ".plan-files").write_text("work\n")
        environment = patch.dict(os.environ, {"PWF_PROJECT_ROOT": str(self.project),
                                 "PWF_SESSION_ADAPTER": "codex", "PWF_SESSION_ID": "commands"})
        environment.start()
        self.addCleanup(environment.stop)
        SessionStore(self.project).claim("codex", "commands", "work")

    def call(self, script, *args, check=True):
        return subprocess.run([sys.executable, str(SCRIPTS / script), *map(str, args)],
                              cwd=self.project, env={**os.environ, "PWF_PROJECT_ROOT": str(self.project)},
                              text=True, capture_output=True, check=check)

    def edit(self, *args, check=True, fingerprint=None):
        return self.call("plan_edit.py", "--expected-fingerprint", fingerprint or self.sha(),
                         *args, check=check)

    def sha(self):
        return hashlib.sha256(self.tasks.read_bytes()).hexdigest()

    def test_default_resolution_and_explicit_foreign_plan(self):
        other = self.plan.parent / "other"
        shutil.copytree(self.plan, other)
        store = SessionStore(self.project)
        store.claim("claude", "other-session", "other")
        (self.project / ".plan-files").write_text("other\n")
        saved = (other / "tasks.md").read_bytes()
        self.edit("reopen", "--title", "More", "--decision", "| D2 | Continue | User request | 2026-10-08 |",
                  "--item", "New result")
        result = json.loads(self.call("plan_checkpoint.py", "progress", "P3.1", "--evidence", "Own result").stdout)
        self.assertEqual(Path(result["plan"]), self.tasks)
        self.assertEqual((other / "tasks.md").read_bytes(), saved)
        denied = self.call("plan_checkpoint.py", "--plan", other / "tasks.md", "progress", "P3.1",
                           "--evidence", "Foreign result", check=False)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("reserved by another session", denied.stdout)
        with patch.dict(os.environ, dict.fromkeys(("PWF_SESSION_ADAPTER", "PWF_SESSION_ID", "CODEX_THREAD_ID",
                         "CLAUDE_SESSION_ID", "COPILOT_AGENT_SESSION_ID", "GROK_SESSION_ID"), "")):
            denied = self.call("plan_state.py", "overview", check=False)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("no planning session identity", denied.stdout)

    def test_same_and_mixed_provider_sessions_keep_separate_plans(self):
        original = self.tasks.read_bytes()
        other = self.plan.parent / "other"
        shutil.copytree(self.plan, other)
        for a, b in (("codex", "codex"), ("claude", "claude"), ("codex", "claude")):
            with self.subTest(providers=(a, b)):
                shutil.rmtree(self.plan.parent / ".sessions")
                self.tasks.write_bytes(original)
                (other / "tasks.md").write_bytes(original)
                store = SessionStore(self.project)
                store.bind(a, "a", "work")
                store.bind(b, "b", "other")
                (self.project / ".plan-files").write_text("other\n")
                with patch.dict(os.environ, {"PWF_SESSION_ADAPTER": a, "PWF_SESSION_ID": "a"}):
                    overview = json.loads(self.call("plan_state.py", "overview").stdout)
                    self.assertEqual(Path(overview["plan"]), self.tasks)
                    self.edit("reopen", "--title", "Own work", "--decision", "| D2 | Continue | User request | 2026-10-08 |",
                              "--item", "Own result")
                    self.call("plan_checkpoint.py", "complete", "P3.1", "--evidence", "Own result verified")
                    self.assertEqual((other / "tasks.md").read_bytes(), original)
                with patch.dict(os.environ, {"PWF_SESSION_ADAPTER": b, "PWF_SESSION_ID": "b"}):
                    overview = json.loads(self.call("plan_state.py", "overview").stdout)
                    self.assertEqual(Path(overview["plan"]), other / "tasks.md")
                    denied = self.call("plan_edit.py", "--plan", self.tasks, "--expected-fingerprint", self.sha(),
                                       "phase-add", "--title", "Foreign", check=False)
                    self.assertNotEqual(denied.returncode, 0)
                    self.assertIn("reserved by another session", denied.stdout)

    def test_checkpoint_transactions_preserve_completed_evidence(self):
        self.edit("reopen", "--title", "Concurrent", "--decision", "| D2 | Continue | User request | 2026-10-08 |",
                  "--item", "Concurrent result")
        saved = self.tasks.read_bytes()
        for iteration in range(20):
            with self.subTest(iteration=iteration):
                self.tasks.write_bytes(saved)
                self.checkpoint_race("progress" if iteration % 2 == 0 else "edit")

    def checkpoint_race(self, second_operation):
        context = multiprocessing.get_context("fork")
        first_ready, second_ready, proceed = context.Event(), context.Event(), context.Event()
        results = context.Queue()
        workers = [context.Process(target=checkpoint_worker, args=(str(self.tasks), op, ready, proceed, results))
                   for op, ready in (("complete", first_ready), (second_operation, second_ready))]
        try:
            workers[0].start()
            self.assertTrue(first_ready.wait(10))
            workers[1].start()
            self.assertTrue(second_ready.wait(10))
            proceed.set()
            outcomes = [results.get(timeout=10) for _ in workers]
            self.assertIn("complete", outcomes)
            expected = "not Active Item" if second_operation == "progress" else "fingerprint"
            self.assertTrue(any(expected in value for value in outcomes), outcomes)
            item = parse_plan(self.tasks).item("P3.1")
            self.assertTrue(item.checked)
            self.assertEqual(item.evidence, "Completion preserved")
        finally:
            proceed.set()
            for worker in workers:
                if worker.pid:
                    worker.join(10)
                    if worker.is_alive():
                        worker.terminate()
                        worker.join()
            results.close()

    def test_handoff_invalidates_preapproved_and_waiting_writers(self):
        self.edit("reopen", "--title", "Handoff", "--decision", "| D2 | Continue | User request | 2026-10-08 |",
                  "--item", "Preserve new ownership")
        saved = self.tasks.read_bytes()
        pre = SCRIPTS.parents[2] / ".codex/hooks/plan-files/scripts/pre-tool-use.sh"
        payload = {"session_id": "commands", "tool_name": "Bash", "tool_input": {
            "command": shlex.join([sys.executable, str(SCRIPTS / "plan_checkpoint.py"), "--plan",
                                   str(self.tasks), "progress", "P3.1", "--evidence", "Old work"])}}
        result = subprocess.run(["bash", str(pre)], input=json.dumps(payload), cwd=self.project,
                                text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(result.stdout), {})
        context = multiprocessing.get_context("fork")
        ready, proceed, results = context.Event(), context.Event(), context.Queue()
        worker = context.Process(target=delayed_writer, args=(str(self.tasks), ready, proceed, results))
        worker.start()
        try:
            self.assertTrue(ready.wait(10))
            store = SessionStore(self.project)
            store.transition("codex", "commands", "handoff", "work")
            # Even the unowned gap after handoff cannot revive the old session.
            denied = self.call("plan_checkpoint.py", "--plan", self.tasks, "progress", "P3.1",
                               "--evidence", "Late work", check=False)
            self.assertIn("relinquished", denied.stdout)
            store.bind("claude", "receiver", "work")
            proceed.set()
            self.assertIn("ownership changed while waiting", results.get(timeout=10))
            self.assertEqual(self.tasks.read_bytes(), saved)
        finally:
            proceed.set()
            worker.join(10)
            if worker.is_alive():
                worker.terminate()
                worker.join()
            results.close()

    def test_fingerprint_formats_and_short_output(self):
        legacy = self.call("plan_state.py", "fingerprint").stdout.strip()
        data = json.loads(self.call("plan_state.py", "fingerprint", "--json").stdout)
        self.assertEqual((data["fingerprint"], data["file_fingerprint"]), (legacy, self.sha()))
        self.assertEqual(len(legacy), 16)
        for file in (self.tasks, self.plan / "decisions.md"):
            with self.subTest(file=file.name):
                self.assertEqual(self.call("plan_state.py", "fingerprint", "--file", file).stdout.strip(),
                                 hashlib.sha256(file.read_bytes()).hexdigest())
        operation = ("--dry-run", "phase-add", "--title", "Next", "--item", "Result works.", "--start")
        full = self.edit(*operation).stdout
        short = self.edit("--compact", *operation).stdout
        self.assertLess(len(short), len(full))
        self.assertEqual(json.loads(short)["file_fingerprint"], json.loads(full)["fingerprint"])
        self.assertEqual(parse_plan(self.tasks).current_phase, 1)

    def test_atomic_phase_setup_and_failed_edits_leave_state_unchanged(self):
        before = self.sha()
        result = json.loads(self.edit("phase-add", "--title", "Next", "--item", "First result works.",
                                     "--item", "Second result works.", "--verify", "Acceptance passes.", "--start").stdout)
        state = parse_plan(self.tasks)
        self.assertEqual((state.current_phase, state.active_item, state.phase(3).status), (3, "P3.1", "in_progress"))
        self.assertEqual(result["items"], ["P3.1", "P3.2", "V3.1"])
        self.assertTrue(restore_payload(self.tasks)["ok"])
        self.assertEqual(state.phase(2).status, "deferred")
        saved = self.tasks.read_bytes()
        for options in [dict(fingerprint=before), dict()]:
            failed = self.edit("phase-add", "--title", "Cannot start", "--item", "Still works.", "--start",
                               check=False, **options)
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse(json.loads(failed.stdout)["ok"])
            self.assertEqual(self.tasks.read_bytes(), saved)

    def test_reopen_preserves_deferred_work_and_checkpoints_finalize(self):
        result = json.loads(self.edit("--compact", "reopen", "--title", "New authorization",
                                     "--decision", "| D2 | Extend verification | User requested | 2026-09-08 |",
                                     "--item", "New result verified.").stdout)
        self.assertEqual(result["item"], "P3.1")
        self.assertTrue(restore_payload(self.tasks)["ok"])
        self.call("plan_checkpoint.py", "complete", "P3.1", "--evidence", "New local result passed", "--deactivate-pointer")
        self.call("plan_checkpoint.py", "--plan", self.tasks, "assert-finalizable", "--project-root", self.project)
        self.assertEqual(parse_plan(self.tasks).phase(2).status, "deferred")
        self.assertEqual((self.project / ".plan-files").read_text().strip(), "work")

    def test_resume_preserves_ids_evidence_and_records_authorization(self):
        self.tasks.write_text(self.tasks.read_text().replace(
            "Evidence: pending", "Evidence: two checks already passed"))
        saved = self.tasks.read_bytes()
        decision = "| D2 | Resume followup | User requested | 2026-10-05 |"
        preview = self.edit("--dry-run", "resume", "2", "--decision", decision)
        self.assertEqual(json.loads(preview.stdout)["item"], "P2.1")
        self.assertEqual(self.tasks.read_bytes(), saved)
        self.assertNotIn(decision, (self.plan / "decisions.md").read_text())
        result = json.loads(self.edit("resume", "2", "--decision", decision).stdout)
        state = parse_plan(self.tasks)
        self.assertEqual((state.current_phase, state.active_item, state.phase(2).status),
                         (2, "P2.1", "in_progress"))
        self.assertEqual(state.item("P2.1").evidence, "two checks already passed")
        self.assertEqual(len(state.phases), 2)
        self.assertIsNone(result["archived_phase"])
        self.assertFalse((self.plan / "history.md").exists())
        self.assertTrue(restore_payload(self.tasks)["ok"])
        saved = {file: file.read_bytes() for file in self.plan.glob("*.md")}
        for phase in (1, 2):
            failed = self.edit("resume", str(phase), "--decision", decision, check=False)
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual({file: file.read_bytes() for file in saved}, saved)

    def test_append_followup_preserves_evidence_and_rejects_invalid_targets(self):
        decision = "| D2 | Verify small followup | User requested followup | 2026-10-05 |"
        for phase in (2, 9):
            saved = {file: file.read_bytes() for file in self.plan.glob("*.md")}
            failed = self.edit("reopen", "--append", str(phase), "--decision", decision,
                               "--item", "Small followup verified", check=False)
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual({file: file.read_bytes() for file in saved}, saved)
        result = json.loads(self.edit("reopen", "--append", "1", "--decision", decision,
                                      "--goal", "Deliver the authorized correction.\nKeep prior verification.",
                                      "--item", "Small followup verified").stdout)
        state = parse_plan(self.tasks)
        self.assertEqual((len(state.phases), state.active_item, result["item"]), (2, "P1.2", "P1.2"))
        self.assertTrue(state.item("P1.1").checked)
        self.assertEqual(state.item("P1.1").evidence, "local check passed")
        self.assertTrue(restore_payload(self.tasks)["ok"])

    def test_execution_status_edits_do_not_publish_unrestorable_state(self):
        for status in ("in_progress", "pending"):
            with self.subTest(status=status):
                saved = self.tasks.read_bytes()
                failed = self.edit("phase-update", "2", "--status", status, check=False)
                self.assertNotEqual(failed.returncode, 0)
                self.assertIn("resume 2 --decision", failed.stdout)
                self.assertEqual(self.tasks.read_bytes(), saved)
                self.assertTrue(restore_payload(self.tasks)["ok"])
        failed = self.call("plan_checkpoint.py", "start", "P2.1", check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(self.tasks.read_bytes(), saved)
        self.edit("phase-add", "--title", "Current", "--item", "Current result", "--start")
        self.edit("phase-add", "--title", "Next", "--item", "Next result")
        saved = self.tasks.read_bytes()
        failed = self.edit("phase-update", "4", "--status", "in_progress", check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("start P4.1", failed.stdout)
        self.assertEqual(self.tasks.read_bytes(), saved)
        self.edit("phase-update", "3", "--status", "in_progress")
        self.assertTrue(restore_payload(self.tasks)["ok"])

    def test_deferred_creation_is_skipped_and_active_deferral_names_pause(self):
        self.edit("phase-add", "--title", "Current", "--item", "Current result", "--start")
        failed = self.edit("phase-update", "3", "--status", "deferred", "--reason", "User postponed", check=False)
        self.assertIn("pause --phase 3", failed.stdout)
        saved = self.tasks.read_bytes()
        for options in (("--status", "deferred"),
                        ("--status", "deferred", "--reason", "User postponed", "--start")):
            self.assertNotEqual(self.edit("phase-add", "--title", "Later", "--item", "Later result",
                                          *options, check=False).returncode, 0)
            self.assertEqual(self.tasks.read_bytes(), saved)
        self.edit("phase-add", "--title", "Later", "--item", "Later result",
                  "--status", "deferred", "--reason", "User postponed (after review)")
        result = json.loads(self.call("plan_checkpoint.py", "complete", "P3.1", "--evidence", "Verified").stdout)
        self.assertIsNone(result["next_item"])
        self.assertEqual(parse_plan(self.tasks).phase(4).status, "deferred")
        self.assertTrue(restore_payload(self.tasks)["ok"])

    def test_decisions_compact_preserves_active_rows_and_recovers_history_write(self):
        decisions = self.plan / "decisions.md"
        history = self.plan / "history.md"
        active = decisions.read_text().split("## Superseded Decisions")[0]
        old_row = "| D0 | " + "x" * 12100 + " | D1 | User changed scope |"
        decisions.write_text(active + "## Superseded Decisions\n" + old_row
                             + "\n## Open Decision Questions\n- Keep this question.\n")
        saved = decisions.read_bytes()
        fingerprint = hashlib.sha256(saved).hexdigest()
        self.edit("--dry-run", "decisions-compact", "--expected-history-fingerprint", "missing",
                  fingerprint=fingerprint)
        self.assertEqual(decisions.read_bytes(), saved)
        self.assertFalse(history.exists())
        with patch.dict(os.environ, {"PWF_PLAN_EDIT_FAIL_AFTER": "history"}):
            failed = self.edit("decisions-compact", "--expected-history-fingerprint", "missing",
                               fingerprint=fingerprint, check=False)
        self.assertIn("injected failure after history", failed.stdout)
        self.assertIn(old_row, history.read_text())
        self.assertEqual(decisions.read_bytes(), saved)
        self.edit("phase-update", "1", "--title", "Recovered")
        self.assertFalse((self.plan / ".plan-edit-transaction.json").exists())
        self.assertTrue(decisions.read_text().startswith(active))
        self.assertIn("Keep this question.", decisions.read_text())
        self.assertNotIn(old_row, decisions.read_text())
        self.assertEqual(history.read_text().count(old_row), 1)
        self.edit("reopen", "--title", "Next", "--decision", "| D2 | Continue | User request | 2026-10-05 |",
                  "--item", "Next result")

    def test_active_decision_consolidation_is_explicit_and_recoverable(self):
        decisions = self.plan / "decisions.md"
        original = "| D2 | " + "retain requirement; " * 800 + " | User request | 2026-10-05 |"
        decisions.write_text(decisions.read_text().replace("## Superseded Decisions", original + "\n## Superseded Decisions"))
        saved = decisions.read_bytes()
        fingerprint = hashlib.sha256(saved).hexdigest()
        replacement = "| D3 | Retain requirement | Consolidates D2 without changing scope | 2026-10-05 |"
        args = ("decisions-consolidate", "--decision", "D2", "--replacement", replacement,
                "--expected-history-fingerprint", "missing")
        for selected in ("D9", "D1"):
            failed = self.edit("decisions-consolidate", "--decision", selected, "--replacement",
                               replacement.replace("D3", "D1"), "--expected-history-fingerprint", "missing",
                               fingerprint=fingerprint, check=False)
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(decisions.read_bytes(), saved)
        self.edit("--dry-run", *args, fingerprint=fingerprint)
        self.assertEqual(decisions.read_bytes(), saved)
        with patch.dict(os.environ, {"PWF_PLAN_EDIT_FAIL_AFTER": "history"}):
            failed = self.edit(*args, fingerprint=fingerprint, check=False)
        self.assertIn("injected failure after history", failed.stdout)
        self.assertEqual(decisions.read_bytes(), saved)
        self.edit("phase-update", "1", "--title", "Recovered")
        self.assertIn(original, (self.plan / "history.md").read_text())
        self.assertIn(replacement, decisions.read_text())
        self.assertIn("| D1 | Verify locally", decisions.read_text())
        self.assertIn("## Open Decision Questions", decisions.read_text())
        self.assertNotIn(original, decisions.read_text())
        self.assertLess(len(decisions.read_bytes()), 12288)

    def test_park_keeps_candidate_and_resume_clears_parked_state(self):
        saved = self.tasks.read_bytes()
        for reason in ("none", "<reason>"):
            self.assertNotEqual(self.call("plan_checkpoint.py", "park", "--reason", reason, check=False).returncode, 0)
            self.assertEqual(self.tasks.read_bytes(), saved)
        self.call("plan_checkpoint.py", "park", "--reason", "User will resume later")
        self.call("plan_checkpoint.py", "assert-finalizable", "--project-root", self.project)
        self.assertEqual((self.project / ".plan-files").read_text(), "work\n")
        self.assertIn("**Parked:** User will resume later", self.tasks.read_text())
        self.edit("resume", "2", "--decision", "| D2 | Resume followup | User authorized | 2026-10-05 |")
        self.assertNotIn("**Parked:**", self.tasks.read_text())
        saved = self.tasks.read_bytes()
        self.assertNotEqual(self.call("plan_checkpoint.py", "park", "--reason", "Later", check=False).returncode, 0)
        self.assertEqual(self.tasks.read_bytes(), saved)
        self.assertTrue(restore_payload(self.tasks)["ok"])
        self.assertNotEqual(self.call("plan_checkpoint.py", "assert-finalizable", "--project-root",
                                     self.project, check=False).returncode, 0)

    def test_invalid_checkpoint_candidate_never_replaces_original(self):
        import plan_checkpoint
        saved = self.tasks.read_bytes()
        invalid = self.tasks.read_text().replace("- **Status:** complete", "- **Status:** in_progress").replace("[x]", "[ ]").splitlines()
        with self.assertRaises(plan_checkpoint.CheckpointError):
            plan_checkpoint._atomic_write(self.tasks, invalid)
        self.assertEqual(self.tasks.read_bytes(), saved)

    def test_pointer_cleanup_reports_why_it_did_not_clear(self):
        pointer = self.project / ".plan-files"
        for value in ("work\n", "", "other\n", None):
            with self.subTest(value=value):
                if value is None:
                    pointer.unlink()
                else:
                    pointer.write_text(value)
                result = json.loads(self.call("plan_checkpoint.py", "--plan", self.tasks,
                                              "deactivate-pointer", "--project-root", self.project).stdout)
                self.assertEqual(result["reason"], "session_scoped")
                self.assertFalse(result["cleared"])
                if value is not None:
                    self.assertEqual(pointer.read_text(), value)

    def test_rollover_error_example_can_be_completed_and_executed(self):
        completed = "".join(f"### Phase {number}: Earlier result\n- **Status:** complete\n"
                            for number in range(3, 13))
        self.tasks.write_text(self.tasks.read_text().replace("## Verification", completed + "## Verification"))
        failed = self.edit("reopen", "--title", "Next", "--decision", "| D2 | Continue | User request | 2026-10-05 |",
                           "--item", "Next result", check=False)
        self.assertNotEqual(failed.returncode, 0)
        command = json.loads(failed.stdout)["error"].split("Example: ", 1)[1]
        for placeholder, value in {"tasks-sha256": self.sha(), "history-sha256-or-missing": "missing",
                                   "phase title": "Next", "outcome": "Next result", "ID": "D2",
                                   "authorization": "Continue", "reason": "User request", "date": "2026-10-05"}.items():
            command = command.replace(f"<{placeholder}>", value)
        result = subprocess.run(shlex.split(command), cwd=self.project, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)["item"], "P13.1")
        self.assertTrue(restore_payload(self.tasks)["ok"])

    def test_planning_helpers_have_zero_risk_without_hiding_other_work(self):
        helper = shlex.join(["python3", str(SCRIPTS / "plan_state.py"), "overview", str(self.tasks)])
        commands = [(helper, 0),
                    (shlex.join(["python3", str(SCRIPTS / "plan_edit.py"), "phase-add", "--title", "Next"]), 0),
                    (shlex.join(["python3", str(SCRIPTS / "plan_checkpoint.py"), "complete", "P3.1",
                                 "--evidence", "Verified", "--deactivate-pointer"]), 0),
                    (helper + " && touch app.py", 1),
                    (helper + " && pytest tests", 2),
                    (shlex.join(["python3", str(SCRIPTS / "plan_state.py"), "overview",
                                 str(self.plan.parent / "other/tasks.md")]), 1)]
        for command, weight in commands:
            with self.subTest(command=command):
                result = subprocess.run([sys.executable, str(SCRIPTS / "maintenance-tool-allowed.py"),
                                         "tool-class", str(self.plan)], cwd=self.project, text=True,
                                        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": command}}),
                                        capture_output=True, check=True)
                classification = json.loads(result.stdout)
                self.assertEqual(classification["semantic_weight"], weight)
                self.assertEqual(classification["plan_maintenance"], weight == 0)

    def test_legacy_findings_can_be_compacted_without_changing_trusted_state(self):
        findings = self.plan / "findings.md"
        findings.write_text("## Current Summary\n- Current result retained.\n## Phase 5 Evidence\n" + "x" * 33000 + "\n")
        saved_tasks = self.tasks.read_bytes()
        sha = hashlib.sha256(findings.read_bytes()).hexdigest()
        result = self.edit("--compact", "section-replace", "--file", "findings.md", "--heading", "Phase 5 Evidence",
                           "--content", "- Original source is preserved in findings-detail.md.", fingerprint=sha)
        self.assertTrue(json.loads(result.stdout)["ok"])
        self.assertIn("Current result retained", findings.read_text())
        self.assertLess(findings.stat().st_size, 32768)
        self.assertEqual(self.tasks.read_bytes(), saved_tasks)
        for file, heading in (("findings.md", "Missing section"), ("tasks.md", "Current Phase")):
            target = self.plan / file
            before = target.read_bytes()
            failed = self.edit("section-replace", "--file", file, "--heading", heading, "--content", "replacement",
                               fingerprint=hashlib.sha256(before).hexdigest(), check=False)
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(target.read_bytes(), before)

        findings.write_text(findings.read_text() + "\n## Phase 5 Evidence\n- Duplicate legacy heading.\n")
        before = findings.read_bytes()
        failed = self.edit("section-replace", "--file", "findings.md", "--heading", "Phase 5 Evidence",
                           "--content", "replacement", fingerprint=hashlib.sha256(before).hexdigest(), check=False)
        self.assertIn("expected exactly one", failed.stdout)
        self.assertEqual(findings.read_bytes(), before)

    def test_literal_heredoc_scope_and_body_are_not_confused_with_code(self):
        classifier = runpy.run_path(str(SCRIPTS / "maintenance-tool-allowed.py"))
        target = self.plan / "findings.md"
        sentinel = self.project / "must-not-run"
        body = f"Literal $(touch {shlex.quote(str(sentinel))})\n*** Update File: {self.tasks}\n"
        command = f"cat >> {shlex.quote(str(target))} <<'MD'\n{body}MD\necho ok"
        outside = self.project / "outside"
        outside.mkdir()
        (self.plan / "external").symlink_to(outside, target_is_directory=True)
        variants = [(command, True),
                    (command.replace("<<'MD'", '<<"MD"'), True),
                    (f"cat <<'MD' > {shlex.quote(str(target))}\n{body}MD", True),
                    (command.replace("<<'MD'", "<<MD"), False),
                    (command.replace(shlex.quote(str(target)), shlex.quote(str(self.project / 'outside.md'))), False),
                    (command.replace(shlex.quote(str(target)), shlex.quote(str(self.plan / 'external/escape.md'))), False),
                    (command.replace(" <<'MD'", ";/tmp/arbitrary-program.md <<'MD'"), False),
                    (command.replace(shlex.quote(str(target)), str(self.plan / '{a,../../escape}.md')), False),
                    (command + "\ntouch app.py", False),
                    (command.replace("MD\necho ok", "NOT_CLOSED"), False),
                    (command.replace(shlex.quote(str(target)), '"$TARGET"'), False)]
        for text, owned in variants:
            with self.subTest(command=text):
                payload = {"tool_name": "Bash", "tool_input": {"command": text}}
                state = classifier["tool_class"](payload, self.plan)
                self.assertEqual(state["plan_maintenance"], owned)
                result = subprocess.run([sys.executable, str(SCRIPTS / "maintenance-tool-allowed.py"), str(self.plan)],
                                        input=json.dumps(payload), text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, owned)
        subprocess.run(["bash", "-c", command], cwd=self.project, check=True, capture_output=True)
        self.assertFalse(sentinel.exists())
        self.assertTrue(target.read_text().endswith(body))
        payload = {"tool_name": "Bash", "tool_input": {"command": command}}
        self.assertEqual(classifier["plan_op_class"](payload, self.plan), "record")
        payload["tool_input"]["command"] = command.replace(shlex.quote(str(target)), shlex.quote(str(self.tasks)))
        self.assertEqual(classifier["plan_op_class"](payload, self.plan), "advance")


if __name__ == "__main__":
    unittest.main()
