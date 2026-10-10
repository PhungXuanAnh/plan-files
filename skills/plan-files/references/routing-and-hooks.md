# Routing and Hook Semantics

Read this reference when resolving a project root, deciding whether a candidate plan belongs to the request, diagnosing session ownership, or comparing provider adapters.

## Project-root resolution

Hooks resolve the project root from the tool call's current directory:

1. Walk upward and collect ancestors containing `.plan-files`, including an empty marker. The farthest/outermost ancestor wins so cwd drift into a child repository cannot silently select a leftover child plan.
2. Otherwise walk upward the same way from the host-declared project directory, `CLAUDE_PROJECT_DIR`, which Claude Code sets for every hook.
3. Otherwise use `git rev-parse --show-toplevel`, walking through an enclosing superproject when present.
4. Otherwise use the current directory.

In nested repositories, put `.plan-files` at the intended outer workspace root. For a new non-git multi-repo workspace with no marker yet, create an empty `.plan-files` there before its first task.

Step 2 exists because Claude Code runs hooks in the session's drifting shell cwd and records it as a physical path. When `<root>/tmp` is a symlink to storage outside the project, such as a Dropbox-backed `.vscode/local_files/tmp`, a cwd under the plan directory has no `.plan-files` ancestor; resolving from it would leave the prior prompt's lease unreset (a stale `discussing` lease then blocks every write) and scatter state into the plan folder. Hooks write logs and session state only at a root with a marker, a `tmp/plan-files` directory, or a `.git` entry (`resolve-project-root.sh --accepts-state`), so a step-4 fallback root stays untouched.

## Candidate versus ownership

Prompt context is a short candidate notice, not a demand to operate on every chat message. A text-only turn may yield while its candidate remains pending. If PreTool rejects attempted work for unresolved routing, a prompt-scoped marker keeps Stop and PostTool recovery active until an explicit routing action succeeds. Reading the skill or running the read-only diagnostic below does not set that marker. The next prompt resets it; owned actionable work still blocks Stop.

Session state under `tmp/plan-files/.sessions/` is the sole source of task ownership. Multiple Codex, Claude, Copilot, or Grok sessions may share one workspace while owning different task ids. A task may have at most one executor across providers. Resumable associations do not reserve execution; multiple sessions may discuss the same task read-only. `.plan-files` marks the workspace root; its legacy contents are preserved but never select a task.

Only `tmp/plan-files/`, `.plan-files`, and `.plan-files-skip` participate in discovery and disabling. The former `tmp/plan-with-files/`, `.plan-with-files`, and `.plan-with-files-skip` names are ignored, even when the current directory or marker is absent. An obsolete path in a prompt does not nominate a task or qualify as owned-plan maintenance.

Whenever shared session routing writes state, it adds missing exact lines `tmp/*` and `.plan-files` to `<project-root>/.git/info/exclude`, preserving existing content. This also runs for a prompt with no candidate plan. It skips roots without a `.git` directory (including worktrees with a `.git` file), and an exclude write failure does not interrupt routing. Already tracked files remain tracked.

On a new user prompt, the hook suspends this session’s execution authority while retaining any still-active reservation until tools drain. It selects a candidate from this session’s previous task/candidate/association, or an exact `tmp/plan-files/<task-id>/*.md` path in the prompt. Sentence-ending punctuation after a Markdown path is accepted; filename extensions such as `.md.bak` are not plan paths. With neither, the session stays uninvolved: no candidate, plan context, or plan Stop pressure, even when other sessions own plans. A candidate produces a short notice and Goal preview. The full recovery message includes Task Identity when a tool needs routing. Classify the latest request:

- `SAME`: an explicit request to resume/implement the named task is strong evidence, including research → implementation after answers or applying decisions to its handoff. Run the supplied bind command exactly before reading other plan content. A reference to a plan as an example/background does not by itself authorize continuation.
- `DIFFERENT`: an explicit new/separate request or different id is strong evidence. Release/do not bind; never repair or compact the candidate as part of the new request.
- `AMBIGUOUS`: shared repo, branch, module, or file is only weak evidence. Run the supplied `clarify <task-id>` command, then ask before switching or mutating a task. The lease enters `waiting`; Stop allows the question and releases execution once outstanding tools finish, preserving the candidate association. Only supported question tools and exact routing commands are allowed while waiting. An asynchronous answer may be followed by explicit bind/release; a new prompt restores pending classification automatically.

Without an ownership hook, inspect only Task Identity and Goal first, apply the same classification, and do not claim session isolation.

The new user request can supersede an earlier research-only deliverable or implementation non-goal. This is a scope update within SAME when the user explicitly continues that plan, not a reason to release it. After bind, record the authorization in `decisions.md` (`decision-supersede` retires the superseded row with its replacement and reason), reconcile Goal/Task Identity/Workflow Profile and remaining phases, then implement. When every phase is settled (complete, blocked, or deferred), restore an active outcome before further operational mutation. `plan_edit.py resume N --decision ...` resumes the existing blocked/deferred phase and retains its IDs and evidence. For distinct new work, `reopen` records the decision, scope fields, new phase, and its started first item in one call. Reads and owned-plan repair remain available. A fully completed plan finalized with `--deactivate-pointer` releases only the caller’s lease. Preserve all other non-goals; they are not automatically temporary research constraints.

Binding once per prompt is intentional: UserPromptSubmit suspends the prior lease and PreTool checks that routing has been resolved. These are not two separate binds. An unchanged task reservation does not preserve old prompt authority. A successful bind remains valid within that prompt; use `resolve`, not repeated bind calls.

## Creation and binding

For a new task, choose a distinct task id and create `plan.md`, `findings.md`, and `decisions.md` from the templates. Before a recognized first plan write, PreTool atomically reserves the task with status `creating`; PostTool confirms only the matching reservation after `plan.md` exists. For an existing unowned task, a recognized plan mutation can claim it before writing. Neither path switches an existing task/candidate, and a competing claim fails before mutation. Do not rerun bind for reassurance; use `resolve` within the same prompt.

Without hooks, pass explicit plan paths for offline work. Default helper resolution requires a verified provider/session identity and an owned or discussing lease. Preserve old task directories when switching.

Stable session identity and binding fail closed. A PreTool ownership response is a required routing action, not an external blocker. Run its exact bind/release command and retry the original tool call. The gate recognizes that command from the tool input rather than by string equality, so `2>&1 | tail -3`, an appended read-only `echo` or `plan_state.py overview`, a dropped `PWF_PROJECT_ROOT=` prefix, or the adapter reached through a symlink still count as the same routing action; chaining anything that is not read-only, aiming a verb at another task, spoofing `PWF_SESSION_ID`, or hiding it in `bash -c` does not. A repeated ownership block therefore means the routing action has not run, not that its formatting was rejected. Do not inspect or alter private `.sessions` files to bypass it.

`release` rejects only this session’s pending candidate/reservation. It is not ordinary end-of-turn cleanup. To transfer owned work, the owner uses the supplied bind adapter with `handoff <task-id>`, then the receiver explicitly binds that task. A `handoff.md` snapshot alone does not transfer ownership. No transition clears or rewrites `.plan-files` or another session’s state. Stop automatically calls `finish` for fully complete owned plans; blocked/deferred plans yield execution at valid Stop and retain only their resume association. Read-only discussion, clarification, and untouched text-only candidates also yield. A blocked Stop retains authority; release is never unconditional Stop cleanup. Pending candidates must be bound, released for DIFFERENT, or explicitly put into clarification wait. PreTool and Stop render the same canonical action-first contract for all four providers.

For an explicitly discussion-only user request, run the supplied command with verb `discuss`. Read-only discussions may coexist with an executor. Recording requires exclusive access and a fresh plan snapshot; native writes reserve execution until valid Stop, while guarded helper writes hold the routing/plan locks for their transaction. This separates recording from advancing: questions, diagnosis, owned-plan maintenance, decisions/findings/history, reports under owned `artifacts/`, and recognized writes outside every plan remain allowed. Execution-state changes and writes whose targets cannot be located remain blocked. Paths resolve symlinks before classification. Stop allows the answer and PostTool does not demand execution checkpoints. If the current prompt already authorizes execution, explicitly upgrade the same task with the supplied bind adapter: `bind <task-id> --reason "<user authorization>"`. Plain bind still fails in discussion, another task cannot be substituted, and needing a tool is not authorization. Record any scope change before execution. Otherwise wait for the next prompt and bind it. Discussion is not completion and cannot excuse abandoning authorized work.

Supported question tool names are `AskUserQuestion`, `ask_user_question`, `request_user_input`, and `request_user_input_async`, including MCP and dotted function namespace prefixes. Question tools carry zero semantic risk. In unresolved ownership they are allowed only after explicit `clarify`; plain text questions also work once that transition succeeds.

## Concurrent sessions and migration

`session_state.py` owns the complete session protocol; `session-state.sh` is a stable launcher for all adapters. Each record remains a private key/value `.state` file at `.sessions/<provider>/<sha256(provider:session)>.state`. Schema 3 separates `associated` (resume candidate) from `task` (exclusive authority), adds `idle`, and retains generation tokens. Bind returns the current bounded overview and records a digest of plan/findings/decisions; changed state requires another explicit overview/resume-pack before mutation. Old valid records remain readable and are upgraded on their next transition. There is no second CSV or JSON ownership table.

Routing changes acquire `.sessions/.routing.lock` exclusively. Checkpoint/editor transactions acquire it shared, then acquire the same plan’s `.plan-edit.lock` exclusively and recheck the session generation. This prevents a waiting helper from writing after handoff and serializes checkpoint/editor writes to one plan; different plans can progress concurrently. Finalization revalidates completion under the exclusive routing lock. Never delete a live lock file: another process may still hold its inode.

Hook caches and feedback are scoped to provider/session/generation. Outstanding mutating tools prevent yield, handoff, and finish. Correlated tool receipts reject old-generation results; turn ids reject late events when supplied; timestamped SessionEnd events older than the current generation are ignored. A provider lacking both correlation and runtime identity cannot distinguish a delayed close from a current close. Providers without tool ids use counted receipts keyed by tool/input when lifecycle timestamps are available; identical concurrent calls cannot be individually correlated, but all must finish before yielding. Hosts lacking that metadata retain limited legacy tracking. Recognized native asynchronous shell handles remain outstanding after PostTool until their completion is collected; shell detachment with `&`/`nohup`/`setsid` is rejected during execution. Opaque external background work has no universal completion signal and must be managed explicitly before relinquishing the task. These are workflow guards, not a filesystem security boundary: native Edit/Write has a PreTool-to-write interval, and arbitrary editors or processes can bypass hooks. Use guarded helpers for transactional plan updates. Separate plans do not coordinate shared source files or Git operations.

Stop is the end of a turn, not proof that a session process exited. Allowed Stop atomically checks the captured generation and plan settlement, then writes `idle` with an association. SessionEnd performs the same guarded release without marking incomplete work complete. Codex/Claude/Copilot install SessionEnd adapters; Grok shutdown/channel_closed delegates to the same core. PostToolUseFailure (and Claude PermissionDenied) drains failed tool receipts. SessionEnd cannot release while tools remain outstanding. Providers must reinstall updated hook definitions; script symlinks alone do not add new events. Restart old sessions after upgrading.

PreTool receipts record attempted calls: a sibling hook or permission rule can still reject execution. Claude's `PostToolUseFailure` excludes pre-execution rejection; `PermissionDenied` excludes sibling-hook and manual denials. The shared lifecycle reconciles its host-provided `transcript_path` before PreTool routing, PostTool, Stop, and SessionEnd. It reads at most the last 16 MiB and accepts only complete native user-message `tool_result` records with `is_error: true`, matching session identity and hashed tool id. It never searches natural-language messages, summaries, stdout, file ages, or other sessions. Successful/background dispatch results do not prove completion. Reconciliation removes only unchanged matching receipts under the routing lock, never grants ownership or changes plan progress, and is disabled in read-only explain mode. Existing cached hook definitions can use this script-only repair on their next tool/Stop event; retry the supplied bind once before considering deliberate recovery.

Missing/unreadable transcripts, incomplete records, unsupported formats, and results outside the bounded window leave receipts intact. Other providers continue to require their native completion events; Claude transcript parsing is not applied to them. In particular, Codex 0.162.1 can omit PostToolUse for a sibling-hook denial and use an `exec-*` id absent from its transcript (ephemeral runs have no transcript at all). Use the explicit rejected-call recovery below when the agent has received that native denial. Do not infer completion from the next tool call or Stop alone. Unknown outcomes still require investigation and, if necessary, user-authorized recovery after writers stop.

### Rejected-call recovery

For a shell call whose native tool result explicitly says a hook or permission check **rejected it before execution**, the same agent may acknowledge that one rejection. This is an explicit attestation based on the received result, not automatic host proof. No additional user confirmation is needed for the agent's own verified rejection. Never use this path for timeouts, interrupted/failed commands that may have started, missing results, or an absent output file. Collect native background jobs normally. Do not clear `.tools`, disable hooks, or reclaim a task to discard a rejected call.

Use the absolute bind adapter from the hook's guidance (represented as `<bind-adapter>` here):

```bash
bash <bind-adapter> tools <task-id> --command '<exact rejected shell command>'
bash <bind-adapter> ack-rejected <task-id> --command '<exact rejected shell command>' \
  --receipt <receipt-from-tools> --generation <generation-from-tools> \
  --reason 'Native PreToolUse denial received for this exact call; execution did not start'
```

Inspect first and proceed only with exactly one matching receipt and its concrete native rejection. The shared core checks the session, task, exact command hash, receipt and recorded generation under the routing lock. Ambiguous identical calls, stale tokens, missing legacy metadata and background handles are refused. `.attempts` contains only hashes/generations for diagnosis; `.tools` is the authority. Acknowledgement removes only that receipt, leaves other tools and all other sessions untouched, and does not bind a prompt or refresh a plan snapshot. These two commands work before bind so a new prompt can recover its own previous rejection; bind and restore afterwards. A repeated acknowledgement fails instead of silently acting on a newer call.

Claude versions with automatic background completion notifications may have no `TaskOutput` tool. Their Stop event's native `background_tasks` registry reconciles completed shell receipts before routing/finalization. Missing or invalid registry data is not completion evidence; neither output-file text nor elapsed time releases authority. An automatic completion prompt may require binding again after this reconciliation, while the same task remains reserved throughout.

Read-only collection of a tracked native job remains allowed across a new prompt, so pending routing cannot prevent existing tools from draining. Only this session's known job handles qualify; sending stdin or launching work still requires normal authorization. Collection keeps the original tool generation and does not bind the new prompt or transfer the task.

Abrupt termination does not guarantee SessionEnd delivery. On bind, a local runtime is automatically recovered only with positive process-death evidence and no outstanding tools. Linux evidence includes machine, boot, pid, and process start time, so pid reuse and old boots are handled. A live, inaccessible, remote, unknown, or legacy runtime is never considered dead merely because its record is old. Missing tool completions require deliberate recovery; inspect running writers before reclaiming.

Unresolved ownership produces `RESERVED` with holder count and activity age. Age is diagnostic, not an expiry. Read-only discussion remains possible. For execution, do not retry bind: run `clarify`, ask whether the sessions and writers have stopped, then use the supplied `reclaim <task-id> --reason "<user authorization>"` only with authorization. Under the routing lock it invalidates old owners and their tool receipts, then binds the caller with the latest snapshot. Corrupt or conflicting records fail closed for mutation; never edit `.sessions/` to bypass them. Normal stopped sessions require neither reclaim nor manual handoff.

An explicit plan path permits reads and offline helper writes to an unowned plan without session identity. It never permits helper writes to a task reserved by another session. Ambiguous/incomplete identities fail instead of falling back to a shared default. Inactive records remain to reject delayed writes from the former owner, including the gap before a receiver binds.

## Resume reads

After binding SAME:

1. Load bounded `plan_state.py overview`. If `restore.ok` is false, run `restore-check` for the complete repair list; a true result needs no immediate duplicate check.
2. Follow only the exact `next_read.targets`, active phase/item, decision, and finding sections needed.
3. Read `handoff.md` only when its freshness state is valid.
4. Never auto-read `history.md`; search or open it only through a specific reference.

A direct complete-file read is valid for format repair, compaction judgment, or broad reconciliation.

## Provider contract

Codex, Claude Code, Copilot, and Grok Build reuse canonical hook cores plus the shared Python session store for resolver/session integration, common format helpers, semantic stale policy, maintenance gating, telemetry, and Stop finalization. Provider launch shims pass the provider name, session identity, and the small output-envelope differences required by each host. Provider-unique events may keep a local adapter when their input or output contract has no shared counterpart, but that adapter must delegate candidate selection and session state to the canonical scripts.

- PreTool gates ambiguous ownership, an unloaded skill, invalid format/profile/item/status/restore state (including legacy plans), explicit background planning helpers, and over-budget unrelated mutations while allowing read-only diagnosis and owned-plan repair. Native Edit/Write must name a target inside the owned plan. Shell maintenance uses a scoped planning helper or the literal Markdown heredoc described below; any accompanying segments must be read-only. Arbitrary Python or shell cannot prove write scope by mentioning plan paths, even in argv. For non-shell tools with unknown schemas, a whole argument must be a path inside the plan; a path quoted inside a longer string grants nothing. Helpers resolve the current session’s owned task, so `--plan` is optional there; naming a foreign plan explicitly does not authorize its mutation. Block messages name supported repair paths.
- PostTool repeats routing recovery after work was blocked for unresolved ownership, then checks integrity, restore state, and budgets before debounce. Unresolved faults repeat every call. Healthy actionable-state and finalization advisories share semantic/time debounce with context and evidence reminders; unchanged reads and plan maintenance stay silent after the first context. It does not complete items.
- Unclassified calls retain conservative execution gating but do not accumulate early stale risk. Recognized evidence/mutations can trigger an early warning; prolonged unknown-only activity receives a conditional checkpoint review after the age limit. Neither warning proves an item is complete.
- Stop blocks actionable or invalid plans and supplies a continuation instruction.

An unstarted contracted plan (empty Current Phase/Active Item, all phases pending) is restorable discussion state. PreTool still requires starting an Active Item before operational work. Over-budget plans continue to allow questions, recognized reads, and owned-plan repair; a question about an unrelated task does not authorize binding or compacting the candidate.

Grok's native adapter uses provider id `grok` and requires the event envelope's `sessionId` to match the runner-provided `GROK_SESSION_ID`. Its allowing UserPromptSubmit output is not a context channel, so pending PreToolUse and Stop responses repeat bounded candidate identity and exact actions. The adapter translates only PreToolUse `block` to Grok's canonical `deny`; shared Stop `block` is already compatible. It invokes the shared Stop core for `end_turn` and the shared SessionEnd core for `shutdown`/`channel_closed`; other reasons remain observe-only. PostToolUse side effects are mandatory even when an older Grok release ignores its stdout; newer releases may deliver the emitted `additionalContext`. Grok overrides the Stop gate after eight continuation rounds, but keeps the task lease available for the next prompt.

A session doing unrelated work needs no opt-out or release. If the user explicitly disables the workflow, `PLANNING_DISABLED=1` affects only processes receiving that environment variable; it does not release existing reservations. `.plan-files-skip` disables hooks for every session in the resolved project.

Official Grok applies a 256-Unicode-character budget to PreTool denial reasons before model delivery. Its adapter passes this capability to the shared core; `feedback_transport.py` writes longer reasons intact into a mode-600 file under the private mode-700 `/tmp/plan-files-feedback-<uid>/` directory. The short deny advertises that absolute path within the host budget. Names hash the project/provider/session routing scope and contain no raw session id.

The feedback exception is deliberately based on tool arguments, not tool names: any call whose arguments contain the current generated path is allowed in full, including unfamiliar tools, nested values, or additional arguments. Other tool calls retain the normal ownership/restore/maintenance gates. Reading feedback does not confer ownership. A new prompt, bind, clarify, discuss, release, or finish invalidates the previous feedback file. Different projects/providers/sessions cannot use each other's path as an exception. The file contains only the hook's existing trusted recovery message, never arbitrary tool input or hidden session state.

The same core mechanism can serve another adapter with a small reason budget; provider wrappers only declare the capability. Stop can still deliver its full context directly. Grok source is reference-only: the official installed executable needs no modification or rebuild. Tests measure the short delivered reason and the complete recovered instructions separately, including through the unchanged Grok runner.

## Early enforcement and Stop audit

Repeated identical long PreTool denials use the private feedback file on all providers: uncapped hosts receive the full first reason and a recovery pointer of at most 512 characters on repeat; Grok retains its 256-character limit from the first denial. Scope transitions invalidate the file. Full instructions are retained, not truncated.

To explain a decision without executing a command or changing leases, markers, logs, or feedback:

```bash
python3 <skill-dir>/scripts/hook_explain.py --provider claude \
  --session-id <session-id> --project-root <project-root> --command 'cp findings.md report.md'
```

The session defaults to `PWF_SESSION_ID` or the corresponding provider environment when available. Output schema 1 includes `provider`, `decision`, `reason`, and `read_only`. The diagnostic invokes the actual shared PreTool policy with writes suppressed; it does not create a parallel policy or confer ownership. It can preview a prospective claim/reservation but cannot reserve it against concurrent changes. The diagnostic itself is allowed before binding.

Literal single-file `cp source target` and `cat source > target`/`>> target` now locate the destination, including directory destinations and symlinks, rather than treating the source plan as a write target. Compound, dynamic, recursive, or unrecognized writes stay conservative. Fixed `xargs` readers (`cat`, `head`, `tail`, `wc`, checksums, `stat`) with supported argument-count/null-input flags are read-only; `xargs sh`, mutating commands, and arbitrary flags are not. Shell gates remain hard constraints, not self-declared read-only exceptions.

All three events use `planning_integrity_warning` in the canonical core; adapters only render their envelopes. Re-evaluate disk state on each tool event, including companion-file freshness. Repair calls and read-only diagnosis remain available; unrelated operational calls wait until the fault is repaired.

| Condition | PreToolUse | PostToolUse | Stop |
|---|---|---|---|
| Pending ownership | Require a routing verb before work | Repeat routing recovery after a blocked attempt | Allow text-only turns; repeat routing after blocked work |
| Malformed sections, phase headings/statuses, Current Phase, missing/unfilled profile | Block operational work, including legacy plans | Repeat bounded repair diagnostics each call | Block with full shared diagnosis |
| Invalid Active Item, ids, evidence | Block operational work | Repeat shared diagnosis | Block |
| Complete phase with unchecked work, stale Current Phase, hidden non-phase work | Block operational work | Repeat shared diagnosis | Block |
| Missing/placeholder resume state, stale handoff/external evidence | Block operational work | Repeat restore repairs each call | Explicit final restore-check verifies freshness before assert-finalizable |
| Hot-state over budget | Block outside writes/unknown calls | Repeat compaction guidance each call | Maintenance remains required by the work loop |
| Valid actionable phases | Allow authorized work | Debounced Stop advisory; unchanged reads/maintenance do not force an injection | Continue remaining work |
| Every phase settled: complete, blocked, or deferred | Block operational mutation until `resume` activates the authorized paused phase or `reopen` adds distinct new work; allow reads, plan repair, and finalization | Debounced finalization reminder; resume/reopen guidance after calls with non-zero semantic weight | Yield execution after settlement checks; retain the resume association; assert-finalizable remains required |
| Never-started proposal or explicit clarify/discuss lease | Preserve routing/discussion gates | No execution pressure in explicit discussion | Allow discussion without claiming completion |
| Skill never read in this session | Block operational mutation, naming the absolute `SKILL.md` path; allow the read-only skill read in any routing state | Existing reload advisory | No separate Stop condition |

Persistent integrity diagnostics are capped at 3000 characters plus a short repair-read hint; full reasons remain available at Stop. Other warning families are bounded separately. Clearing one fault removes its warning on the next PostTool; other faults still repeat. Pending work is not an invalid state and must never be used to block the tools needed to complete it. Stop remains the final backstop rather than the first diagnosis.

Explicit background flags (`background`, `is_background`, `run_in_background`) or shell detachment are denied for recognized short planning helper execution/discovery. The shared classifier handles known shell tool names and ordinary command forms; this is workflow guidance/enforcement, not a general shell security boundary. Background builds, servers and test suites remain available. A provider that renames arguments or automatically backgrounds a foreground command needs adapter capability support; the skill cannot intercept UI interrupts or suppress host completion notifications. Existing feedback-file and explicit routing recovery exceptions still apply.

## Self-sufficient messages

A message that tells the agent to run or read something names its absolute path, resolved at runtime by `planning_skill_dir`/`planning_script_path`/`planning_doc_path` from the core's own location through install symlinks. Never hardcode an install path, and never emit a bare script basename: an agent that has to guess a path guesses the provider hook directory it was invoked from, fails, and then searches the filesystem. `tests/test-ownership-flow.py::test_messages_name_absolute_paths` fails any bare mention across every adapter.

The candidate/ownership message offers `bind`, `release`, `clarify`, and `discuss`; owned work additionally supports explicit `handoff` through the same adapter. A task held by another lease additionally offers user-authorized `reclaim`. `discuss` applies to an owned plan and to a pending candidate, so a question about the plan, this workflow, or the agent's own behavior has an offered action that settles Stop instead of blocking on unresolved ownership.

The skill gate is the last PreTool mutation gate, so concrete plan faults are reported first. Recognition, however, runs before every gate: a read-only call whose input names the resolved `SKILL.md` path is recorded immediately and allowed even while ownership is pending, because reading the rules is how the agent classifies the prompt it is being routed on. The marker is session-scoped and status-independent, so a read before bind still counts after it. A validated routing command may be combined with a read-only skill-read segment and still count as loaded. The entire call must satisfy routing validation; mentioning the path cannot carry an unrelated mutation past the gates.

A harness that loads the skill natively still has to read the file once; that is deliberate, because the gate can only observe what passes through a tool call. Every message that asks for the read therefore states it as required rather than conditional — telling an agent to read the file "if the rules are not in your context" leaves one that believes it knows them blocked on its first mutation, which is the failure this gate was meant to prevent.

## What authorizes a call

Authorization is read from tool input, and the signal must be one the input can actually prove:

- A call is read-only, or every recognized write target lies inside the owned plan directory.
- A shell command qualifies as maintenance through a scoped planning helper or a literal `cat` heredoc with a quoted delimiter and one `.md` target inside the plan. Its body is data; following commands must be read-only and foreground. Other shell/Python writes cannot establish scope merely by mentioning paths, including in argv. Mixed writes, substitutions in targets, and malformed forms fail closed; native Edit/Write remains the direct repair path.
- The path-mention fallback survives only for non-shell tools with unknown input schemas, where an explicit path field is absent but the plan is still named.

A discussion lease protects the plan, not the filesystem. Under `discussing`, a mutation whose recognized targets all lie outside the plan root is allowed, so a user who asks a question and asks for the answer written down still gets the file. Writes into a plan directory keep their existing rules, and a command whose targets cannot be located stays blocked.
