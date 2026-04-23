# GitHub Copilot Hook Integration — Modifications

Reduced and refactored `.github/hooks/` to be **manual-opt-in** with **zero pollution** on non-planning sessions.

## Final hook layout

**Manifest:** [.github/hooks/planning-with-files.json](.github/hooks/planning-with-files.json) declares 3 hooks:
- `postToolUse` (timeout 5s)
- `agentStop` (timeout 10s)
- `errorOccurred` (timeout 5s)

**Scripts in [.github/hooks/scripts/](.github/hooks/scripts/):**
- `post-tool-use.{sh,ps1}` — modified
- `agent-stop.{sh,ps1}` — unchanged
- `error-occurred.{sh,ps1}` — unchanged

## What was removed

- `sessionStart` hook + `session-start.{sh,ps1}` scripts
  - Reason: user attaches the planning skill manually; do not auto-inject SKILL.md
  - Tradeoff: lost auto-recovery via `session-catchup.py` after `/clear`. User said they don't care about `/clear`, only `/compact`.
- `preToolUse` hook + `pre-tool-use.{sh,ps1}` scripts
  - Reason: redundant with postToolUse (both inject `additionalContext` into the same next-LLM-prompt). Merged into postToolUse.
- `preCompact` hook + `pre-compact.{sh,ps1}` scripts (briefly added then removed)
  - Reason: user said it doesn't take effect (per their testing).

## What was changed in post-tool-use

### Goal anchoring strategy
Replaced `head -15 task_plan.md` with **section extraction** of `## Goal` and `## Current Phase` blocks via:
- bash: two-stage `awk` pipeline (capture-by-header → strip HTML comments) + `sed` to collapse blank-line runs
- PowerShell: line-by-line foreach loops with regex `^## (Goal|Current Phase)\s*$`

Why: `head -15` misses real content when Goal is multi-paragraph or the file has accumulated decisions/errors above the cutoff. Section extraction is size-bounded and always extracts exactly the relevant bits.

Verified live: a 49-line plan with ~20-line Goal + ~6-line Current Phase + filler sections (`## Phases`, `## Decisions Made`, `## Errors Encountered`) → injection contained only Goal + Current Phase, excluded everything else.

### Nudge text
Updated to:
> `[planning-with-files] Update progress.md with what you just did. If a phase is now complete, update task_plan.md status. If you no longer see the planning-with-files SKILL.md rules in your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing.`

Self-reload instruction replaces the earlier "ask the user to re-attach" wording — model handles compaction recovery autonomously.

### Per-section hard caps (defense in depth)
The hook enforces independent character caps per section:
- `MAX_GOAL_CHARS=700` (sh) / `$MaxGoalChars = 700` (ps1)
- `MAX_PHASE_CHARS=100` (sh) / `$MaxPhaseChars = 100` (ps1)

When a section exceeds its cap, only that section is truncated (cut to N chars + a marker line appended). The other section is emitted intact. This guarantees `Current Phase` can never be starved by a verbose `Goal`.

**Truncation marker (verbatim):**
> `[truncated by post-tool-use hook — full text in task_plan.md; this section is too long for per-call injection, consider shortening it there]`

Tells the model both **where to find the rest** (re-read `task_plan.md` if truly needed — usually unnecessary since Goal/Phase are concept-level) and **the right action** (shorten the file, since per-call re-injection cost compounds).

**Two-layer defense:**
- **Soft cap** = template guidance in HTML comments (`MAX 50 words / ~350 chars` for Goal, `MAX 15 words / ~100 chars` for Phase). What a well-behaved LLM follows.
- **Hard cap** = hook truncation (700 / 100). Safety net when soft cap is ignored, plan accumulates cruft, or user edits manually.

Goal hard cap = 2× soft cap (350→700) gives headroom; Phase hard cap = soft cap (both 100) since Phase should always be terse.

**Worst-case injection:** ~1.3 KB. Well-behaved sessions: ~600 chars and no marker.

**Verified scenarios** (via Python harness driving the bash hook):
| Scenario | Total chars | Truncation markers |
|---|---|---|
| Realistic well-behaved plan | 603 | 0 |
| Verbose Goal (5000+ chars) + normal Phase | 1277 | 1 (Goal only) |
| Both sections oversized | 1339 | 2 |
| HTML comments present | 511 | 0 (comments stripped) |
| Only `## Goal` exists | clean | 0 (no `## Current Phase` header emitted) |

### Template comment updates
[templates/task_plan.md](templates/task_plan.md) and [skills/planning-with-files/templates/task_plan.md](skills/planning-with-files/templates/task_plan.md) HTML comments updated to advertise the soft caps and explain the per-call re-injection cost. Per-IDE template copies (`.cursor/`, `.gemini/`, `.codex/`, etc.) NOT yet synced — run `scripts/sync-ide-folders.py` to propagate.

### Gating
All three remaining hooks no-op (`echo '{}'`) when `task_plan.md` does not exist in CWD. Confirms the design property: zero context pollution on any session where the user has not opted into planning by creating the plan file.

## Behavioral guarantees verified

| Scenario | Output |
|---|---|
| No `task_plan.md` | All 3 hooks emit `{}` |
| Plan exists, post-tool-use | `=== Current plan (Goal + Current Phase from task_plan.md) ===\n<sections>\n\n[nudge]` |
| Plan exists, agent-stop, all phases complete | `"ALL PHASES COMPLETE (N/N). ..."` |
| Plan exists, agent-stop, some phases incomplete | `"Task incomplete (X/Y phases done). ..."` |
| Tool errors with plan | error-occurred extracts `error.message` (truncated 200 chars), tells model to log under "Errors Encountered" |

## Debug logging (added to all 3 hooks)

All hook scripts (`.sh` + `.ps1`) write append-mode debug logs to:
- `tmp/hook-logs/plan-with-files/post-tool-use.log`
- `tmp/hook-logs/plan-with-files/agent-stop.log`
- `tmp/hook-logs/plan-with-files/error-occurred.log`

Path is workspace-relative (relative to hook cwd, which is the workspace root). `tmp/` added to [.gitignore](.gitignore) so logs are never committed. Logging writes only to file — stdout (the JSON contract with Copilot) is untouched.

**Each entry includes ISO-8601 UTC timestamp.**

### What gets logged per hook

**post-tool-use.log:**
- `cwd`, stdin preview (first 300 chars + total length)
- `task_plan.md` presence + byte count (or `ABSENT -> emitting {} (no-op, zero pollution)`)
- raw extracted Goal / Current Phase character counts
- per-section truncation events: `Goal: 1710 chars -> TRUNCATED to 700` vs `within cap 700`
- final `additionalContext` length
- **Full `additionalContext` body** between `--- additionalContext begin ---` / `--- additionalContext end ---` markers (so you can see verbatim what was injected into the LLM)
- final stdout JSON length

**agent-stop.log:**
- `cwd`, stdin preview, plan presence + bytes
- format detected (`Status:` vs `[bracket]` fallback)
- phase counts: `total=N complete=N in_progress=N pending=N`
- decision: `ALL COMPLETE` or `INCOMPLETE`
- stdout length

**error-occurred.log:**
- `cwd`, stdin preview (first 500 chars — longer cap since error payloads are richer)
- plan presence
- extracted+truncated `error.message` (200-char cap)
- stdout length OR no-op reason (e.g. parse exception, no `error.message` field)

### Why this matters
- Diagnose silent no-ops (was `task_plan.md` actually missing? wrong cwd?)
- Confirm soft-cap discipline (look for `TRUNCATED` lines — none = LLM behaving)
- See exactly what the LLM received per tool call (the `--- additionalContext` block)
- Correlate Copilot's stdin payload shape against the hook contract
- Verify which `agent-stop` format engaged (Status vs bracket fallback)

### Caveat for live VS Code sessions
Copilot caches hook manifests at process start. After editing scripts, **reload the VS Code window** (`Developer: Reload Window`) for live tool calls to start writing new log entries.

## Multi-task layout via `.plan-with-files` pointer (latest change)

Replaced the single workspace-root `task_plan.md` model with a **strict pointer-based multi-task layout**. Hooks no longer fall back to the legacy location — there is now exactly one way to point at a plan, which keeps the contract simple and the no-op behavior unambiguous.

### New filesystem layout

```
<workspace root>/
├── .plan-with-files                     # ONE LINE: active task id
└── tmp/plan-with-files/
    ├── JIRA-1234/
    │   ├── task_plan.md
    │   ├── findings.md
    │   └── progress.md
    └── add-oauth/                       # parked task; resume by editing pointer
        └── ...
```

Switch tasks: `echo "<other-id>" > .plan-with-files`. Old folders persist for resume.

### Resolution algorithm (all 6 hooks: sh + ps1)

1. If `.plan-with-files` is missing → emit `{}` (no-op).
2. Read first line, trim whitespace. Validate against `^[A-Za-z0-9._-]+$` AND not `.` AND not `..`. Reject otherwise.
3. Check `tmp/plan-with-files/<task-id>/` exists. If not → emit `{}`.
4. Use `tmp/plan-with-files/<task-id>/task_plan.md`.

**Security:** task-id whitelist blocks path traversal (`../`), spaces, slashes. Invalid ids silently no-op (don't reveal anything to logs that an attacker would see).

**No legacy fallback** — by user's explicit decision (rationale: SKILL.md is now responsible for guiding the model through pointer creation; ambiguous fallback would let stale `./task_plan.md` files hijack new sessions).

### Plan-source diagnostic in logs

Every hook log entry now begins with a `plan source:` line that tells you the resolution outcome:
- `plan source: .plan-with-files -> tmp/plan-with-files/JIRA-1234 -> tmp/plan-with-files/JIRA-1234/task_plan.md` (resolved OK)
- `plan source: .plan-with-files -> tmp/plan-with-files/PHANTOM (DIR MISSING -> no-op)`
- `plan source: .plan-with-files -> '../../etc/passwd' (INVALID id -> no-op)`
- `plan source: no .plan-with-files pointer -> no-op`

Verified all 5 resolution paths via Python harness (valid pointer, missing pointer, missing dir, malicious id, nothing set).

### Naming convention

Both pointer file and folder are PLURAL: `.plan-with-files` and `tmp/plan-with-files/`. Earlier iteration briefly used singular `.plan-with-file`; renamed everywhere for consistency with the skill name. No singular references remain in repo.

### SKILL.md updated

[skills/planning-with-files/SKILL.md](skills/planning-with-files/SKILL.md) now contains a dedicated section teaching the LLM:

- The required directory layout + ASCII tree
- **Task id rules** (whitelist + forbidden chars), with valid/invalid examples
- **Workflow A — starting a NEW task**: pick id (ask user if unclear) → `mkdir tmp/plan-with-files/<id>` → create 3 md files from templates → `echo "<id>" > .plan-with-files`
- **Workflow B — CONTINUING a task**: read `.plan-with-files`. If missing OR id doesn't match user's prompt, list `tmp/plan-with-files/*/` and **ask the user** (never silently overwrite the pointer).
- **Switching tasks** by rewriting the pointer
- Hook-behavior table (4 pointer states → 4 outcomes)
- Updated Quick Start (7 steps including pointer write)

NOT YET propagated to the 12 IDE-specific copies (`.cursor/`, `.gemini/`, `.codex/`, `.codebuddy/`, `.continue/`, `.factory/`, `.kiro/`, `.mastracode/`, `.opencode/`, `.pi/`) nor the localized variants (`-zh`, `-zht`). Run `scripts/sync-ide-folders.py` to propagate.

### Behavioral guarantee table updated

| Pointer state | Hook output |
|---|---|
| `.plan-with-files` missing | `{}` no-op |
| Pointer present, dir missing | `{}` no-op (skill should ask user) |
| Pointer present, invalid id | `{}` no-op |
| Pointer present, dir + `task_plan.md` present | Goal + Current Phase injected |

Earlier "no `task_plan.md` in workspace root" gating is now superseded — `task_plan.md` is no longer expected at workspace root at all. Templates and HTML comment captions still reference `task_plan.md` as the filename (correct — the file is still named that, just lives in a subfolder).

## Real-world quirk (observed during live test)

The **first** tool call after creating `task_plan.md` may not see the new file — hook fires before write is flushed (or runs in a different CWD for that specific tool). Subsequent tool calls inject correctly. Practical impact: 1-tool-call lag from plan creation to hook activation.

## How the user runs the planning workflow now

1. Start session → nothing fires automatically.
2. User manually attaches the `planning-with-files` skill (loads SKILL.md into context).
3. Model creates `task_plan.md` per SKILL.md instructions.
4. From the next tool call onward, post-tool-use injects Goal + Current Phase + nudge.
5. agent-stop blocks termination until all phases marked complete.
6. error-occurred prompts error logging in the plan.
7. After `/compact`: nudge tells model to reload skill itself if it no longer sees SKILL.md rules.
