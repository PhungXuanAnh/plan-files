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

• Serena can symbol-read the JSX, but this workspace’s active language server is TypeScript-only, so Python symbol extraction is unavailable. I’m switching to line-numbered reads for the Python files and keeping the reads scoped to the
  commented ranges.

• PostToolUse hook (completed)
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in
  your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.

• PostToolUse hook (completed)
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in
  your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.

• PostToolUse hook (completed)
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in
  your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.

• PostToolUse hook (completed)
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in
  your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.

• PostToolUse hook (completed)
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in
  your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.

• PostToolUse hook (completed)
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in
  your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.

• PostToolUse hook (completed)
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in
  your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.

• PostToolUse hook (completed)
  hook context: [planning-with-files] Update progress.md with what you just did. If a phase is now complete, update tmp/plan-with-files/4606-ui-parity/task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in
  your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.

```
you can see that the hook make context poluted, we need to reduce it, the mechanism is:
when write to context the first time, then we remind again after 30 times of tool call, write the number of tool call to a file in tmp/planning-with-files/tool_call_count.txt, 
and read it when tool call, if the number is more than 30, then we write the hook context again, and reset the number to 0.
what do you think? do you have better solution?


