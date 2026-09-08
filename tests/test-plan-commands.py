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
