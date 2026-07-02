# Examples: Planning with Files in Action

## Example 1: Research Task

**User request:** "Research the benefits of morning exercise and write a summary"

### Loop 1: Create planning files
```bash
Write tasks.md
Write findings.md
Write decisions.md
```

```markdown
# Tasks: Morning Exercise Benefits Research

## Goal
Create a concise research summary on the benefits of morning exercise.

## Current Phase
Phase 1

## Phases

### Phase 1: Search and gather sources
- [ ] Search reputable sources
- [ ] Record source notes in findings.md
- **Status:** in_progress

### Phase 2: Synthesize findings
- [ ] Compare physical and mental health benefits
- [ ] Write summary
- **Status:** pending
```

### Loop 2: Research
```bash
Read tasks.md
Read decisions.md
WebSearch "morning exercise benefits"
Write findings.md              # external content goes here only
Edit tasks.md                  # mark Phase 1 complete when done
```

### Loop 3: Synthesize
```bash
Read tasks.md
Read decisions.md
Read findings.md
Write morning_exercise_summary.md
Edit tasks.md                  # update progress and phase status
```

---

## Example 2: Decision Change

**User request:** "Use SQLite." Later: "Actually use JSON; this should stay portable."

### decisions.md
```markdown
# Decisions

## Active Decisions
| ID | Decision | Rationale | Date |
|----|----------|-----------|------|
| D2 | Use JSON file storage | User changed direction; portability matters more than query support | 2026-06-28 |

## Superseded Decisions
| ID | Old Decision | Replaced By | Reason |
|----|--------------|-------------|--------|
| D1 | Use SQLite storage | D2 | User decided portability is more important |

## Open Decision Questions
- [ ] 
```

Before editing `decisions.md`, read it first. Do not silently delete D1; keeping the superseded row prevents confusion later.

---

## Example 3: Bug Fix Task

**User request:** "Fix the login bug in the authentication module"

### tasks.md
```markdown
# Tasks: Fix Login Bug

## Goal
Identify and fix the bug preventing successful login.

## Current Phase
Phase 2

## Phases

### Phase 1: Locate Failure
- [x] Reproduce login error
- [x] Locate authentication code
- **Status:** complete

### Phase 2: Implement Fix
- [ ] Fix root cause
- [ ] Run auth tests
- **Status:** in_progress

## Progress Notes
- Reproduced `TypeError: Cannot read property 'token' of undefined`.
- Root cause appears to be an unawaited user lookup.

## Errors Encountered
| Error | Attempt | Resolution |
|-------|---------|------------|
| Login TypeError | 1 | Inspect async user lookup before retrying |
```

### findings.md
```markdown
# Findings

## Research Findings
- Auth handler is in `src/auth/login.ts`.
- `validateToken()` receives undefined user object when lookup is not awaited.

## Resources
- `src/auth/login.ts`
- `tests/auth/login.test.ts`
```

---

## Example 4: Compaction

When a hook reports a planning file is over its budget (`tasks.md`/`decisions.md` 150, `findings.md` 250), compact before continuing — starting with `## Progress Notes`, then completed phases.

### Before
```markdown
## Progress Notes
- 60 old entries for completed phases...
- Current blocker: staging auth callback fails with 403.
```

### After
```markdown
## Progress Notes
- Completed setup, implementation, and local verification.
- Current blocker: staging auth callback fails with 403.
```

Compaction preserves current work, blockers, verification commands, recent errors, active decisions, and source references. It does not raw-truncate.

---

## Read-Before-Decide Pattern

Always refresh the active task and user decisions before important choices:

```bash
Read tasks.md
Read decisions.md
```

Use `findings.md` for detailed discoveries and external content. Use `decisions.md` only for durable user choices.
