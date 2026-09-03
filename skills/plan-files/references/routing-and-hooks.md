# Routing and Hook Semantics

Read this reference when resolving a project root, deciding whether a candidate plan belongs to the request, diagnosing session ownership, or comparing provider adapters.

## Project-root resolution

Hooks resolve the project root from the tool call's current directory:

1. Walk upward and collect ancestors containing `.plan-files`, including an empty pointer. The farthest/outermost ancestor wins so cwd drift into a child repository cannot silently select a leftover child plan.
2. Otherwise use `git rev-parse --show-toplevel`, walking through an enclosing superproject when present.
3. Otherwise use the current directory.

In nested repositories, put `.plan-files` at the intended outer workspace root. For a new non-git multi-repo workspace with no pointer yet, create an empty `.plan-files` there before its first task.

## Candidate versus ownership

The root pointer is a human/new-session default, not authority. Session state under `tmp/plan-files/.sessions/` owns routing for a prompt. At most one agent is assumed to work a project at a time.

On a new user prompt, a session-aware hook suspends its prior lease and exposes only candidate Task Identity and Goal. Classify the latest request:

- `SAME`: an explicit resume or matching task id is strong evidence. Run the supplied bind command exactly before reading other plan content.
- `DIFFERENT`: an explicit new/separate request or different id is strong evidence. Release/do not bind; never repair or compact the candidate as part of the new request.
- `AMBIGUOUS`: shared repo, branch, module, or file is only weak evidence. Ask before switching or mutating a task.

Without an ownership hook, inspect only Task Identity and Goal first, apply the same classification, and do not claim session isolation.

## Creation and binding

For a new task, create `tasks.md`, `findings.md`, and `decisions.md` from the templates. PreTool cannot claim a task before `tasks.md` exists; PostTool auto-claims it after creation and synchronizes `.plan-files`. Do not hand-edit the pointer or rerun bind merely for reassurance. An already owned/settled lease can make a redundant bind fail harmlessly; use `resolve` to check ownership.

When no hook supplies a bind command, update `.plan-files` manually. Preserve old task directories when switching.

Stable session identity and binding fail closed. A PreTool ownership response is a required routing action, not an external blocker. Run its exact bind/release command and retry the original tool call. Do not inspect or alter private `.sessions` files to bypass it.

## Resume reads

After binding SAME:

1. Load bounded `plan_state.py overview` and `restore-check`.
2. Follow only the exact `next_read.targets`, active phase/item, decision, and finding sections needed.
3. Read `handoff.md` only when its freshness state is valid.
4. Never auto-read `history.md`; search or open it only through a specific reference.

A direct complete-file read is valid for format repair, compaction judgment, or broad reconciliation.

## Provider contract

Codex, Claude Code, and Copilot reuse canonical shell hook cores for resolver/session integration, common format helpers, semantic stale policy, maintenance gating, telemetry, and Stop finalization. Provider launch shims pass the provider name, session identity, and the small output-envelope differences required by each host. Provider-unique events may keep a local adapter when their input or output contract has no shared counterpart, but that adapter must delegate candidate selection and session state to the canonical scripts.

- PreTool gates ambiguous ownership, invalid item/restore state, and over-budget unrelated mutations while allowing read-only diagnosis and owned-plan repair. It recognizes both from the tool input, never from a tool or script name: a call passes when it is demonstrably read-only, or when its input targets or explicitly names the owned plan directory. A repair/checkpoint command that names no plan path — a bare `--help`, a version probe — is therefore blocked like any other unrecognized call; pass `--plan <plan-dir>/tasks.md` and it is allowed. Every block message states this condition, so treat it as the instruction rather than as a broken gate.
- PostTool injects bounded current context, checkpoint reminders, restore repairs, and compaction warnings. It does not complete items.
- Stop blocks actionable or invalid plans and supplies a continuation instruction.

Set `PLANNING_DISABLED=1` for a single invocation when the user explicitly disables the workflow. `.plan-files-skip` disables it for the resolved project.
