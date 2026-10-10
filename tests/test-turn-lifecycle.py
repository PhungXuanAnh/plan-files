"""Execution leases end independently of persistent plan progress and association."""
import json
import os
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills/plan-files/scripts"
sys.path.insert(0, str(SCRIPTS))
from session_state import SessionStore, SessionError, plan_transaction
from session_runtime import begin_tool, end_tool, host_identity, process_identity


class TurnLifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="turn-lifecycle-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = SessionStore(self.root)
        self.directory = self.root / "tmp/plan-files/task-a"
        self.directory.mkdir(parents=True)
        self.plan = self.directory / "plan.md"
        self.plan.write_text("""# Lifecycle
## Goal
Verify transferable task execution.
## Task Identity
- Deliverable: lifecycle fixture
- Anchors: task-a
- Non-goals: production changes
## Current Phase
Phase 1
## Active Item
P1.1
## Workflow Profile
**Profile:** C
## Resume Checkpoint
- **Next action:** Complete P1.1: verify the artifact
- **Blocker:** none
## Phases
### Phase 1: Work
- [ ] [P1.1] Artifact verified.
  - Evidence: pending
- **Status:** in_progress
## Verification
- Check the artifact.
""")
        (self.directory / "decisions.md").write_text("## Active Decisions\n- None.\n")
        (self.directory / "findings.md").write_text("## Current Summary\n- Artifact needs verification.\n")
        (self.root / ".plan-files").touch()

    def row(self, provider, session):
        return self.store.read(self.store.route(provider, session))

    def hook(self, provider, session, name, **extra):
        adapter = ROOT / (".github/hooks/scripts" if provider == "copilot" else f".{provider}/hooks/plan-files/scripts")
        payload = {"session_id": session, "sessionId": session, "reason": "end_turn", **extra}
        if provider == "copilot" and name == "user-prompt-submit.sh":
            name = "user-prompt-transformed.py"
            payload["transformedPrompt"] = payload.get("prompt", "")
        env = {**os.environ, "PWF_PROJECT_ROOT": str(self.root), "PWF_SESSION_ADAPTER": provider,
               "PWF_SESSION_ID": session, "GROK_SESSION_ID": session}
        env.pop("PLANNING_DISABLED", None)
        result = subprocess.run([sys.executable if name.endswith(".py") else "bash", str(adapter / name)], cwd=self.root, env=env,
                                input=json.dumps(payload), text=True, capture_output=True, check=True)
        output = json.loads(result.stdout)
        return output.get("hookSpecificOutput", output)

    def pause(self):
        self.plan.write_text(self.plan.read_text().replace("## Active Item\nP1.1", "## Active Item\n")
                             .replace("Status:** in_progress", "Status:** deferred (user postponed)"))

    def test_stop_yield_reacquisition_and_stale_events(self):
        for provider in ("codex", "claude", "copilot", "grok"):
            with self.subTest(provider=provider):
                initial = self.plan.read_text()
                self.hook(provider, "a", "user-prompt-submit.sh", prompt=f"Continue {self.plan}.", turn_id="current")
                self.assertEqual(self.row(provider, "a")["candidate"], "task-a")
                self.store.bind(provider, "a", "task-a")
                self.assertEqual(self.hook(provider, "a", "agent-stop.sh", turn_id="previous"), {})
                self.assertEqual(self.row(provider, "a")["status"], "owned")
                self.assertEqual(self.hook(provider, "a", "agent-stop.sh")["decision"], "block")
                self.pause()
                preserved = self.plan.read_bytes()
                self.assertEqual(self.hook(provider, "a", "agent-stop.sh"), {})
                self.assertEqual(self.plan.read_bytes(), preserved)
                self.assertEqual(self.row(provider, "a")["status"], "idle")
                self.assertEqual(self.store.owners("task-a"), [])
                old_generation = self.row(provider, "a")["generation"]
                self.store.bind(provider, "b", "task-a")
                self.assertEqual(self.store.pending(provider, "a"), "task-a")
                with self.assertRaises(SessionError):
                    self.store.bind(provider, "a", "task-a")
                self.store.transition(provider, "b", "handoff", "task-a")
                self.assertIn("deferred", self.store.bind(provider, "a", "task-a"))
                current = self.row(provider, "a")
                self.store.yield_turn(provider, "a", old_generation, ending=True)
                self.assertEqual(self.row(provider, "a"), current)
                self.store.yield_turn(provider, "a", current["generation"], ending=True)
                self.assertEqual(self.store.owners("task-a"), [])
                self.plan.write_text(initial)

    def test_concurrent_discussion_freshness_and_inflight_writes(self):
        for provider in ("codex", "claude", "copilot", "grok"):
            with self.subTest(provider=provider):
                writer, reader = provider + "-writer", provider + "-reader"
                self.store.bind(provider, writer, "task-a")
                self.store.pending(provider, reader, "task-a")
                self.store.transition(provider, reader, "discuss", "task-a")
                self.assertEqual(self.store.resolve(provider, reader), str(self.directory))
                payload = {"tool_name": "Write", "tool_use_id": "write-1",
                           "tool_input": {"file_path": str(self.directory / "findings.md"), "content": "new"}}
                with self.assertRaises(SessionError):
                    begin_tool(self.store, provider, reader, payload)
                self.store.transition(provider, writer, "handoff", "task-a")
                begin_tool(self.store, provider, reader, payload)
                self.assertEqual(self.hook(provider, reader, "agent-stop.sh")["decision"], "block")
                end_tool(self.store, provider, reader, payload)
                self.assertEqual(self.hook(provider, reader, "agent-stop.sh"), {})
                with patch.dict(os.environ, {"PWF_PROJECT_ROOT": str(self.root), "PWF_SESSION_ADAPTER": provider, "PWF_SESSION_ID": reader}):
                    with self.assertRaises(SessionError):
                        with plan_transaction(self.plan):
                            self.fail("yielded authority allowed a write")
                self.store.bind(provider, reader, "task-a")
                findings = self.directory / "findings.md"
                findings.write_text(findings.read_text() + "Updated by another writer.\n")
                with self.assertRaisesRegex(SessionError, "changed since"):
                    begin_tool(self.store, provider, reader, payload)
                with self.store.lock():
                    self.store.remember_read(self.store.route(provider, reader), "task-a")
                begin_tool(self.store, provider, reader, payload)
                end_tool(self.store, provider, reader, payload)
                self.store.transition(provider, reader, "handoff", "task-a")

    def test_session_end_and_verified_dead_runtime_recovery(self):
        for provider in ("codex", "claude", "copilot", "grok"):
            with self.subTest(provider=provider):
                self.store.bind(provider, "closing", "task-a")
                before = self.plan.read_bytes()
                event = "agent-stop.sh" if provider == "grok" else "session-end.sh"
                if provider != "grok":
                    self.hook(provider, "closing", event, timestamp="2000-01-01T00:00:00Z")
                    self.assertTrue(self.store.owners("task-a"), "old SessionEnd released new authority")
                self.assertEqual(self.hook(provider, "closing", event, reason="shutdown"), {})
                self.assertEqual(self.store.owners("task-a"), [])
                self.assertEqual(self.plan.read_bytes(), before)
                self.assertEqual(self.store.pending(provider, "closing"), "task-a")
        machine, boot = host_identity()
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        self.addCleanup(lambda: child.poll() is None and child.kill())
        start, _ = process_identity(child.pid)
        self.store.bind("codex", "crashed", "task-a")
        file = self.store.route("codex", "crashed")
        with self.store.lock():
            self.store.write(file, "owned", task="task-a", runtime=f"{machine}:{boot}:{child.pid}:{start}")
        with self.assertRaises(SessionError):
            self.store.bind("claude", "receiver", "task-a")
        child.terminate(); child.wait()
        self.store.bind("claude", "receiver", "task-a")
        self.assertEqual(self.store.owners("task-a"), [self.store.route("claude", "receiver")])

    def test_anonymous_failures_legacy_age_and_orphan_reclaim(self):
        self.store.bind("copilot", "writer", "task-a")
        file = self.store.route("copilot", "writer")
        payload = {"tool_name": "Write", "timestamp": "2026-10-10T00:00:00Z",
                   "tool_input": {"file_path": str(self.directory / "findings.md"), "content": "record"}}
        for _ in range(2):
            begin_tool(self.store, "copilot", "writer", payload)
        self.pause()
        end_tool(self.store, "copilot", "writer", payload)
        self.assertEqual(self.hook("copilot", "writer", "agent-stop.sh")["decision"], "block")
        self.hook("copilot", "writer", "post-tool-use.sh", **payload, hook_event_name="PostToolUseFailure")
        self.assertEqual(self.hook("copilot", "writer", "agent-stop.sh"), {})
        self.store.bind("codex", "legacy", "task-a")
        legacy = self.store.route("codex", "legacy")
        legacy.write_text("schema=2\nstatus=owned\ntask=task-a\ngeneration=" + "a" * 32 + "\n")
        os.utime(legacy, (0, 0))
        with self.assertRaises(SessionError):
            self.store.bind("claude", "receiver", "task-a")
        self.store.reclaim("claude", "receiver", "task-a", "user confirmed writers stopped")
        payload.update(tool_use_id="orphan")
        begin_tool(self.store, "claude", "receiver", payload)
        generation = self.row("claude", "receiver")["generation"]
        self.store.reclaim("claude", "receiver", "task-a", "user confirmed orphan tool stopped")
        self.assertFalse(self.store.busy(self.store.route("claude", "receiver")))
        self.store.yield_turn("claude", "receiver", generation, ending=True)
        self.assertEqual(self.row("claude", "receiver")["status"], "owned")
        payload.update(tool_use_id="denied")
        begin_tool(self.store, "claude", "receiver", payload)
        self.assertEqual(self.hook("claude", "receiver", "post-tool-use.sh", **payload,
                                   hook_event_name="PermissionDenied"), {})
        self.assertFalse(self.store.busy(self.store.route("claude", "receiver")))

    def test_native_background_results_hold_authority_until_collected(self):
        self.store.bind("codex", "writer", "task-a")
        file = self.store.route("codex", "writer")
        command = {"tool_name": "exec_command", "tool_use_id": "launch",
                   "tool_input": {"cmd": "python3 build.py"}}
        begin_tool(self.store, "codex", "writer", command)
        end_tool(self.store, "codex", "writer", {**command, "tool_response": {"session_id": 42, "output": "building; Exit code: 0"}})
        self.assertTrue(self.store.busy(file))
        with self.assertRaises(SessionError):
            self.store.transition("codex", "writer", "handoff", "task-a")
        poll = {"tool_name": "write_stdin", "tool_use_id": "poll", "tool_input": {"session_id": 42}}
        begin_tool(self.store, "codex", "writer", poll)
        end_tool(self.store, "codex", "writer", {**poll, "tool_response": {"exit_code": 0, "output": "built"}})
        self.assertFalse(self.store.busy(file))

        with self.assertRaisesRegex(SessionError, "untracked shell detachment"):
            begin_tool(self.store, "codex", "writer", {**command, "tool_input": {"cmd": "python3 build.py &"}})
        command.update(tool_name="Bash", tool_use_id="claude-launch")
        begin_tool(self.store, "codex", "writer", command)
        end_tool(self.store, "codex", "writer", {**command, "tool_response": {"backgroundTaskId": "background-job"}})
        self.assertTrue(self.store.busy(file))
        poll = {"tool_name": "TaskOutput", "tool_use_id": "claude-poll", "tool_input": {"task_id": "background-job"}}
        begin_tool(self.store, "codex", "writer", poll)
        end_tool(self.store, "codex", "writer", {**poll, "tool_response": {"task": {"status": "completed", "exitCode": 0}}})
        self.assertFalse(self.store.busy(file))

        # Modern Claude sends automatic completion prompts instead of TaskOutput.
        self.store.transition("codex", "writer", "handoff", "task-a")
        self.store.bind("claude", "writer", "task-a")

        file = self.store.route("claude", "writer")
        begin_tool(self.store, "claude", "writer", command)
        end_tool(self.store, "claude", "writer", {**command, "tool_response": {"backgroundTaskId": "job"}})
        self.store.pending("claude", "writer", "task-a")
        with self.assertRaisesRegex(SessionError, "unfinished"):
            self.store.bind("claude", "writer", "task-a")
        for registry in (None, [{"id": "job", "type": "shell", "status": "running"}]):
            self.hook("claude", "writer", "agent-stop.sh", background_tasks=registry)
            self.assertTrue(self.store.busy(file))
        self.hook("claude", "writer", "agent-stop.sh", background_tasks=[])
        self.assertFalse(self.store.busy(file))
        self.store.bind("claude", "writer", "task-a")

        # A new user prompt must not block collection of an already-running job.
        self.store.transition("claude", "writer", "handoff", "task-a")
        self.store.bind("copilot", "writer", "task-a")
        file = self.store.route("copilot", "writer")
        command.update(tool_name="Bash", tool_use_id="copilot-launch")
        begin_tool(self.store, "copilot", "writer", command)
        end_tool(self.store, "copilot", "writer", {**command, "tool_response": {"shellId": "job"}})
        self.store.pending("copilot", "writer", "task-a")
        poll = {"tool_name": "read_bash", "tool_use_id": "collect", "tool_input": {"shellId": "job"}}
        unknown = {**poll, "tool_input": {"shellId": "unknown"}}
        self.assertEqual(self.hook("copilot", "writer", "pre-tool-use.sh", **unknown).get("decision"), "block")
        stdin = {**poll, "tool_input": {"shellId": "job", "chars": "run work"}}
        self.assertEqual(self.hook("copilot", "writer", "pre-tool-use.sh", **stdin).get("decision"), "block")
        self.assertNotEqual(self.hook("copilot", "writer", "pre-tool-use.sh", **poll).get("decision"), "block")
        self.hook("copilot", "writer", "post-tool-use.sh", **poll, tool_response={"exitCode": 0})
        self.assertFalse(self.store.busy(file))
        self.assertEqual(self.row("copilot", "writer")["status"], "pending")
        self.store.bind("copilot", "writer", "task-a")

    def test_claude_rejected_calls_reconcile_before_bind_without_clearing_live_work(self):
        import hashlib
        self.store.bind("claude", "writer", "task-a")
        file = self.store.route("claude", "writer")
        payload = {"tool_name": "Bash", "tool_use_id": "denied-by-sibling-hook",
                   "tool_input": {"command": "touch must-not-exist"}}
        begin_tool(self.store, "claude", "writer", payload)
        begin_tool(self.store, "claude", "writer", {**payload, "tool_use_id": "still-running"})
        transcript = self.root / "host.jsonl"
        def result(call, **extra):
            return {"type": "user", "sessionId": "writer", "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": call, "is_error": True,
                 "content": "PreToolUse:Bash hook error: denied by another hook"}]}, **extra}
        # Wrong sessions, quoted JSON, incomplete records, and successful/background
        # responses cannot prove that the in-flight call was rejected.
        rejected = result(payload["tool_use_id"])
        background = result("still-running")
        background["message"]["content"][0].update(is_error=False, content="Background task ID: live-job")
        transcript.write_text(json.dumps(result("still-running", sessionId="someone-else")) + "\n" +
                              json.dumps(result("still-running", isSidechain=True)) + "\n" +
                              json.dumps(background) + "\n" +
                              json.dumps({"type": "user", "sessionId": "writer", "message": {
                                  "role": "user", "content": json.dumps(result("still-running"))}}) + "\n" +
                              json.dumps(rejected))
        self.store.pending("claude", "writer", "task-a")
        hook_args = {"transcript_path": str(transcript), "tool_name": "Bash", "tool_use_id": "bind",
                     "tool_input": {"command": f"PWF_PROJECT_ROOT={self.root} bash {ROOT}/.claude/hooks/plan-files/scripts/bind-session.sh bind task-a"}}
        self.hook("claude", "writer", "pre-tool-use.sh", **hook_args)
        self.assertEqual(len(self.store.tools(file)), 2)
        with transcript.open("a") as stream:
            stream.write("\n")
        self.hook("claude", "writer", "pre-tool-use.sh", **hook_args)
        self.assertEqual(set(self.store.tools(file)), {hashlib.sha256(b"still-running").hexdigest()})
        with self.assertRaisesRegex(SessionError, "unfinished"):
            self.store.bind("claude", "writer", "task-a")
        end_tool(self.store, "claude", "writer", {**payload, "tool_use_id": "still-running"})
        self.store.bind("claude", "writer", "task-a")
        self.assertEqual(self.row("claude", "writer")["status"], "owned")

        # A missed terminal error can be repaired at Stop, but missing evidence
        # and genuine background receipts must keep the reservation.
        begin_tool(self.store, "claude", "writer", {**payload, "tool_use_id": "failed"})
        begin_tool(self.store, "claude", "writer", {**payload, "tool_use_id": "launched"})
        end_tool(self.store, "claude", "writer", {**payload, "tool_use_id": "launched",
                                                 "tool_response": {"backgroundTaskId": "live-job"}})
        self.pause()
        self.hook("claude", "writer", "agent-stop.sh", transcript_path=str(self.root / "missing.jsonl"))
        self.assertEqual(len(self.store.tools(file)), 2)
        with transcript.open("a") as stream:
            stream.write(json.dumps(result("failed")) + "\n")
        self.hook("claude", "writer", "agent-stop.sh", transcript_path=str(transcript))
        self.assertEqual(len(self.store.tools(file)), 1)
        self.assertTrue(self.store.owners("task-a"))
        self.assertEqual(self.hook("claude", "writer", "agent-stop.sh", transcript_path=str(transcript),
                                  background_tasks=[]), {})
        self.assertFalse(self.store.owners("task-a"))

    def test_terminal_error_reconciliation_keeps_new_generations_and_bounds_reads(self):
        import hashlib
        from session_runtime import reconcile_tool_results
        from tool_results import terminal_error_keys
        self.store.bind("claude", "writer", "task-a")
        file = self.store.route("claude", "writer")
        payload = {"tool_name": "Bash", "tool_use_id": "same-id", "tool_input": {"command": "touch file"},
                   "transcript_path": str(self.root / "host.jsonl")}
        begin_tool(self.store, "claude", "writer", payload)
        key = hashlib.sha256(b"same-id").hexdigest()
        def new_generation(*args):
            self.store.reclaim("claude", "writer", "task-a", "fixture verifies generation fencing")
            begin_tool(self.store, "claude", "writer", payload)
            return {key}
        with patch("tool_results.terminal_error_keys", side_effect=new_generation):
            reconcile_tool_results(self.store, "claude", "writer", payload)
        self.assertEqual(self.store.tools(file)[key], self.row("claude", "writer")["generation"])
        record = {"type": "user", "sessionId": "writer", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "same-id", "is_error": True}]}}
        line = json.dumps(record) + "\n"
        transcript = Path(payload["transcript_path"])
        transcript.write_text(line + 'x' * 2000 + '\n' + line + '{broken}\n')
        with patch("tool_results.TRANSCRIPT_LIMIT", len(line.encode()) + 32):
            self.assertEqual(terminal_error_keys("claude", "writer", str(transcript), {key}), {key})
            self.assertEqual(terminal_error_keys("claude", "other", str(transcript), {key}), set())
            for provider in ("codex", "copilot", "grok"):
                self.assertEqual(terminal_error_keys(provider, "writer", str(transcript), {key}), set())
        # Corruption is preserved for diagnosis; reconciliation must not prevent
        # the normal read-only or deliberate recovery commands from running.
        file.with_suffix(".tools").write_text("{broken")
        reconcile_tool_results(self.store, "claude", "writer", payload)
        self.assertEqual(file.with_suffix(".tools").read_text(), "{broken")
        with self.assertRaisesRegex(SessionError, "invalid tool receipts"):
            self.store.yield_turn("claude", "writer", self.row("claude", "writer")["generation"], ending=True)

    def test_rejected_call_acknowledgement_is_exact_fenced_and_available_before_bind(self):
        from tool_recovery import recover
        for provider in ("codex", "claude", "copilot", "grok"):
            with self.subTest(provider=provider):
                self.store.bind(provider, "writer", "task-a")
                file = self.store.route(provider, "writer")
                command = "printf 'denied > output' > rejected.txt 2>&1"
                call = {"tool_name": "Bash", "tool_use_id": "denied", "tool_input": {"command": command}}
                begin_tool(self.store, provider, "writer", call)
                live = {**call, "tool_use_id": "live", "tool_input": {"command": "sleep 60"}}
                begin_tool(self.store, provider, "writer", live)
                end_tool(self.store, provider, "writer", {**live, "tool_response": {"backgroundTaskId": "job"}})
                self.store.pending(provider, "writer", "task-a")
                before = self.row(provider, "writer")
                token = json.loads(recover(self.store, provider, "writer", "task-a", command))["matches"][0]
                for session, task, text, values in [
                    ("other", "task-a", command, token), ("writer", "task-b", command, token),
                    ("writer", "task-a", command + " ", token),
                    ("writer", "task-a", command, {**token, "generation": "stale"}),
                    ("writer", "task-a", command, {**token, "receipt": "background:job"}),
                ]:
                    with self.assertRaises(SessionError):
                        recover(self.store, provider, session, task, text, **values, reason="native denial received")
                self.assertEqual(len(self.store.tools(file)), 2)
                directory = ".github/hooks/scripts" if provider == "copilot" else f".{provider}/hooks/plan-files/scripts"
                adapter = ROOT / directory / "bind-session.sh"
                argv = ["bash", str(adapter), "ack-rejected", "task-a", "--command", command,
                        "--receipt", token["receipt"], "--generation", token["generation"],
                        "--reason", "native pre-execution rejection received"]
                allowed = self.hook(provider, "writer", "pre-tool-use.sh", tool_name="Bash",
                                    tool_input={"command": shlex.join(argv)})
                self.assertNotIn(allowed.get("decision"), {"block", "deny"})
                for suffix in (" > unapproved.txt", " && touch unapproved.txt"):
                    rejected = self.hook(provider, "writer", "pre-tool-use.sh", tool_name="Bash",
                                         tool_input={"command": shlex.join(argv) + suffix})
                    self.assertIn(rejected.get("decision"), {"block", "deny"})
                env = {**os.environ, "PWF_PROJECT_ROOT": str(self.root), "PWF_SESSION_ADAPTER": provider,
                       "PWF_SESSION_ID": "writer", "CODEX_THREAD_ID": "writer",
                       "CLAUDE_SESSION_ID": "writer", "COPILOT_AGENT_SESSION_ID": "writer", "GROK_SESSION_ID": "writer"}
                result = subprocess.run(argv, cwd=self.root, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["remaining_tools"], 1)
                self.assertEqual(self.row(provider, "writer"), before)
                with self.assertRaises(SessionError):
                    recover(self.store, provider, "writer", "task-a", command, **token, reason="duplicate")
                # Background execution still retains the lease after acknowledgement.
                with self.assertRaises(SessionError):
                    self.store.bind(provider, "writer", "task-a")
                from session_runtime import begin_collection
                collection = {"tool_name": "TaskOutput", "tool_use_id": "collect", "tool_input": {"task_id": "job"}}
                self.assertTrue(begin_collection(self.store, provider, "writer", collection))
                end_tool(self.store, provider, "writer", {**collection, "tool_response": {"status": "completed"}})
                self.store.bind(provider, "writer", "task-a")
                begin_tool(self.store, provider, "writer", call)
                with self.assertRaises(SessionError):
                    recover(self.store, provider, "writer", "task-a", command, **token, reason="old generation")
                fresh = json.loads(recover(self.store, provider, "writer", "task-a", command))["matches"][0]
                begin_tool(self.store, provider, "writer", {**call, "tool_use_id": "duplicate-command"})
                with self.assertRaises(SessionError):
                    recover(self.store, provider, "writer", "task-a", command, **fresh, reason="ambiguous")
                end_tool(self.store, provider, "writer", {**call, "tool_use_id": "duplicate-command"})
                recover(self.store, provider, "writer", "task-a", command, **fresh, reason="native denial received")
                self.store.transition(provider, "writer", "handoff", "task-a")



if __name__ == "__main__":
    unittest.main()
