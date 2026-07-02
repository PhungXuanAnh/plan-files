# Reference: Manus Context Engineering Principles

This skill is based on context engineering principles from Manus-style agent workflows: use files as persistent working memory, keep the active plan in attention, and preserve enough history to avoid repeating mistakes.

## Core Principles

### 1. Filesystem as External Memory

```
Context Window = RAM (volatile, limited)
Filesystem = Disk (persistent, durable)
```

Anything important should be written to disk. The active task folder contains:

| File | Purpose |
|------|---------|
| `tasks.md` | Goal, current phase, phase statuses, concise progress, errors, verification |
| `findings.md` | Discoveries, research, browser/search results, source references |
| `decisions.md` | Active user decisions, superseded decisions, open decision questions |

### 2. Manipulate Attention Through Recitation

After many tool calls, original goals drift out of attention. Re-read `tasks.md` before major decisions so the goal and current phase are recent again.

Also re-read `decisions.md` before changing direction. User choices are more stable than tool observations and should not be overwritten from memory.

### 3. Keep the Wrong Stuff, But Compact It

Failed attempts and old decisions help prevent repeated mistakes. Keep them, but compress stale detail:

- Recent/current errors stay explicit in `tasks.md`.
- Resolved or old errors become short summaries.
- Changed user decisions move to `## Superseded Decisions` in `decisions.md`.
- Large research notes in `findings.md` become summaries plus links/paths to sources.

### 4. Compression Must Be Restorable

When compacting:

- Keep URLs even if web content is dropped.
- Keep file paths when dropping long snippets.
- Keep exact commands/checks that prove completion.
- Keep active decisions and blockers.
- Never raw-truncate.

### 5. Isolate Untrusted Content

External content belongs in `findings.md`, not `tasks.md` or `decisions.md`. The hook re-injects `## Goal` and `## Current Phase` from `tasks.md`, so those sections must stay trusted and concise.

## File Lifecycle

| Event | Action |
|-------|--------|
| Start task | Create `tasks.md`, `findings.md`, `decisions.md` |
| Resume task | Read all 3 files |
| Start phase | Update `tasks.md` current phase and status |
| Discover information | Update `findings.md` |
| User decides/changes direction | Read then update `decisions.md` |
| Complete phase | Update `tasks.md` status, progress, verification |
| File exceeds its budget (`tasks.md`/`decisions.md` 150, `findings.md` 250) | Compact with judgment before continuing |

## Compaction Guidance

Per-file line budgets: `tasks.md` 150, `findings.md` 250, `decisions.md` 150. These are token-budget guidelines, not hard data-retention rules.

Prefer:

- `tasks.md`: compact `## Progress Notes` first and hardest (keep only active/recent entries), then collapse completed phases to a one-line outcome — but keep each `### Phase N:` heading and its `- **Status:**` line verbatim.
- `findings.md`: summarize old findings and keep source references.
- `decisions.md`: keep active decisions explicit; compress superseded history.

Avoid:

- Blind truncation.
- Removing unresolved blockers.
- Removing active user decisions.
- Removing exact verification commands.

## Reboot Test

If you can answer all 5, your context is solid:

- Where am I? `## Current Phase` in `tasks.md`
- Where am I going? Remaining phases in `tasks.md`
- What's the goal? `## Goal` in `tasks.md`
- What have I learned? `findings.md`
- What has the user decided? `decisions.md`

## Source

Based on Manus context-engineering ideas:
https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus
