"""Cross-provider ownership recovery and maintenance behavior, in isolated roots."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills/plan-files/scripts"
ADAPTERS = {
    "codex": ROOT / ".codex/hooks/plan-files/scripts",
    "claude": ROOT / ".claude/hooks/plan-files/scripts",
    "copilot": ROOT / ".github/hooks/scripts",
    "grok": ROOT / ".grok/hooks/plan-files/scripts",
}


class OwnershipFlow(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ownership space '")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        self.plan = self.project / "tmp/plan-files/task-a"
        self.plan.mkdir(parents=True)
        self.tasks = self.plan / "tasks.md"
        self.tasks.write_text("""# Tasks: Branded links
## Goal
Deliver branded links.
## Task Identity
- Deliverable: Research and implementation proposal
- Anchors: task-a
- Non-goals: implementation until user authorization
## Current Phase
Phase 1
## Active Item
P1.1
## Workflow Profile
**Profile:** C
## Resume Checkpoint
- **Next action:** Complete P1.1: verify redirect behavior
- **Blocker:** none
## Phases
### Phase 1: Work
- [ ] [P1.1] Redirect works.
  - Evidence: pending
- **Status:** in_progress
## Verification
- Check redirect response.
""")
        (self.plan / "decisions.md").write_text("## Active Decisions\n- None.\n")
        (self.plan / "findings.md").write_text("## Current Summary\n- Redirect verification remains.\n")
        (self.project / ".plan-files").write_text("task-a\n")

    def run_command(self, args, provider, payload=None, check=True):
        env = {**os.environ, "PWF_PROJECT_ROOT": str(self.project),
               "PWF_SESSION_ADAPTER": provider, "PWF_SESSION_ID": "fixture",
               "CODEX_THREAD_ID": "fixture", "COPILOT_AGENT_SESSION_ID": "fixture",
               "GROK_SESSION_ID": "fixture", "GROK_WORKSPACE_ROOT": str(self.project)}
        env.pop("PLANNING_DISABLED", None)
        return subprocess.run(args, cwd=self.project, env=env,
                              input=json.dumps(payload) if payload else None,
                              capture_output=True, text=True, check=check)

    def state(self, provider, *args, check=True):
        return self.run_command(["bash", str(SCRIPTS / "session-state.sh"), *args],
                                provider, check=check).stdout.strip()

    def hook(self, provider, event, command="git status --short", tool=None, tool_input=None, expand=True):
        if provider == "copilot" and event == "user-prompt-submit.sh":
            event = "user-prompt-transformed.py"
        camel = provider in {"grok", "copilot"}
        payload = ({"sessionId": "fixture", "toolName": tool or "run_terminal_cmd",
                    "toolInput": {"command": command}, "reason": "end_turn"}
                   if camel else
                   {"session_id": "fixture", "tool_name": tool or "Bash",
                    "tool_input": {"command": command}})
        if tool_input is not None:
            payload["toolInput" if camel else "tool_input"] = tool_input
        result = json.loads(self.run_command(
            ["python3" if event.endswith(".py") else "bash", str(ADAPTERS[provider] / event)],
            provider, {**payload, "transformedPrompt": "continue"}).stdout)
        result = result.get("hookSpecificOutput", result)
        if provider == "grok" and event == "pre-tool-use.sh" and "reason" in result:
            self.assertLessEqual(len(result["reason"]), 256)
            path = Path(self.state(provider, "feedback-file", provider, "fixture"))
            if str(path) in result["reason"]:
                self.addCleanup(path.unlink, missing_ok=True)
                if expand:
                    allowed = self.hook(provider, event, tool="unknown_reader",
                                        tool_input={"nested": [{"path": str(path)}]}, expand=False)
                    self.assertEqual(allowed.get("decision"), "allow")
                    result["reason"] = path.read_text().rstrip("\n")
        return result

    def action(self, provider, verb):
        # Use the exact shell-quoted command supplied by the shared core.
        context = self.state(provider, "candidate-context", "task-a",
                             str(ADAPTERS[provider] / "bind-session.sh"))
        import re
        return next(cmd for cmd in re.findall(r"`([^`]+)`", context)
                    if cmd.endswith(f" {verb} task-a"))

    def test_recovery_message_and_bind(self):
        # Long identity and shell-sensitive root paths exercise real output and execution.
        self.tasks.write_text(self.tasks.read_text().replace(
            "Research and implementation proposal", "Research " + "long identity " * 100))
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "pending", provider, "fixture", "task-a")
                pre = self.hook(provider, "pre-tool-use.sh")
                stop = self.hook(provider, "agent-stop.sh")
                command = self.action(provider, "bind")
                self.assertIn(command, pre["reason"])
                self.assertIn(command, stop["reason"])
                self.assertEqual(pre["reason"], stop["reason"])
                self.assertLess(pre["reason"].index(command), pre["reason"].index("## Task Identity"))
                self.assertLess(len(pre["reason"]), 10000)
                # Full instructions are separate from capped host deny output.
                self.assertNotIn(command, pre["reason"][:256])
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", command).get("decision"),
                                 {"block", "deny"})
                self.run_command(["bash", "-c", command], provider)
                self.assertEqual(self.state(provider, "resolve", provider, "fixture"), str(self.plan))
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh").get("decision"), {"block", "deny"})

    def test_missing_identity_still_supplies_recovery(self):
        self.tasks.write_text("# Tasks: empty identity\n")
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "pending", provider, "fixture", "task-a")
                pre = self.hook(provider, "pre-tool-use.sh")
                self.assertIn(self.action(provider, "bind"), pre["reason"])
                self.assertEqual(pre["reason"], self.hook(provider, "agent-stop.sh")["reason"])

    def test_clarify_preserves_candidate_and_gates_work(self):
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "pending", provider, "fixture", "task-a")
                command = self.action(provider, "clarify")
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", command).get("decision"), {"block", "deny"})
                self.run_command(["bash", "-c", command], provider)
                self.assertEqual(self.hook(provider, "agent-stop.sh"), {})
                self.assertEqual((self.project / ".plan-files").read_text().strip(), "task-a")
                self.assertEqual(self.state(provider, "resolve", provider, "fixture", check=False), "")
                for tool in ("AskUserQuestion", "ask_user_question", "request_user_input_async",
                             "functions.request_user_input_async", "mcp__ui__ask_user_question"):
                    self.assertNotIn(self.hook(provider, "pre-tool-use.sh", tool=tool).get("decision"), {"block", "deny"})
                for cmd in ("git status --short", "touch generated", command + "; touch generated"):
                    self.assertIn(self.hook(provider, "pre-tool-use.sh", cmd)["decision"], {"block", "deny"})
                self.assertEqual(self.state(provider, "claim", provider, "fixture", "task-a", check=False), "")
                # An async answer can explicitly bind, without claiming a different task.
                self.run_command(["bash", "-c", self.action(provider, "bind")], provider)
                self.assertEqual(self.state(provider, "resolve", provider, "fixture"), str(self.plan))
                self.hook(provider, "user-prompt-submit.sh")
                self.assertEqual(self.state(provider, "pending-candidate", provider, "fixture"), "task-a")
                self.assertIn(self.hook(provider, "pre-tool-use.sh")["decision"], {"block", "deny"})
                self.run_command(["bash", "-c", self.action(provider, "release")], provider)
                self.assertEqual((self.project / ".plan-files").read_text(), "")
                (self.project / ".plan-files").write_text("task-a\n")

    def test_maintenance_and_workflow_question(self):
        (self.plan / "handoff.md").write_text("old handoff\n" * 62)
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "claim", provider, "fixture", "task-a")
                for cmd in ("git status --short", "rg -n redirect .", "cd . && cat README.md",
                            f'python3 helper.py --plan "{self.tasks}"'):
                    self.assertNotIn(self.hook(provider, "pre-tool-use.sh", cmd).get("decision"), {"block", "deny"})
                for cmd in ("touch outside", "python3 unknown.py"):
                    self.assertIn(self.hook(provider, "pre-tool-use.sh", cmd)["decision"], {"block", "deny"})
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", tool="ask_user_question").get("decision"), {"block", "deny"})
                # An explicit meta-only turn may stop without claiming completion.
                command = self.action(provider, "bind").replace(" bind task-a", " discuss task-a")
                self.assertIn(command, self.hook(provider, "pre-tool-use.sh", "touch outside")["reason"])
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", command).get("decision"), {"block", "deny"})
                self.run_command(["bash", "-c", command], provider)
                self.assertEqual(self.hook(provider, "agent-stop.sh"), {})
                self.assertEqual(self.hook(provider, "post-tool-use.sh"), {})
                self.assertIn("[ ] [P1.1]", self.tasks.read_text())
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh").get("decision"), {"block", "deny"})
                self.assertIn(self.hook(provider, "pre-tool-use.sh", "touch outside")["decision"], {"block", "deny"})
                self.hook(provider, "user-prompt-submit.sh")
                self.assertEqual(self.state(provider, "pending-candidate", provider, "fixture"), "task-a")

    def test_unstarted_plan_is_restorable_but_cannot_execute(self):
        self.tasks.write_text(self.tasks.read_text().replace("\nPhase 1\n", "\n")
                              .replace("\nP1.1\n", "\n").replace("Status:** in_progress", "Status:** pending"))
        restored = json.loads(self.run_command(
            ["python3", str(SCRIPTS / "plan_state.py"), "restore-check", str(self.tasks)], "codex").stdout)
        self.assertTrue(restored["ok"])
        self.assertTrue(restored["discussion_mode"])
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "claim", provider, "fixture", "task-a")
                self.assertEqual(self.hook(provider, "agent-stop.sh"), {})
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh").get("decision"), {"block", "deny"})
                self.assertIn(self.hook(provider, "pre-tool-use.sh", "touch outside")["decision"], {"block", "deny"})

    def test_research_implementation_discussion_resume(self):
        provider = "grok"
        # Turn 1: research proposal is owned and may be discussed.
        original = self.tasks.read_text()
        self.tasks.write_text(original.replace("\nPhase 1\n", "\n")
                              .replace("\nP1.1\n", "\n").replace("Status:** in_progress", "Status:** pending"))
        self.state(provider, "claim", provider, "fixture", "task-a")
        self.assertEqual(self.hook(provider, "agent-stop.sh"), {})
        # Turn 2: user authorizes implementing the SAME plan after lead answers.
        self.hook(provider, "user-prompt-submit.sh")
        denial = self.hook(provider, "pre-tool-use.sh", "touch implementation")
        self.assertIn("even after research", denial["reason"])
        self.run_command(["bash", "-c", self.action(provider, "bind")], provider)
        # Simulate the agent recording the new authorization under ownership.
        (self.plan / "decisions.md").write_text("## Active Decisions\n- User authorized implementation after lead answers.\n")
        self.tasks.write_text(original.replace("Research and implementation proposal", "Implemented branded links")
                              .replace("implementation until user authorization", "unrelated features"))
        self.assertNotIn(self.hook(provider, "pre-tool-use.sh", "touch implementation").get("decision"), {"block", "deny"})
        # Turn 3: workflow question with an oversized handoff; no implementation.
        (self.plan / "handoff.md").write_text("old handoff\n" * 62)
        self.hook(provider, "user-prompt-submit.sh")
        self.run_command(["bash", "-c", self.action(provider, "bind")], provider)
        command = self.action(provider, "bind").replace(" bind task-a", " discuss task-a")
        self.run_command(["bash", "-c", command], provider)
        self.assertNotIn(self.hook(provider, "pre-tool-use.sh").get("decision"), {"block", "deny"})
        self.assertEqual(self.hook(provider, "agent-stop.sh"), {})
        # Turn 4: resume and repair stale handoff before completing the same item.
        self.hook(provider, "user-prompt-submit.sh")
        self.run_command(["bash", "-c", self.action(provider, "bind")], provider)
        self.assertIn(self.hook(provider, "pre-tool-use.sh", "touch implementation")["decision"], {"block", "deny"})
        (self.plan / "handoff.md").unlink()
        self.assertNotIn(self.hook(provider, "pre-tool-use.sh", "touch implementation").get("decision"), {"block", "deny"})
        self.run_command(["python3", str(SCRIPTS / "plan_checkpoint.py"), "--plan", str(self.tasks),
                          "complete", "P1.1", "--evidence", "redirect verified", "--deactivate-pointer"], provider)
        self.assertEqual(self.hook(provider, "agent-stop.sh"), {})
        self.assertEqual(self.state(provider, "resolve", provider, "fixture", check=False), "")
        self.assertEqual((self.project / ".plan-files").read_text(), "")

    def test_feedback_path_allows_any_tool_and_is_session_scoped(self):
        self.state("grok", "pending", "grok", "fixture", "task-a")
        denial = self.hook("grok", "pre-tool-use.sh", expand=False)
        path = Path(self.state("grok", "feedback-file", "grok", "fixture"))
        self.assertIn(str(path), denial["reason"][:256])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        original = path.read_text()
        for tool, args in (
            ("Read", {"file_path": str(path)}),
            ("mcp__reader__open_document", {"options": [None, {"source": str(path)}]}),
            ("arbitrary_tool", {"query": f"please inspect {path} now"}),
            ("write_file", {"note": str(path), "file_path": "outside.py"}),
            ("run_terminal_cmd", {"command": f"cat {path}; touch outside.py"}),
        ):
            # Per user contract, inclusion permits the entire call regardless
            # of tool name, apparent effect, or other arguments. Do not execute it.
            result = self.hook("grok", "pre-tool-use.sh", tool=tool, tool_input=args, expand=False)
            self.assertEqual(result["decision"], "allow")
        self.assertEqual(path.read_text(), original)
        self.assertEqual(self.state("grok", "resolve", "grok", "fixture", check=False), "")
        self.assertEqual(self.state("grok", "pending-candidate", "grok", "fixture"), "task-a")
        foreign = self.state("grok", "feedback-file", "grok", "another-session")
        self.assertIn(self.hook("grok", "pre-tool-use.sh", tool="Read",
                               tool_input={"file_path": foreign}, expand=False)["decision"], {"block", "deny"})
        # A prompt transition removes the prior exception even for the same task.
        self.hook("grok", "user-prompt-submit.sh")
        self.assertFalse(path.exists())
        self.assertEqual(self.hook("grok", "pre-tool-use.sh", tool="Read",
                                   tool_input={"file_path": str(path)}, expand=False)["decision"], "deny")


if __name__ == "__main__":
    unittest.main()
