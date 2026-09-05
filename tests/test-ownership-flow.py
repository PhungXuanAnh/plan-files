"""Cross-provider ownership recovery and maintenance behavior, in isolated roots."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills/plan-files/scripts"
# A message that names something to run or read must name where it is; a bare
# basename makes the agent guess a path and then search the filesystem for it.
RUNNABLE_MENTION = re.compile(
    r"\S*(?:plan_state\.py|plan_checkpoint\.py|plan_edit\.py|SKILL\.md|format-contract\.md)")
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

    def own(self, provider, task="task-a"):
        """Claim as a session that has already loaded the skill, the normal case."""
        self.state(provider, "claim", provider, "fixture", task)
        self.state(provider, "skill-loaded", provider, "fixture", "mark")

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
                            f"python3 {shlex.quote(str(SCRIPTS / 'plan_state.py'))} budgets {shlex.quote(str(self.tasks))}"):
                    self.assertNotIn(self.hook(provider, "pre-tool-use.sh", cmd).get("decision"), {"block", "deny"})
                # An arbitrary program that merely names the plan proves nothing
                # about what it writes, so it is not owned-plan maintenance.
                for cmd in ("touch outside", "python3 unknown.py",
                            f'python3 helper.py --plan "{self.tasks}"'):
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
        self.own(provider)
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

    def test_early_integrity_and_persistent_reminders(self):
        original = self.tasks.read_text()
        # Include an uncontracted legacy plan matching the reported failure.
        legacy = original.replace("## Active Item\nP1.1\n", "")
        cases = [
            (legacy.replace("Phase 1\n", "Phase 99\n", 1)
             .replace("**Profile:** C", "**Profile:** [A | B | C]")
             .replace("- **Status:** in_progress", "- **Status:** unknown"), "FORMAT CONTRACT VIOLATION"),
            (original.replace("- **Status:** in_progress", "- **Status:** complete"), "STATUS LIES"),
            (legacy.replace("- [ ] [P1.1]", "- [x] [P1.1]")
             .replace("- **Status:** in_progress", "- **Status:** complete")
             .replace("## Verification", "### Phase 2: More work\n- [ ] More work\n- **Status:** pending\n## Verification"), "STALE '## Current Phase'"),
            (original + "\n### Hidden work\n- [ ] Remaining outcome\n", "NOT a recognized phase heading"),
        ]
        for provider in ADAPTERS:
            self.own(provider)
            for broken, diagnosis in cases:
                with self.subTest(provider=provider, diagnosis=diagnosis):
                    self.tasks.write_text(broken)
                    denied = self.hook(provider, "pre-tool-use.sh", "touch app.py")
                    self.assertIn(denied.get("decision"), {"block", "deny"})
                    self.assertIn(diagnosis, denied["reason"])
                    self.assertNotIn(self.hook(provider, "pre-tool-use.sh").get("decision"), {"block", "deny"})
                    self.assertNotIn(self.hook(provider, "pre-tool-use.sh", tool="Write",
                                             tool_input={"file_path": str(self.tasks), "content": original}).get("decision"), {"block", "deny"})
                    for _ in range(2):
                        context = self.hook(provider, "post-tool-use.sh").get("additionalContext", "")
                        self.assertIn("STOP WILL BLOCK", context)
                        self.assertIn(diagnosis, context)
                    self.assertIn(diagnosis, self.hook(provider, "agent-stop.sh")["reason"])
            self.tasks.write_text(original)
            self.assertNotIn(self.hook(provider, "pre-tool-use.sh", "touch app.py").get("decision"), {"block", "deny"})
            for _ in range(2):
                context = self.hook(provider, "post-tool-use.sh").get("additionalContext", "")
                self.assertIn("actionable phases remain", context)
                self.assertNotIn("FORMAT CONTRACT VIOLATION", context)
            # Companion state is rechecked even without a tasks.md change.
            findings = self.plan / "findings.md"
            saved = findings.read_text()
            findings.write_text("## Current Summary\n-\n")
            for _ in range(2):
                self.assertIn("RESTORE STATE ACTION REQUIRED", self.hook(provider, "post-tool-use.sh")["additionalContext"])
            findings.write_text(saved)
            self.assertNotIn("RESTORE STATE ACTION REQUIRED", self.hook(provider, "post-tool-use.sh")["additionalContext"])

    def test_planning_commands_foreground_only(self):
        import shlex
        command = f"python3 {SCRIPTS / 'plan_state.py'} overview {shlex.quote(str(self.tasks))}"
        for provider in ADAPTERS:
            self.own(provider)
            for key in ("background", "is_background", "run_in_background"):
                with self.subTest(provider=provider, flag=key):
                    args = {"command": command, key: True}
                    self.assertIn("FOREGROUND PLANNING COMMAND REQUIRED", self.hook(provider, "pre-tool-use.sh", tool_input=args)["reason"])
                    self.assertNotIn(self.hook(provider, "pre-tool-use.sh", tool_input={**args, key: False}).get("decision"), {"block", "deny"})
            self.assertIn("FOREGROUND PLANNING COMMAND REQUIRED", self.hook(provider, "pre-tool-use.sh", command + " &")["reason"])
            for other in ("npm test", "python3 app.py --fixture plan_state.py", "echo plan_state.py"):
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", tool_input={"command": other, "background": True}).get("decision"), {"block", "deny"})
            self.assertNotIn(self.hook(provider, "pre-tool-use.sh", tool="get_command_or_subagent_output",
                                      tool_input={"task_id": "already-running", "timeout_ms": 30000}).get("decision"), {"block", "deny"})
            context = self.hook(provider, "post-tool-use.sh", tool_input={"command": command, "background": True})["additionalContext"]
            self.assertIn("do not launch a duplicate", context)

    def test_pure_question_settles_stop_through_offered_verb(self):
        """A question about the plan or the agent's own behavior is not SAME/DIFFERENT/AMBIGUOUS."""
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "pending", provider, "fixture", "task-a")
                blocked = self.hook(provider, "agent-stop.sh")
                self.assertIn("OWNERSHIP ACTION REQUIRED", blocked["reason"])
                # The verb that settles this must be one the message itself offered.
                command = self.action(provider, "discuss")
                self.assertIn(command, blocked["reason"])
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", command).get("decision"),
                                 {"block", "deny"})
                self.run_command(["bash", "-c", command], provider)
                self.assertEqual(self.hook(provider, "agent-stop.sh"), {})
                # Discussion still cannot enable execution, and the candidate survives.
                self.assertIn(self.hook(provider, "pre-tool-use.sh", "touch app.py")["decision"],
                              {"block", "deny"})
                self.assertEqual((self.project / ".plan-files").read_text().strip(), "task-a")

    def test_skill_gate_blocks_mutation_until_read(self):
        skill_md = str(ROOT / "skills/plan-files/SKILL.md")
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "claim", provider, "fixture", "task-a")
                blocked = self.hook(provider, "pre-tool-use.sh", "touch app.py")
                self.assertIn(blocked.get("decision"), {"block", "deny"})
                self.assertIn("SKILL NOT LOADED", blocked["reason"])
                self.assertIn(skill_md, blocked["reason"])
                # A blocked session must keep every route it needs to comply.
                for allowed in ("rg Phase .",
                                f"python3 {shlex.quote(str(SCRIPTS / 'plan_state.py'))} overview {shlex.quote(str(self.tasks))}"):
                    self.assertNotIn(self.hook(provider, "pre-tool-use.sh", allowed).get("decision"),
                                     {"block", "deny"})
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", tool="Read",
                                           tool_input={"file_path": str(ROOT / "wrong/SKILL.md")}
                                           ).get("decision"), {"block", "deny"})
                self.assertIn(self.hook(provider, "pre-tool-use.sh", "touch app.py").get("decision"),
                              {"block", "deny"}, "a wrong-path guess must not satisfy the gate")
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", f"cat {skill_md}").get("decision"),
                                 {"block", "deny"})
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", "touch app.py").get("decision"),
                                 {"block", "deny"}, "one read of the named path must clear the gate")
                self.state(provider, "skill-loaded", provider, "fixture", "clear")

    def test_discussion_allows_the_report_the_user_asked_for(self):
        """A discussion lease protects the plan, not the whole filesystem."""
        report = self.project / "tmp/hook-report.md"
        other = self.project / "tmp/plan-files/task-b"
        other.mkdir(parents=True, exist_ok=True)
        (other / "tasks.md").write_text(self.tasks.read_text())
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.own(provider)
                self.run_command(["bash", "-c", self.action(provider, "discuss")], provider)
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", tool="Write",
                                           tool_input={"file_path": str(report), "content": "x"}
                                           ).get("decision"), {"block", "deny"})
                # The plan itself, and anything whose targets cannot be located,
                # stay gated.
                self.assertIn(self.hook(provider, "pre-tool-use.sh", tool="Write",
                                        tool_input={"file_path": str(other / "tasks.md"), "content": "x"}
                                        )["decision"], {"block", "deny"})
                self.assertIn(self.hook(provider, "pre-tool-use.sh",
                                        "python3 -c 'open(\"/tmp/x\",\"w\")'")["decision"],
                              {"block", "deny"})

    def test_posttool_reminds_unresolved_ownership(self):
        """Silence here hides a guaranteed Stop block until the turn is over."""
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "pending", provider, "fixture", "task-a")
                bind = self.action(provider, "bind")
                for _ in range(2):
                    context = self.hook(provider, "post-tool-use.sh").get("additionalContext", "")
                    self.assertIn("ownership is unresolved", context)
                    self.assertIn(bind, context, "PostTool must repeat the runnable routing actions")
                self.assertIn("OWNERSHIP ACTION REQUIRED",
                              self.hook(provider, "agent-stop.sh")["reason"])
                self.run_command(["bash", "-c", bind], provider)
                self.assertNotIn("ownership is unresolved",
                                 self.hook(provider, "post-tool-use.sh").get("additionalContext", ""))

    def test_plan_path_mention_cannot_launder_a_shell_mutation(self):
        """A shell command's write targets are unparseable, so naming a plan proves nothing."""
        outside = self.project / "tmp/report.md"
        # Shell-quoted the way a real command must be; the fixture root contains
        # a space and a quote, so an unquoted path is malformed and fails closed.
        laundered = (f"PLAN={shlex.quote(str(self.plan) + '/')} python3 -c "
                     + shlex.quote(f"from pathlib import Path; Path({str(outside)!r}).write_text('x')"))
        repair = (f"python3 {shlex.quote(str(SCRIPTS / 'plan_edit.py'))} --plan {shlex.quote(str(self.tasks))}"
                  " --expected-fingerprint x phase-update 1 --status complete")
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "pending", provider, "fixture", "task-a")
                self.assertIn(self.hook(provider, "pre-tool-use.sh", laundered)["decision"],
                              {"block", "deny"})
                self.assertEqual(self.state(provider, "route-status", provider, "fixture"), "pending",
                                 "a blocked mutation must not resolve ownership as a side effect")
                self.own(provider)
                self.run_command(["bash", "-c", self.action(provider, "discuss")], provider)
                self.assertIn(self.hook(provider, "pre-tool-use.sh", laundered)["decision"],
                              {"block", "deny"})
                # Real repair and read-only diagnosis must stay available.
                for allowed in (repair, "grep -n foo bar.py"):
                    self.assertNotIn(self.hook(provider, "pre-tool-use.sh", allowed).get("decision"),
                                     {"block", "deny"})

    def test_skill_read_before_routing_is_allowed_and_counts(self):
        """Loading the rules first is the correct order and must not be penalized."""
        skill_md = str(ROOT / "skills/plan-files/SKILL.md")
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "pending", provider, "fixture", "task-a")
                self.assertIn("SKILL.md",
                              self.hook(provider, "pre-tool-use.sh")["reason"],
                              "the ownership message must name the skill it expects to be read")
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", f"cat {skill_md}").get("decision"),
                                 {"block", "deny"}, "a skill read precedes routing")
                self.run_command(["bash", "-c", self.action(provider, "bind")], provider)
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", "touch app.py").get("decision"),
                                 {"block", "deny"}, "a read before bind must still count after it")
                self.state(provider, "skill-loaded", provider, "fixture", "clear")
                # Naming the path must not carry an unrelated mutation past a gate.
                self.state(provider, "pending", provider, "fixture", "task-a")
                self.assertIn(self.hook(provider, "pre-tool-use.sh",
                                        f"touch app.py && cat {skill_md}")["decision"], {"block", "deny"})
                self.assertEqual(self.state(provider, "skill-loaded", provider, "fixture", "check",
                                            check=False), "")
                self.state(provider, "skill-loaded", provider, "fixture", "clear")

    def assertRunnablePathsAbsolute(self, text, where):
        for token in RUNNABLE_MENTION.findall(text or ""):
            token = token.strip("'\"`,.;:()[]")
            self.assertTrue(token.startswith("/"),
                            f"{where}: {token!r} named without an absolute path in: {text[:400]}")

    def test_messages_name_absolute_paths(self):
        original = self.tasks.read_text()
        findings = self.plan / "findings.md"
        saved_findings = findings.read_text()
        legacy = original.replace("## Active Item\nP1.1\n", "")
        states = {
            "restore-incomplete": (original, "## Current Summary\n-\n"),
            "profile-unfilled": (original.replace("**Profile:** C", "**Profile:** [A | B | C]"), saved_findings),
            "discussion-mode": (legacy.replace("Phase 1\n", "\n", 1)
                                .replace("- **Status:** in_progress", "- **Status:** pending"), saved_findings),
            "settled-pointer": (original.replace("- [ ] [P1.1]", "- [x] [P1.1]")
                                .replace("Evidence: pending", "Evidence: redirect returned 302")
                                .replace("- **Status:** in_progress", "- **Status:** complete")
                                .replace("## Active Item\nP1.1\n", "## Active Item\n\n"), saved_findings),
            "legacy-uncontracted": (legacy, saved_findings),
        }
        for provider in ADAPTERS:
            self.state(provider, "claim", provider, "fixture", "task-a")
            for label, (plan_text, findings_text) in states.items():
                with self.subTest(provider=provider, state=label):
                    self.tasks.write_text(plan_text)
                    findings.write_text(findings_text)
                    pre = self.hook(provider, "pre-tool-use.sh", "touch app.py")
                    self.assertRunnablePathsAbsolute(pre.get("reason", ""), f"{provider} PreTool {label}")
                    post = self.hook(provider, "post-tool-use.sh")
                    self.assertRunnablePathsAbsolute(post.get("additionalContext", ""),
                                                     f"{provider} PostTool {label}")
                    stop = self.hook(provider, "agent-stop.sh")
                    self.assertRunnablePathsAbsolute(stop.get("reason", ""), f"{provider} Stop {label}")
            self.tasks.write_text(original)
            findings.write_text(saved_findings)


if __name__ == "__main__":
    unittest.main()
