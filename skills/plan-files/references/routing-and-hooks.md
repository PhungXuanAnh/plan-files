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

- `SAME`: an explicit request to resume/implement the named task is strong evidence, including research → implementation after answers or applying decisions to its handoff. Run the supplied bind command exactly before reading other plan content. A reference to a plan as an example/background does not by itself authorize continuation.
- `DIFFERENT`: an explicit new/separate request or different id is strong evidence. Release/do not bind; never repair or compact the candidate as part of the new request.
- `AMBIGUOUS`: shared repo, branch, module, or file is only weak evidence. Run the supplied `clarify <task-id>` command, then ask before switching or mutating a task. The lease enters `waiting`; Stop allows the question without clearing the candidate/pointer. Only supported question tools and exact routing commands are allowed while waiting. An asynchronous answer may be followed by explicit bind/release; a new prompt restores pending classification automatically.

Without an ownership hook, inspect only Task Identity and Goal first, apply the same classification, and do not claim session isolation.

The new user request can supersede an earlier research-only deliverable or implementation non-goal. This is a scope update within SAME when the user explicitly continues that plan, not a reason to release it. After bind, record the authorization in `decisions.md`, reconcile Goal/Task Identity/Workflow Profile and remaining phases, then implement. Preserve all other non-goals; they are not automatically temporary research constraints.

Binding once per prompt is intentional: UserPromptSubmit suspends the prior lease and PreTool checks that routing has been resolved. These are not two separate binds. A matching `.plan-files` pointer does not preserve old prompt authority. A successful bind remains valid within that prompt; use `resolve`, not repeated bind calls.

## Creation and binding

For a new task, create `tasks.md`, `findings.md`, and `decisions.md` from the templates. PreTool cannot claim a task before `tasks.md` exists; PostTool auto-claims it after creation and synchronizes `.plan-files`. Do not hand-edit the pointer or rerun bind merely for reassurance. An already owned/settled lease can make a redundant bind fail harmlessly; use `resolve` to check ownership.

When no hook supplies a bind command, update `.plan-files` manually. Preserve old task directories when switching.

Stable session identity and binding fail closed. A PreTool ownership response is a required routing action, not an external blocker. Run its exact bind/release command and retry the original tool call. Do not inspect or alter private `.sessions` files to bypass it.

`release` rejects a pending candidate and may clear its root pointer. It is not ordinary end-of-turn cleanup. Stop automatically calls `finish` for fully complete owned plans; blocked/deferred plans retain their resume lease. Pending candidates must be bound, released for DIFFERENT, or explicitly put into clarification wait. PreTool and Stop render the same canonical action-first contract for all four providers.

For an explicitly discussion-only user request about the owned plan or workflow, run the supplied bind command with verb `discuss` instead. This retains the task under a `discussing` lease: PreTool permits questions, read-only diagnosis, and owned-plan maintenance, while gating outside writes and unknown calls. Stop allows the answer and PostTool does not demand execution checkpoints. The next user prompt returns the lease to `pending`; rebind before execution. This is a turn scope, not a completed/blocked/deferred phase. Do not enter it merely to escape maintenance or unfinished authorized work.

Supported question tool names are `AskUserQuestion`, `ask_user_question`, `request_user_input`, and `request_user_input_async`, including MCP and dotted function namespace prefixes. Question tools carry zero semantic risk. In unresolved ownership they are allowed only after explicit `clarify`; plain text questions also work once that transition succeeds.

## Resume reads

After binding SAME:

1. Load bounded `plan_state.py overview` and `restore-check`.
2. Follow only the exact `next_read.targets`, active phase/item, decision, and finding sections needed.
3. Read `handoff.md` only when its freshness state is valid.
4. Never auto-read `history.md`; search or open it only through a specific reference.

A direct complete-file read is valid for format repair, compaction judgment, or broad reconciliation.

## Provider contract

Codex, Claude Code, Copilot, and Grok Build reuse canonical shell hook cores for resolver/session integration, common format helpers, semantic stale policy, maintenance gating, telemetry, and Stop finalization. Provider launch shims pass the provider name, session identity, and the small output-envelope differences required by each host. Provider-unique events may keep a local adapter when their input or output contract has no shared counterpart, but that adapter must delegate candidate selection and session state to the canonical scripts.

- PreTool gates ambiguous ownership, an unloaded skill, invalid format/profile/item/status/restore state (including legacy plans), explicit background planning helpers, and over-budget unrelated mutations while allowing read-only diagnosis and owned-plan repair. It recognizes both from the tool input, never from a tool or script name: a call passes when it is demonstrably read-only, or when its input targets or explicitly names the owned plan directory. A repair/checkpoint command that names no plan path — a bare `--help`, a version probe — is therefore blocked like any other unrecognized call; pass `--plan <plan-dir>/tasks.md` and it is allowed. Every block message states this condition, so treat it as the instruction rather than as a broken gate.
- PostTool repeats the routing actions while ownership is unresolved instead of staying silent, then checks integrity, restore state, and budgets before debounce or the settled-plan fast path. Unresolved diagnostics repeat every call; actionable work gets a short Stop warning every call. Full plan context and evidence reminders retain their debounce. It does not complete items.
- Stop blocks actionable or invalid plans and supplies a continuation instruction.

An unstarted contracted plan (empty Current Phase/Active Item, all phases pending) is restorable discussion state. PreTool still requires starting an Active Item before operational work. Over-budget plans continue to allow questions, recognized reads, and owned-plan repair; a question about an unrelated task does not authorize binding or compacting the candidate.

Grok's native adapter uses provider id `grok` and requires the event envelope's `sessionId` to match the runner-provided `GROK_SESSION_ID`. Its allowing UserPromptSubmit output is not a context channel, so pending PreToolUse and Stop responses repeat bounded candidate identity and exact actions. The adapter translates only PreToolUse `block` to Grok's canonical `deny`; shared Stop `block` is already compatible. It skips the shared Stop core unless `reason == "end_turn"`, because Grok also emits observe-only `shutdown`/`channel_closed` Stop events. PostToolUse side effects are mandatory even when an older Grok release ignores its stdout; newer releases may deliver the emitted `additionalContext`. Grok overrides the Stop gate after eight continuation rounds, but keeps the task lease available for the next prompt.

Set `PLANNING_DISABLED=1` for a single invocation when the user explicitly disables the workflow. `.plan-files-skip` disables it for the resolved project.

Official Grok applies a 256-Unicode-character budget to PreTool denial reasons before model delivery. Its adapter passes this capability to the shared core; `feedback_transport.py` writes longer reasons intact into a mode-600 file under the private mode-700 `/tmp/plan-files-feedback-<uid>/` directory. The short deny advertises that absolute path within the host budget. Names hash the project/provider/session routing scope and contain no raw session id.

The feedback exception is deliberately based on tool arguments, not tool names: any call whose arguments contain the current generated path is allowed in full, including unfamiliar tools, nested values, or additional arguments. Other tool calls retain the normal ownership/restore/maintenance gates. Reading feedback does not confer ownership. A new prompt, bind, clarify, discuss, release, or finish invalidates the previous feedback file. Different projects/providers/sessions cannot use each other's path as an exception. The file contains only the hook's existing trusted recovery message, never arbitrary tool input or hidden session state.

The same core mechanism can serve another adapter with a small reason budget; provider wrappers only declare the capability. Stop can still deliver its full context directly. Grok source is reference-only: the official installed executable needs no modification or rebuild. Tests measure the short delivered reason and the complete recovered instructions separately, including through the unchanged Grok runner.

## Early enforcement and Stop audit

All three events use `planning_integrity_warning` in the canonical core; adapters only render their envelopes. Re-evaluate disk state on each tool event, including companion-file freshness. Repair calls and read-only diagnosis remain available; unrelated operational calls wait until the fault is repaired.

| Condition | PreToolUse | PostToolUse | Stop |
|---|---|---|---|
| Pending ownership | Require a routing verb before work | Repeat the same routing actions every call | Repeat routing actions |
| Malformed sections, phase headings/statuses, Current Phase, missing/unfilled profile | Block operational work, including legacy plans | Repeat bounded repair diagnostics each call | Block with full shared diagnosis |
| Invalid Active Item, ids, evidence | Block operational work | Repeat shared diagnosis | Block |
| Complete phase with unchecked work, stale Current Phase, hidden non-phase work | Block operational work | Repeat shared diagnosis | Block |
| Missing/placeholder resume state, stale handoff/external evidence | Block operational work | Repeat restore repairs each call | Explicit restore-check remains required before final output |
| Hot-state over budget | Block outside writes/unknown calls | Repeat compaction guidance each call | Maintenance remains required by the work loop |
| Valid actionable phases | Allow authorized work | Short Stop warning each call; no repeated full context | Continue remaining work |
| Settled contracted plan with active candidate pointer | Allow cleanup | Repeat finalization/POINTER_ACTIVE reminder | Existing lease settlement behavior is preserved; assert-finalizable remains required |
| Never-started proposal or explicit clarify/discuss lease | Preserve routing/discussion gates | No execution pressure in explicit discussion | Allow discussion without claiming completion |
| Skill never read in this session | Block operational mutation, naming the absolute `SKILL.md` path; allow the read-only skill read in any routing state | Existing reload advisory | No separate Stop condition |

Persistent integrity diagnostics are capped at 3000 characters plus a short repair-read hint; full reasons remain available at Stop. Other warning families are bounded separately. Clearing one fault removes its warning on the next PostTool; other faults still repeat. Pending work is not an invalid state and must never be used to block the tools needed to complete it. Stop remains the final backstop rather than the first diagnosis.

Explicit background flags (`background`, `is_background`, `run_in_background`) or shell detachment are denied for recognized short planning helper execution/discovery. The shared classifier handles known shell tool names and ordinary command forms; this is workflow guidance/enforcement, not a general shell security boundary. Background builds, servers and test suites remain available. A provider that renames arguments or automatically backgrounds a foreground command needs adapter capability support; the skill cannot intercept UI interrupts or suppress host completion notifications. Existing feedback-file and explicit routing recovery exceptions still apply.

## Self-sufficient messages

A message that tells the agent to run or read something names its absolute path, resolved at runtime by `planning_skill_dir`/`planning_script_path`/`planning_doc_path` from the core's own location through install symlinks. Never hardcode an install path, and never emit a bare script basename: an agent that has to guess a path guesses the provider hook directory it was invoked from, fails, and then searches the filesystem. `tests/test-ownership-flow.py::test_messages_name_absolute_paths` fails any bare mention across every adapter.

The candidate/ownership message offers every verb its own gate accepts: `bind`, `release`, `clarify`, and `discuss`. `discuss` applies to an owned plan and to a pending candidate, so a question about the plan, this workflow, or the agent's own behavior has an offered action that settles Stop instead of blocking on unresolved ownership.

The skill gate is the last PreTool mutation gate, so concrete plan faults are reported first. Recognition, however, runs before every gate: a read-only call whose input names the resolved `SKILL.md` path is recorded immediately and allowed even while ownership is pending, because reading the rules is how the agent classifies the prompt it is being routed on. The marker is session-scoped and status-independent, so a read before bind still counts after it. Requiring read-only means naming the path cannot carry an unrelated mutation past the gates this signal opens.

A harness that loads the skill natively still has to read the file once; that is deliberate, because the gate can only observe what passes through a tool call. Every message that asks for the read therefore states it as required rather than conditional — telling an agent to read the file "if the rules are not in your context" leaves one that believes it knows them blocked on its first mutation, which is the failure this gate was meant to prevent.

## What authorizes a call

Authorization is read from tool input, and the signal must be one the input can actually prove:

- A call is read-only, or every recognized write target lies inside the owned plan directory.
- A shell command qualifies as plan maintenance only when the program it executes is a planning helper. Its write targets cannot be parsed, so a plan path appearing somewhere in the command proves nothing about what it writes — otherwise `<any mutation>; cat <plan>/tasks.md` would launder arbitrary work through the owned-plan allowance, and an agent reading the allowed-calls hint would find that bypass and use it. Malformed or unquotable commands fail closed.
- The path-mention fallback survives only for non-shell tools with unknown input schemas, where an explicit path field is absent but the plan is still named.

A discussion lease protects the plan, not the filesystem. Under `discussing`, a mutation whose recognized targets all lie outside the plan root is allowed, so a user who asks a question and asks for the answer written down still gets the file. Writes into a plan directory keep their existing rules, and a command whose targets cannot be located stays blocked.
