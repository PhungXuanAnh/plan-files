"""Cross-provider ownership recovery and maintenance behavior, in isolated roots."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time
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

    def test_session_writes_add_local_git_excludes(self):
        git_dir = self.project / ".git"
        for provider in ADAPTERS:
            self.state(provider, "pending", provider, "fixture")
        self.assertFalse(git_dir.exists())
        git_dir.write_text("gitdir: elsewhere\n")
        self.state("codex", "pending", "codex", "fixture")
        self.assertEqual(git_dir.read_text(), "gitdir: elsewhere\n")
        git_dir.unlink()
        self.run_command(["git", "init", "-q"], "codex")
        exclude = git_dir / "info/exclude"
        for initial in (None, "# existing rule\ncustom", "tmp/*\n# keep\n"):
            with self.subTest(initial=initial):
                if initial is None:
                    exclude.unlink()
                else:
                    exclude.write_text(initial)
                for provider in ADAPTERS:
                    for _ in range(2):
                        self.hook(provider, "user-prompt-submit.sh")
                content = exclude.read_text()
                self.assertTrue(content.startswith(initial or ""))
                for pattern in ("tmp/*", ".plan-files"):
                    self.assertEqual(content.splitlines().count(pattern), 1)
                ignored = self.run_command(
                    ["git", "check-ignore", "tmp/plan-files/task-a/tasks.md", ".plan-files"],
                    "codex").stdout.splitlines()
                self.assertEqual(ignored, ["tmp/plan-files/task-a/tasks.md", ".plan-files"])

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

    def test_routing_command_survives_read_only_decoration(self):
        """The prescribed command plus a pipe or an appended read is the same action.

        Byte-exact comparison refused `bind task-a 2>&1 | tail -3`, the dropped
        env prefix, and the adapter reached through a symlink, then answered
        every retry with the identical instruction -- a loop the agent left only
        by accident. Chaining real work onto the routing command stays refused.
        """
        alias = self.project / "alias-scripts"
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "pending", provider, "fixture", "task-a")
                command = self.action(provider, "bind")
                script = str(ADAPTERS[provider] / "bind-session.sh")
                alias.unlink(missing_ok=True)
                alias.symlink_to(ADAPTERS[provider])
                accepted = (
                    f"{command} 2>&1 | head -3",
                    f'{command} 2>&1 | tail -2; echo "pointer=$(cat {shlex.quote(str(self.project / ".plan-files"))})"',
                    "bash " + command.split(" bash ", 1)[1],
                    command.replace(script, shlex.quote(str(alias / "bind-session.sh"))) + " 2>&1 | tail -2",
                )
                for variant in accepted:
                    self.assertNotIn(self.hook(provider, "pre-tool-use.sh", variant).get("decision"),
                                     {"block", "deny"}, variant)
                refused = (
                    f"rm -rf {shlex.quote(str(self.project / 'src'))} && {command}",
                    command.replace("task-a", "task-b"),
                    f"{command} > {shlex.quote(str(self.project / 'out.txt'))}",
                )
                for variant in refused:
                    self.assertIn(self.hook(provider, "pre-tool-use.sh", variant).get("decision"),
                                  {"block", "deny"}, variant)
                # Recognition is worth nothing unless the decorated command it
                # admits also resolves ownership when the agent runs it.
                self.run_command(["bash", "-c", accepted[0]], provider)
                self.assertEqual(self.state(provider, "resolve", provider, "fixture"), str(self.plan))
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh").get("decision"), {"block", "deny"})
                # The owned-plan discussion check reads the same recognizer.
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh",
                                           f'{self.action(provider, "discuss")} 2>&1 | tail -1').get("decision"),
                                 {"block", "deny"})

    def discuss(self, provider):
        """Put this provider's session into the discussing lease."""
        self.own(provider)
        self.run_command(["bash", "-c", self.action(provider, "discuss")], provider)
        self.assertEqual(self.state(provider, "route-status", provider, "fixture"), "discussing")

    def test_env_prefixed_reads_and_help_probes_are_recognized(self):
        """What a gate calls read-only decides what every gated state refuses.

        Reading argv[0] as the executable made `PLANE_INSECURE=1 cat file`
        unclassifiable, and a read tool whose name carries its verb anywhere but
        the front (`jira_search`) was refused for its name alone. Both were
        blocked in the one lease that exists to allow reads.
        """
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.discuss(provider)
                for command in (f"PLANE_INSECURE=1 cat {shlex.quote(str(self.tasks))}",
                                f"env FOO=1 grep -c Goal {shlex.quote(str(self.tasks))}"):
                    self.assertNotIn(self.hook(provider, "pre-tool-use.sh", command).get("decision"),
                                     {"block", "deny"}, command)
                # An env prefix must not launder a write into a read either.
                self.assertIn(self.hook(provider, "pre-tool-use.sh",
                                        f"FOO=1 rm -rf {shlex.quote(str(self.project / 'src'))}").get("decision"),
                              {"block", "deny"})
                for tool, allowed in (("mcp__jira__jira_search", True),
                                      ("mcp__serena__find_symbol", True),
                                      ("mcp__github__create_issue", False),
                                      ("mcp__x__search_and_replace", False)):
                    decision = self.hook(provider, "pre-tool-use.sh", tool=tool,
                                         tool_input={"query": "x"}).get("decision")
                    if allowed:
                        self.assertNotIn(decision, {"block", "deny"}, tool)
                    else:
                        self.assertIn(decision, {"block", "deny"}, tool)
                # A help probe on a planning helper is read-only, so it may ride
                # along with the routing command the gate itself prescribes.
                self.state(provider, "pending", provider, "fixture", "task-a")
                helper = shlex.quote(str(SCRIPTS / "plan_edit.py"))
                probe = f'{self.action(provider, "bind")}; python3 {helper} handoff-write --help'
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", probe).get("decision"),
                                 {"block", "deny"}, probe)

    def test_discussion_records_but_does_not_advance(self):
        """The discussing lease protects execution state, not the filesystem.

        It used to be the reverse of that: a checkbox tick, a checkpoint and a
        full tasks.md rewrite all passed, while the read-only API query needed to
        answer the very question under discussion was refused. Recording is the
        product of a discussion turn and must pass; advancing waits for a bind.
        """
        edit = shlex.quote(str(SCRIPTS / "plan_edit.py"))
        state = shlex.quote(str(SCRIPTS / "plan_state.py"))
        checkpoint = shlex.quote(str(SCRIPTS / "plan_checkpoint.py"))
        plan = shlex.quote(str(self.tasks))
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.discuss(provider)
                recorded = [
                    ("Write", {"file_path": str(self.plan / "decisions.md"), "content": "- decided\n"}),
                    ("Write", {"file_path": str(self.plan / "findings.md"), "content": "- found\n"}),
                    ("Write", {"file_path": str(self.project / "report.md"), "content": "answer\n"}),
                    ("Bash", {"command": f"python3 {state} overview {plan}"}),
                    ("Bash", {"command": f"python3 {edit} --plan {plan} --expected-fingerprint abc "
                                         f"entry-append --file decisions.md --heading 'Active Decisions' --entry 'x'"}),
                    ("Bash", {"command": f"python3 {edit} --plan {plan} --expected-fingerprint abc "
                                         f"--dry-run phase-update 1 --status complete"}),
                    ("Bash", {"command": 'curl -sS "https://example.com/api/tasks"'}),
                    ("Bash", {"command": f"PLANE_INSECURE=1 {shlex.quote(str(self.project / 'get-task.sh'))} 'per_page=100'"}),
                    ("mcp__plane__plane_search", {"query": "rds"}),
                ]
                for tool, tool_input in recorded:
                    self.assertNotIn(self.hook(provider, "pre-tool-use.sh", tool=tool,
                                               tool_input=tool_input).get("decision"),
                                     {"block", "deny"}, tool_input)
                advanced = [
                    ("Write", {"file_path": str(self.tasks), "content": "# rewritten\n"}),
                    ("Edit", {"file_path": str(self.tasks), "old_string": "- [ ] [P1.1]",
                              "new_string": "- [x] [P1.1]"}),
                    ("Write", {"file_path": str(self.plan / "handoff.md"), "content": "paused\n"}),
                    ("Bash", {"command": f"python3 {checkpoint} --plan {plan} complete P1.1 --evidence x"}),
                    ("Bash", {"command": f"python3 {edit} --plan {plan} --expected-fingerprint abc "
                                         f"phase-update 1 --status complete"}),
                    ("Bash", {"command": f"python3 {edit} --plan {plan} --expected-fingerprint abc "
                                         f"entry-append --file tasks.md --heading Verification --entry 'x'"}),
                    ("Bash", {"command": f"sed -i s/a/b/ {plan}"}),
                ]
                for tool, tool_input in advanced:
                    result = self.hook(provider, "pre-tool-use.sh", tool=tool, tool_input=tool_input)
                    self.assertIn(result.get("decision"), {"block", "deny"}, tool_input)
                    # The denial has to name the recording it wants instead.
                    self.assertIn("entry-append", result.get("reason", ""), tool_input)
                # Destructive and unlocatable writes stay refused as before.
                for tool, tool_input in (
                    ("Bash", {"command": f"rm -rf {shlex.quote(str(self.project / 'src'))}"}),
                    ("Bash", {"command": f"curl -sS https://example.com > {shlex.quote(str(self.project / 'out.json'))}"}),
                    ("mcp__plane__create_issue", {"title": "x"}),
                ):
                    self.assertIn(self.hook(provider, "pre-tool-use.sh", tool=tool,
                                            tool_input=tool_input).get("decision"),
                                  {"block", "deny"}, tool_input)

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
            healthy = [self.hook(provider, "post-tool-use.sh").get("additionalContext", "") for _ in range(2)]
            # Removing an invalid hidden heading need not change the semantic
            # fingerprint; an already delivered healthy reminder can stay quiet.
            self.assertEqual(healthy[1], "")
            self.assertNotIn("FORMAT CONTRACT VIOLATION", healthy[0])
            # Companion state is rechecked even without a tasks.md change.
            findings = self.plan / "findings.md"
            saved = findings.read_text()
            findings.write_text("## Current Summary\n-\n")
            for _ in range(2):
                self.assertIn("RESTORE STATE ACTION REQUIRED", self.hook(provider, "post-tool-use.sh")["additionalContext"])
            findings.write_text(saved)
            self.assertNotIn("RESTORE STATE ACTION REQUIRED", self.hook(provider, "post-tool-use.sh").get("additionalContext", ""))

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
                # The plan stays gated. A write outside every plan does not,
                # whether or not the gate can locate it: refusing the shell form
                # of a write the Write tool may perform is the asymmetry this
                # lease carried, and it cost read-only diagnosis. Recognizable
                # destruction is still refused.
                self.assertIn(self.hook(provider, "pre-tool-use.sh", tool="Write",
                                        tool_input={"file_path": str(other / "tasks.md"), "content": "x"}
                                        )["decision"], {"block", "deny"})
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh",
                                           "python3 -c 'open(\"/tmp/x\",\"w\")'").get("decision"),
                                 {"block", "deny"})
                self.assertIn(self.hook(provider, "pre-tool-use.sh",
                                        f"rm -rf {shlex.quote(str(self.project / 'src'))}")["decision"],
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
        # A repair is not a carrier: the chained command runs too, so the whole
        # call must fail rather than pass on the strength of one good segment.
        chained_after = f"{repair} && rm -rf {shlex.quote(str(outside))}"
        chained_before = f"rm -rf {shlex.quote(str(outside))} && {repair}"
        # A repair may compute an argument, but the substituted command runs
        # too, so it faces the same read-only test as any other segment.
        editor = shlex.quote(str(SCRIPTS / "plan_edit.py"))
        tasks = shlex.quote(str(self.tasks))
        computed = (f"python3 {editor} --plan {tasks} --expected-fingerprint "
                    f"\"$(sha256sum {tasks} | cut -d' ' -f1)\" phase-update 1 --status complete")
        substituted = (f"python3 {editor} --plan {tasks} --expected-fingerprint x "
                       f"phase-update 1 --title $(rm -rf {shlex.quote(str(outside))})")
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.state(provider, "pending", provider, "fixture", "task-a")
                self.assertIn(self.hook(provider, "pre-tool-use.sh", laundered)["decision"],
                              {"block", "deny"})
                self.assertEqual(self.state(provider, "route-status", provider, "fixture"), "pending",
                                 "a blocked mutation must not resolve ownership as a side effect")
                self.own(provider)
                self.run_command(["bash", "-c", self.action(provider, "discuss")], provider)
                for blocked in (chained_after, chained_before, substituted):
                    self.assertIn(self.hook(provider, "pre-tool-use.sh", blocked)["decision"],
                                  {"block", "deny"})
                # Under a discussion lease `laundered` writes outside every plan,
                # so it is no longer refused for being unparseable; the pending
                # assertion above is what keeps ownership from being bypassed.
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", laundered).get("decision"),
                                 {"block", "deny"})
                # Reaching into the plan from inside inline code still blocks.
                inline_plan_write = "python3 -c " + shlex.quote(
                    f"from pathlib import Path; Path({str(self.tasks)!r}).write_text('x')")
                self.assertIn(self.hook(provider, "pre-tool-use.sh", inline_plan_write)["decision"],
                              {"block", "deny"})
                # An unparseable tool proves nothing by quoting the plan in prose,
                # while naming it as a whole argument still reads as maintenance.
                self.assertIn(self.hook(provider, "pre-tool-use.sh", tool="mcp__deploy__ship",
                                        tool_input={"environment": "production",
                                                    "note": f"see {self.tasks} for context"}
                                        )["decision"], {"block", "deny"})
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", tool="mcp__plan__annotate",
                                           tool_input={"note": str(self.tasks)}
                                           ).get("decision"), {"block", "deny"})
                # Read-only diagnosis stays available under the lease.
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh",
                                           "grep -n foo bar.py").get("decision"), {"block", "deny"})
        # A genuine repair, and one that computes an argument, must still be
        # recognized as owned-plan maintenance. That is a property of the shared
        # allowance, not of a lease: under a discussion lease these same commands
        # are gated for advancing the plan, which is a different refusal.
        for allowed in (repair, computed, f"{repair} | head -5"):
            self.assertEqual(self.run_command(
                ["python3", str(SCRIPTS / "maintenance-tool-allowed.py"), str(self.plan)],
                "claude", {"tool_name": "Bash", "tool_input": {"command": allowed}},
                check=False).returncode, 0, allowed)

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

    def test_settled_recovery_command_executes_and_advisories_debounce(self):
        """Replay the resume flow with an old deferred phase, in every envelope."""
        original = self.tasks.read_text()
        settled = (original.replace("- [ ] [P1.1]", "- [x] [P1.1]")
                   .replace("Evidence: pending", "Evidence: redirect returned 302")
                   .replace("- **Status:** in_progress", "- **Status:** complete")
                   .replace("## Active Item\nP1.1\n", "## Active Item\n\n")
                   .replace("## Verification", "### Phase 2: Another owner\n"
                            "- [ ] [P2.1] Followup delivered.\n  - Evidence: pending\n"
                            "- **Status:** deferred (user assigned another owner)\n## Verification"))
        decisions = self.plan / "decisions.md"
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.tasks.write_text(settled)
                decisions.write_text("## Active Decisions\n- None.\n")
                (self.project / ".plan-files").write_text("task-a\n")
                self.own(provider)
                first = self.hook(provider, "post-tool-use.sh").get("additionalContext", "")
                self.assertIn("FINALIZATION ACTION REQUIRED", first)
                self.assertEqual(self.hook(provider, "post-tool-use.sh").get("additionalContext", ""), "")
                denied = self.hook(provider, "pre-tool-use.sh", "touch app.py")
                self.assertIn(denied.get("decision"), {"block", "deny"})
                command = re.search(r'python3 .*?--compact .*?--item "<first outcome>"', denied["reason"])[0]
                for key, value in {"phase title": "New request", "ID": "D2",
                                   "what the user authorized": "Verify new redirect", "why": "User request",
                                   "date": "2026-09-08", "first outcome": "New redirect works."}.items():
                    command = command.replace(f"<{key}>", value)
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", command).get("decision"), {"block", "deny"})
                result = json.loads(self.run_command(["bash", "-c", command], provider).stdout)
                self.assertEqual(result["item"], "P3.1")
                self.assertIn("deferred (user assigned another owner)", self.tasks.read_text())
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", "touch app.py").get("decision"), {"block", "deny"})
                self.assertEqual(self.hook(provider, "agent-stop.sh").get("decision"), "block")
                complete = shlex.join(["python3", str(SCRIPTS / "plan_checkpoint.py"), "complete",
                                       "P3.1", "--evidence", "New redirect returned 302", "--deactivate-pointer"])
                self.run_command(["bash", "-c", complete], provider)
                # Real Bash helpers used to count as unknown risk, producing a
                # false reopen demand after completion and each final read.
                checks = [complete,
                          shlex.join(["python3", str(SCRIPTS / "plan_state.py"), "overview", str(self.tasks)]),
                          shlex.join(["python3", str(SCRIPTS / "plan_state.py"), "restore-check", str(self.tasks)]),
                          shlex.join(["python3", str(SCRIPTS / "plan_checkpoint.py"), "--plan", str(self.tasks),
                                      "assert-finalizable", "--project-root", str(self.project)])]
                for check in checks:
                    self.assertEqual(self.hook(provider, "post-tool-use.sh", check).get("additionalContext", ""), "")
                reporter = shlex.join(["python3", str(SCRIPTS / "observe.py"), "--project-root", str(self.project), "--json"])
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", reporter).get("decision"), {"block", "deny"})
                self.assertEqual(json.loads(self.run_command(["bash", "-c", reporter], provider).stdout)["schema_version"], 1)
                self.assertEqual(self.hook(provider, "post-tool-use.sh", reporter).get("additionalContext", ""), "")
                for unsafe in (reporter + " && touch app.py", reporter.replace(str(SCRIPTS / "observe.py"), "./observe.py")):
                    self.assertIn(self.hook(provider, "pre-tool-use.sh", unsafe).get("decision"), {"block", "deny"})
                self.assertNotEqual(self.hook(provider, "agent-stop.sh").get("decision"), "block")

    def test_scoped_compaction_repairs_legacy_findings(self):
        findings = self.plan / "findings.md"
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                findings.write_text("## Current Summary\n- Preserve verification notes.\n"
                                    "## Phase 5 Evidence\n" + "x" * 33000 + "\n")
                self.own(provider)
                opaque = shlex.join(["python3", "-c", "pass", str(findings)])
                denied = self.hook(provider, "pre-tool-use.sh", opaque)
                self.assertIn(denied.get("decision"), {"block", "deny"})
                self.assertIn("native Edit/Write", denied["reason"])
                self.assertIn("even as arguments", denied["reason"])
                archive = f"cat > {shlex.quote(str(self.plan / 'findings-detail.md'))} <<'MD'\nLocal notes\nMD\necho ok"
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", archive).get("decision"), {"block", "deny"})
                self.assertIn(self.hook(provider, "pre-tool-use.sh", archive + "\ntouch app.py").get("decision"), {"block", "deny"})
                command = shlex.join(["python3", str(SCRIPTS / "plan_edit.py"), "--compact",
                                      "--expected-fingerprint", hashlib.sha256(findings.read_bytes()).hexdigest(),
                                      "section-replace", "--file", "findings.md", "--heading", "Phase 5 Evidence",
                                      "--content", "- Legacy notes summarized; verification remains."])
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", command).get("decision"), {"block", "deny"})
                self.assertTrue(json.loads(self.run_command(["bash", "-c", command], provider).stdout)["ok"])
                self.assertNotIn("COMPACTION REQUIRED", self.hook(provider, "post-tool-use.sh", command).get("additionalContext", ""))
                self.assertNotIn(self.hook(provider, "pre-tool-use.sh", "touch app.py").get("decision"), {"block", "deny"})

    def test_unknown_activity_does_not_imply_early_stale_evidence(self):
        for provider in ADAPTERS:
            with self.subTest(provider=provider):
                self.own(provider)
                self.hook(provider, "post-tool-use.sh")
                cache = Path(self.state(provider, "cache", provider, "fixture"))
                baseline = dict(line.split("=", 1) for line in cache.read_text().splitlines())

                def seed(**updates):
                    state = {**baseline, "last_checkpoint_ts": str(int(time.time())), **updates}
                    cache.write_text("".join(f"{key}={value}\n" for key, value in state.items()))

                # The observed unknown / mutation / unknown burst took 35s.
                seed(last_checkpoint_ts=str(int(time.time()) - 35))
                for tool, command in (("opaque_bridge", "query"), ("Bash", "touch result.txt"),
                                      ("opaque_bridge", "query")):
                    context = self.hook(provider, "post-tool-use.sh", command, tool=tool).get("additionalContext", "")
                    self.assertNotIn("STALE ITEM STATE", context)
                    self.assertNotIn("CHECKPOINT REVIEW", context)
                state = dict(line.split("=", 1) for line in cache.read_text().splitlines())
                self.assertEqual((state["unchanged_risk_score"], state["unchanged_unknown_count"]), ("1", "2"))

                # Unknown-only work remains observable after the age limit.
                seed(last_checkpoint_ts=str(int(time.time()) - 181), unchanged_unknown_count="2")
                review = self.hook(provider, "post-tool-use.sh", tool="opaque_bridge").get("additionalContext", "")
                self.assertIn("CHECKPOINT REVIEW", review)
                self.assertNotIn("STALE ITEM STATE", review)
                self.assertNotIn("CHECKPOINT REVIEW", self.hook(provider, "post-tool-use.sh", tool="opaque_bridge").get("additionalContext", ""))
                self.assertIn("STALE ITEM STATE", self.hook(provider, "post-tool-use.sh", "pytest -q", tool="Bash").get("additionalContext", ""))

                # A live pre-upgrade cache cannot retain mixed unknown risk.
                seed(risk_schema="", unchanged_risk_score="7", unchanged_unknown_count="70")
                self.assertNotIn("STALE ITEM STATE", self.hook(provider, "post-tool-use.sh", tool="opaque_bridge").get("additionalContext", ""))
                state = dict(line.split("=", 1) for line in cache.read_text().splitlines())
                self.assertEqual((state["risk_schema"], state["unchanged_risk_score"], state["unchanged_unknown_count"]), ("2", "0", "1"))

                # Likely evidence still triggers early pressure, and Stop gates.
                seed()
                self.hook(provider, "post-tool-use.sh", "pytest -q", tool="Bash")
                self.assertIn("STALE ITEM STATE", self.hook(provider, "post-tool-use.sh", "pytest -q", tool="Bash").get("additionalContext", ""))
                self.assertEqual(self.hook(provider, "agent-stop.sh").get("decision"), "block")

        report = json.loads(self.run_command(["python3", str(SCRIPTS / "observe.py"), "--project-root",
                                              str(self.project), "--json"], "claude").stdout)
        post = report["hooks"]["post_tool"]
        self.assertEqual(post["checkpoint_review_events"], len(ADAPTERS))
        self.assertEqual(post["stale_events"], 2 * len(ADAPTERS))
        self.assertGreaterEqual(post["max_unknown_count"], 3)

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
