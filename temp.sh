# shellcheck disable=all

there is one problem with tool call hook, agent commonly call tool in parallel, for example with codex, i saw this log:

```
PostToolUse hook (completed)
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in

• PostToolUse hook (completed)
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in
  your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.
  your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.

• PostToolUse hook (completed)
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in
  your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.

──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
