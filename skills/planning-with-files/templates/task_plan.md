# Task Plan: [Brief Description]
<!-- 
  WHAT: This is your roadmap for the entire task. Think of it as your "working memory on disk."
  WHY: After 50+ tool calls, your original goals can get forgotten. This file keeps them fresh.
  WHEN: Create this FIRST, before starting any work. Update after each phase completes.
-->

## Goal
<!-- 
  WHAT: One clear sentence (or two short ones) describing what you're trying to achieve. MAX 50 words / ~350 characters.
  WHY: This is your north star. Re-reading this keeps you focused on the end state.
  LENGTH RULE: Keep it tight. Detailed context, full constraints, and acceptance criteria belong in findings.md, NOT here.
        This section is re-injected into the model on every tool call by the post-tool-use hook, so verbosity is paid per-call.
  EXAMPLE: "Create a Python CLI todo app with add, list, and delete functionality, persisting to a local JSON file."
-->
[One sentence describing the end state]

## Current Phase
<!-- 
  WHAT: Which phase you're currently working on (e.g., "Phase 1", "Phase 3"). MAX 15 words / ~100 characters.
  WHY: Quick reference for where you are in the task. Update this as you progress.
  LENGTH RULE: Phase label + at most a short qualifier. Detailed status notes belong in progress.md, NOT here.
        This section is re-injected into the model on every tool call by the post-tool-use hook.
-->
Phase 1

## Phases
<!-- 
  WHAT: Break your task into 3-7 logical phases. Each phase should be completable.
  WHY: Breaking work into phases prevents overwhelm and makes progress visible.
  
  PHASE STRUCTURE (required for every phase):
    1. **Status** — pending | in_progress | complete  (placed FIRST so you can scan progress fast)
    2. **Tasks** — concrete actions you take (imperative verbs)
    3. **Done when** — executable acceptance criteria (each item names HOW to verify, not just WHAT outcome)
  
  STATUS VALUES:
    - pending: Not started yet
    - in_progress: Currently working on this
    - complete: ALL "Done when" boxes checked AND verified by the named method
-->

### Phase 1: Requirements & Discovery
<!-- 
  WHAT: Understand what needs to be done and gather initial information.
  WHY: Starting without understanding leads to wasted effort.
-->
**Status:** in_progress

**Tasks:**
- [ ] Understand user intent
- [ ] Identify constraints and requirements
- [ ] Document findings in findings.md

**Done when:**
- [ ] **Findings recorded:** open `findings.md` → contains explicit answers to every Key Question below
- [ ] **Constraints listed:** at least one bullet per: tech stack / data shape / external dependencies / non-goals
- [ ] **User confirms scope** (if interactive) — paste user's confirmation into `findings.md`

### Phase 2: Planning & Structure
<!-- 
  WHAT: Decide approach and structure. Document decisions so you remember why.
-->
**Status:** pending

**Tasks:**
- [ ] Define technical approach
- [ ] Create project structure if needed
- [ ] Document decisions with rationale in `## Decisions Made` table below

**Done when:**
- [ ] **Decisions table populated:** every non-obvious choice has a row with rationale
- [ ] **Project skeleton exists:** `ls <project-root>` shows expected directories
- [ ] **No undefined assumptions:** re-read `## Goal` — every word maps to a documented decision

### Phase 3: Implementation
<!-- 
  WHAT: Actually build/create/write the solution.
-->
**Status:** pending

**Tasks:**
- [ ] Execute the plan step by step
- [ ] Write code to files before executing
- [ ] Update `progress.md` after each significant change

**Done when:**
- [ ] **Code compiles/lints clean:** `<exact build/lint command>` exits 0
- [ ] **Unit tests added & pass:** `<exact test command>` shows new tests covering the changes
- [ ] **No TODOs left for this phase** in the code (`grep -rn TODO src/` excludes pre-existing ones)

### Phase 4: Testing & Verification
<!-- 
  WHAT: Verify everything works and meets requirements.
  
  ⚠ ANTI-SUBSTITUTION RULE:
    Each "Done when" item below names a SPECIFIC test method (unit / integration / E2E).
    DO NOT substitute a cheaper test for the named one.
    Example violation: criterion says "Selenium E2E" → agent runs only pytest → marks ✅.
    A unit test passing is NOT evidence that the E2E criterion is met.
-->
**Status:** pending

**Tasks:**
- [ ] Run all named verifications below
- [ ] Document test results in `progress.md` (include exact commands and observable output)
- [ ] Fix any issues found, then re-run the failing verification

**Done when** (each criterion names its tool + assertion — do not swap tools):
- [ ] **Unit-level:** `<exact test command>` → all relevant tests pass
- [ ] **Integration-level:** `<service / curl / API call>` → response matches `<expected shape/value>`
- [ ] **E2E / user-flow level:** `<Selenium MCP / Playwright / manual UI walkthrough>` → user sees `<exact observable state>` AND backend stores `<exact field=value>`
- [ ] **Live data verification (if applicable):** query `<storage>` for the record produced by the E2E run; assert `<field> == <expected>`

### Phase 5: Delivery
<!-- 
  WHAT: Final review and handoff to user.
-->
**Status:** pending

**Tasks:**
- [ ] Review all output files
- [ ] Ensure deliverables are complete
- [ ] Hand off to user with a summary

**Done when:**
- [ ] **Deliverables list verified:** every item in `## Goal` is mapped to a concrete file/PR/URL
- [ ] **`progress.md` final entry written:** session summary + what's left (if anything)
- [ ] **User accepts** (if interactive) OR all "Done when" boxes in earlier phases are checked

## Key Questions
<!-- 
  WHAT: Important questions you need to answer during the task.
  WHY: These guide your research and decision-making. Answer them as you go.
  EXAMPLE: 
    1. Should tasks persist between sessions? (Yes - need file storage)
    2. What format for storing tasks? (JSON file)
-->
1. [Question to answer]
2. [Question to answer]

## Decisions Made
<!-- 
  WHAT: Technical and design decisions you've made, with the reasoning behind them.
  WHY: You'll forget why you made choices. This table helps you remember and justify decisions.
  WHEN: Update whenever you make a significant choice (technology, approach, structure).
  EXAMPLE:
    | Use JSON for storage | Simple, human-readable, built-in Python support |
-->
| Decision | Rationale |
|----------|-----------|
|          |           |

## Errors Encountered
<!-- 
  WHAT: Every error you encounter, what attempt number it was, and how you resolved it.
  WHY: Logging errors prevents repeating the same mistakes. This is critical for learning.
  WHEN: Add immediately when an error occurs, even if you fix it quickly.
  EXAMPLE:
    | FileNotFoundError | 1 | Check if file exists, create empty list if not |
    | JSONDecodeError | 2 | Handle empty file case explicitly |
-->
| Error | Attempt | Resolution |
|-------|---------|------------|
|       | 1       |            |

## Notes
<!-- 
  REMINDERS:
  - Update phase status as you progress: pending → in_progress → complete
  - Re-read this plan before major decisions (attention manipulation)
  - Log ALL errors - they help avoid repetition
  - Never repeat a failed action - mutate your approach instead
-->
- Update phase status as you progress: pending → in_progress → complete
- Re-read this plan before major decisions (attention manipulation)
- Log ALL errors - they help avoid repetition
