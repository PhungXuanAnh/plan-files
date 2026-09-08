# Observing Long Planning Runs

Use the reporter after a fixture or real planning session:

```bash
python3 <plan-files-skill>/scripts/observe.py --project-root <project>
```

The canonical reporter is recognized as read-only, including through an installed skill symlink, so it remains usable after finalization. A different script named `observe.py` or a reporter call chained to a mutation does not inherit that allowance.

Run the deterministic isolated comparison with either output format:

```bash
make behavioral-eval
python3 <plan-files-skill>/scripts/behavioral_eval.py --json
```

The evaluator creates its project under a temporary directory, forces a 12-to-13 phase rollover, rebinds a new session, checks both complete and deliberately broken restore state, probes real PostTool/Stop hooks, and removes the fixture afterward. It compares planning disabled, the legacy unbounded overview, and the revised bounded packet under the pinned values reported in its output. `restorable_context` is a structural recovery proxy, not a claim about model-semantic recall.

Add `--rollout <rollout.jsonl>` when measuring Codex/ChatGPT turn behavior. Use `--json` for comparison scripts.

Interpret the signals separately:

- `first_final_seconds` measures when the backend first tried to finish. It is diagnostic, not a correctness target.
- `stop_continuations` measures how often Stop enforcement resumed that turn.
- A changed semantic fingerprint after a continuation is productive progress.
- `max_no_progress_streak >= 2` means repeated finals are cycling without item/phase/evidence progress.
- `tool_classes` and `max_risk_score` explain stale pressure. Read-only exploration and plan maintenance have zero semantic weight; likely evidence and operational mutations raise risk.
  Scoped shell invocations of planning helpers also count as plan maintenance, even without a shell write verb. Chaining unrelated work or targeting another plan does not qualify.
- `unknown` stays conservative for execution gating, but PostTool counts it separately from recognized evidence/mutation risk. Unknown activity cannot cross the early risk threshold. After the age limit (180 seconds by default), unknown-only activity emits a conditional `CHECKPOINT REVIEW`; it does not assert stale evidence. `max_unknown_count` and `checkpoint_review_events` expose this distinction. Reviews share the ten-minute repeat limit and reset on plan progress.
- `stale_events` means risk/age crossed policy while the Active Item did not change; inspect whether its evidence predicate is already true. `max_unchanged_tools` alone is diagnostic volume, not staleness.
- `injected_chars`, `injected_bytes`, and `debounced_events` quantify hook context cost; `stop_continuations`/`output_chars` quantify enforced resumes.
- Healthy execution advances Active Item shortly after evidence appears, resets the no-progress count, and reaches a settled plan even if the backend attempted an early final.

For controlled comparisons, pin the model/effort, Codex version, bridge revision, skill revision, prompt, and fixture. Run several repetitions because first-final timing is stochastic. Compare planning disabled, the current policy, and the revised item-aware policy only on safe local/mock fixtures; production mutations are not required.

PreTool logs one `decision=` line for every outcome, allows included, so a permitted routing/discussion/repair call is distinguishable from a call the gate never saw. Both JSON reporters use schema version 1. Scope telemetry hashes task/session identifiers and never logs raw hook input. `stop_risk_advisories` counts emitted Stop advisories; healthy advisories share semantic/time debounce while unresolved faults repeat. `redundant_reminders` measures repeated full goal/item context, and `read_only_false_reminders` measures inappropriate checkpoint/stale pressure. `read_only_silent_after_first` also catches repeated generic Stop noise after unchanged reads. New counters are additive; older PostTool lines without semantic class/risk remain readable as `legacy`/zero values.

The private PostTool cache uses `risk_schema=2` and adds `unchanged_unknown_count` and `last_review_ts`. On the first invocation with an older cache, mixed risk and warning-repeat state reset under the existing lock; the plan fingerprint and checkpoint timestamp remain intact. Reviews and stale warnings use separate repeat timestamps so later evidence can still escalate a prior unknown-only review. Older telemetry defaults the new unknown/review counters to zero. `stale_events` continues to count recognized-risk warnings separately from unknown-only reviews.

## Interaction-cost regression (2026-09-08)

The same `long-run-v2` eight-call probe, immediately before and after debouncing healthy Stop/finalization advisories, emitted 8 versus 3 context packets: 2,937 versus 2,262 characters (23.0% less). The five unchanged reads after the initial context became silent. Missed-checkpoint detection and actionable Stop enforcement still passed. This measures deterministic hook output, not model token billing or total task latency.

For real-session audits, count unique tool-use IDs and separate planning commands, task work, hook context, and recovery retries. Do not double-count rendered attachments or streaming message usage. Report hook-runtime sums separately from wall time because concurrent calls overlap. Compare direct Markdown and CLI workflows by their total interaction cost, not just the bytes in one successful output.

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
