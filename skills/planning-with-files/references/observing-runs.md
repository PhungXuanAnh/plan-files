# Observing Long Planning Runs

Use the reporter after a fixture or real planning session:

```bash
python3 <planning-with-files-skill>/scripts/observe.py --project-root <project>
```

Run the deterministic isolated comparison with either output format:

```bash
make behavioral-eval
python3 <planning-with-files-skill>/scripts/behavioral_eval.py --json
```

The evaluator creates its project under a temporary directory, forces a 12-to-13 phase rollover, rebinds a new session, checks both complete and deliberately broken restore state, probes real PostTool/Stop hooks, and removes the fixture afterward. It compares planning disabled, the legacy unbounded overview, and the revised bounded packet under the pinned values reported in its output. `restorable_context` is a structural recovery proxy, not a claim about model-semantic recall.

Add `--rollout <rollout.jsonl>` when measuring Codex/ChatGPT turn behavior. Use `--json` for comparison scripts.

Interpret the signals separately:

- `first_final_seconds` measures when the backend first tried to finish. It is diagnostic, not a correctness target.
- `stop_continuations` measures how often Stop enforcement resumed that turn.
- A changed semantic fingerprint after a continuation is productive progress.
- `max_no_progress_streak >= 2` means repeated finals are cycling without item/phase/evidence progress.
- `tool_classes` and `max_risk_score` explain stale pressure. Read-only exploration and plan maintenance have zero semantic weight; likely evidence and operational mutations raise risk.
- `stale_events` means risk/age crossed policy while the Active Item did not change; inspect whether its evidence predicate is already true. `max_unchanged_tools` alone is diagnostic volume, not staleness.
- `injected_chars`, `injected_bytes`, and `debounced_events` quantify hook context cost; `stop_continuations`/`output_chars` quantify enforced resumes.
- Healthy execution advances Active Item shortly after evidence appears, resets the no-progress count, and reaches a settled plan even if the backend attempted an early final.

For controlled comparisons, pin the model/effort, Codex version, bridge revision, skill revision, prompt, and fixture. Run several repetitions because first-final timing is stochastic. Compare planning disabled, the current policy, and the revised item-aware policy only on safe local/mock fixtures; production mutations are not required.

Both JSON reporters use schema version 1. Scope telemetry hashes task/session identifiers and never logs raw hook input. New counters are additive; older PostTool lines without semantic class/risk remain readable as `legacy`/zero values.

## Recorded comparison (2026-08-28)

These baselines were captured before the corresponding improvements. Use the deterministic `long-run-v2` fixture for like-for-like packet/restore/reminder comparisons; historical hook-log totals have different event counts, so compare their normalized rates rather than raw totals.

| Metric | Recorded baseline | Revised measurement | Result |
|---|---:|---:|---|
| Entrypoint | 19,454 bytes / 2,695 words | 9,364 bytes / 1,194 words | 51.9% fewer bytes; 55.7% fewer words |
| Same-fixture resume packet | 9,793 chars (legacy unbounded) | 4,096 chars | 58.2% smaller; hard cap met |
| Structural restore proxy | 4/5 fields | 5/5 fields | all fields restorable; this is not model-semantic recall |
| Read-only false reminders | 5/5 unchanged reads (legacy policy simulation) | 0/5 | eliminated in the controlled sequence |
| Deliberate missed checkpoint | not risk-classified | detected after two evidence-likely calls | required pressure retained |
| Hook injection volume | 59 injections / 42,666 chars (723 chars/injection) | 3/8 calls / 1,740 chars (580 chars/injection) | 19.8% lower normalized size in the controlled probe |
| Historical stale rate | 103/142 PostTool events (72.5%) | controlled read-only false-stale rate 0/5 | historical and controlled denominators differ; do not compare raw totals |

The immediate pre-split `SKILL.md` measurement was 19,752 bytes / 2,725 words; the revised entrypoint is also 52.6% / 56.2% smaller than that later snapshot. The original audit resume packet was 8,681 characters on a different fixture; `long-run-v2` reports the same-fixture legacy value above to avoid attributing fixture growth to the packet policy.
