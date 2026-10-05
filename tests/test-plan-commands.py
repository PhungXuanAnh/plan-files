"""The planning CLI completes a resumed task without intermediate-state repairs."""
import hashlib
import json
import os
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

    def call(self, script, *args, check=True):
        return subprocess.run([sys.executable, str(SCRIPTS / script), *map(str, args)],
                              cwd=self.project, env={**os.environ, "PWF_PROJECT_ROOT": str(self.project)},
                              text=True, capture_output=True, check=check)

    def edit(self, *args, check=True, fingerprint=None):
        return self.call("plan_edit.py", "--expected-fingerprint", fingerprint or self.sha(),
                         *args, check=check)

    def sha(self):
        return hashlib.sha256(self.tasks.read_bytes()).hexdigest()

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
        self.assertEqual((self.project / ".plan-files").read_text().strip(), "")

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
        for value, expected in (("work\n", "cleared"), ("", "already_empty"),
                                ("other\n", "different_task"), (None, "missing")):
            with self.subTest(value=value):
                if value is None:
                    pointer.unlink()
                else:
                    pointer.write_text(value)
                result = json.loads(self.call("plan_checkpoint.py", "--plan", self.tasks,
                                              "deactivate-pointer", "--project-root", self.project).stdout)
                self.assertEqual(result["reason"], expected)
                self.assertEqual(result["cleared"], expected == "cleared")
                if value == "other\n":
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
