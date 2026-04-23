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

## Workflow Profile
<!-- 
  CRITICAL: Pick ONE profile before starting. This determines what "done" means for every coding phase below.
  The agent MUST NOT mark a coding phase complete until it reaches the named handoff point of the chosen profile.
  Replace the placeholder below with: A | B | C
-->
**Profile:** [A | B | C]

### Profile A — PR-Handoff (human reviews before merge)
- Agent does: code → local E2E → unit tests → commit → push → open PR → wait CI green → write PR description → **STOP**
- Human does: code review → merge → deploy → prod verification
- **Phase done when:** PR open, CI green, description complete, reviewers requested
- **Agent must NOT:** self-merge, mark phase done before CI green, skip writing PR description

### Profile B — Staging-Verified (agent ships to staging + re-runs E2E there)
- Agent does: everything in Profile A, then: merge PR to staging → wait CI/CD pipeline → re-run E2E on staging URL → **STOP**
- Human does: prod promotion, prod verification, monitoring
- **Phase done when:** staging deployment reflects merged code AND the SAME E2E flow that passed locally also passes against the staging URL
- **Agent must NOT:** mark phase done if staging E2E was skipped, mark phase done if staging E2E used localhost URL by mistake

### Profile C — Research/Document (no code, no PR, no deploy)
- Agent does: gather data → analyze → write findings → produce deliverable file/report → **STOP**
- **Phase done when:** deliverable file exists, has been reviewed against the Goal, key questions answered
- **No PR / staging / CI applies** — skip Profile A/B criteria in coding phase template below

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

### CODING PHASE TEMPLATE — copy this into any coding phase you create
<!--
  Copy this block (rename to "Phase N: <name>") for any phase that produces shippable code.
  The "Done when" criteria below adapt to your chosen Workflow Profile (A / B / C).
  For pure-research phases, use the simpler Phase 1 (Requirements & Discovery) shape instead.
-->
**Status:** pending

**Tasks:**
- [ ] Implement the change (code, config, schema)
- [ ] Add/update unit tests
- [ ] Run local E2E to validate user-visible behavior
- [ ] Write commit(s) + push branch + open PR with description, screenshots, test evidence

**Done when** (criteria depend on `## Workflow Profile` selected at top — anti-substitution rule applies):

**Always required (Profile A AND Profile B):**
- [ ] **Local code:** files saved, no `git status` dirty changes outside intended files
- [ ] **Unit tests:** `<exact test command>` exits 0 with new tests covering the changes
- [ ] **Local E2E:** `<Selenium MCP / curl / manual UI walkthrough>` against `localhost` → user sees `<exact observable state>` AND backend stores `<exact field=value>`
- [ ] **Committed:** `git log --oneline -3` shows changes in named commit(s) on a feature branch (NOT `main`/`master`/`staging`)
- [ ] **Pushed:** `git log origin/<branch> --oneline -1` matches local HEAD
- [ ] **PR opened:** `gh pr view <PR#>` shows correct base, body filled with description + screenshots + test evidence
- [ ] **CI green on PR:** `gh pr view <PR#> --json statusCheckRollup` → all checks SUCCESS

**Profile A (PR-Handoff) — STOP HERE:**
- [ ] **Reviewers requested + handoff message:** PR has reviewers assigned; paste PR URL + 1-line summary into `progress.md`

**Profile B (Staging-Verified) — additional criteria after CI green:**
- [ ] **Merged to staging:** `git log staging --oneline -3` shows the merge commit
- [ ] **CI/CD pipeline complete:** `<exact command/URL>` → all stages green
- [ ] **Deployed:** version on staging reflects new commit SHA (e.g. `curl https://staging.example.com/version` returns expected SHA)
- [ ] **Staging E2E re-run:** the EXACT SAME flow from "Local E2E" above — but pointed at the **staging URL** (NOT localhost) → same assertions pass
- [ ] **Handoff message:** paste staging URL + verification screenshots into `progress.md`

---

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
- [ ] **Workflow Profile chosen:** the `## Workflow Profile` section above has A, B, or C filled in (NOT the placeholder)
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
  Uses the CODING PHASE TEMPLATE above — fill in the placeholders for this specific change.
-->
**Status:** pending

**Tasks:**
- [ ] Execute the plan step by step
- [ ] Write code to files before executing
- [ ] Update `progress.md` after each significant change

**Done when** (apply the CODING PHASE TEMPLATE criteria above based on Workflow Profile):
- [ ] **Always required (Profile A & B):** all 7 items from the "Always required" block above — local code clean, unit tests pass, local E2E passes, committed, pushed, PR opened, CI green
- [ ] **Profile A → STOP:** reviewers requested + handoff in `progress.md`
- [ ] **Profile B → continue:** merged to staging, CI/CD green, deployed, staging E2E re-run with same assertions, handoff in `progress.md`
- [ ] **Profile C only:** code is local, no PR needed — replace above with: `<exact deliverable file>` exists and matches Goal

### Phase 4: Testing & Verification
<!-- 
  WHAT: Verify everything works and meets requirements.
  
  ⚠ ANTI-SUBSTITUTION RULE:
    Each "Done when" item below names a SPECIFIC test method (unit / integration / E2E).
    DO NOT substitute a cheaper test for the named one.
    Example violation: criterion says "Selenium E2E on staging URL" → agent runs only pytest → marks ✅.
    A unit test passing is NOT evidence that the E2E criterion is met.
    Local E2E passing is NOT evidence that staging E2E is met (Profile B).
-->
**Status:** pending

**Tasks:**
- [ ] Run all named verifications below
- [ ] Document test results in `progress.md` (include exact commands and observable output)
- [ ] Fix any issues found, then re-run the failing verification

**Done when** (each criterion names its tool + assertion — do not swap tools or environments):
- [ ] **Unit-level:** `<exact test command>` → all relevant tests pass
- [ ] **Integration-level:** `<service / curl / API call against localhost>` → response matches `<expected shape/value>`
- [ ] **Local E2E:** `<Selenium MCP / Playwright / manual UI walkthrough against localhost>` → user sees `<exact observable state>` AND backend stores `<exact field=value>`
- [ ] **Profile B only — Staging E2E re-run:** the SAME flow above but against the **staging URL** → same assertions pass (do NOT skip; localhost passing does not imply staging passes — config drift, env vars, migrations can break it)
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
- [ ] **Profile A handoff complete:** PR URL + reviewer list shared with user — agent stops here
- [ ] **Profile B handoff complete:** staging URL + staging E2E evidence + readiness for prod-promotion shared with user — agent stops here
- [ ] **Profile C handoff complete:** deliverable file path + summary shared with user

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
