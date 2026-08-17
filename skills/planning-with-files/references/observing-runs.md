# Observing Long Planning Runs

Use the reporter after a fixture or real planning session:

```bash
python3 <planning-with-files-skill>/scripts/observe.py --project-root <project>
```

Add `--rollout <rollout.jsonl>` when measuring Codex/ChatGPT turn behavior. Use `--json` for comparison scripts.

Interpret the signals separately:

- `first_final_seconds` measures when the backend first tried to finish. It is diagnostic, not a correctness target.
- `stop_continuations` measures how often Stop enforcement resumed that turn.
- A changed semantic fingerprint after a continuation is productive progress.
- `max_no_progress_streak >= 2` means repeated finals are cycling without item/phase/evidence progress.
- `stale_events` or rising `max_unchanged_tools` means the Active Item has not been checkpointed; inspect whether its evidence predicate is already true.
- Healthy execution advances Active Item shortly after evidence appears, resets the no-progress count, and reaches a settled plan even if the backend attempted an early final.

For controlled comparisons, pin the model/effort, Codex version, bridge revision, skill revision, prompt, and fixture. Run several repetitions because first-final timing is stochastic. Compare planning disabled, the current policy, and the revised item-aware policy only on safe local/mock fixtures; production mutations are not required.
