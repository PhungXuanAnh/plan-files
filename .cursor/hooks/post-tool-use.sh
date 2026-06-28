#!/bin/bash
# planning-with-files: Post-tool-use hook for Cursor
# Reminds the agent to update tasks.md after file modifications.
# Debounced: emits at most once per 60 seconds to suppress parallel-call noise.

DEBOUNCE_SECS=60
TS_FILE="tmp/hook-logs/plan-with-files/cursor-nudge-ts"
LOCK_FILE="${TS_FILE}.lock"

if [ -f tasks.md ]; then
    mkdir -p "tmp/hook-logs/plan-with-files" 2>/dev/null || true
    EMIT=false
    {
        flock -x 9 || true
        NOW=$(date +%s)
        LAST=0
        [ -f "$TS_FILE" ] && LAST=$(cat "$TS_FILE" 2>/dev/null || echo 0)
        LAST=${LAST:-0}
        if [ $(( NOW - LAST )) -ge "$DEBOUNCE_SECS" ]; then
            EMIT=true
            printf '%s' "$NOW" > "$TS_FILE"
        fi
    } 9>>"$LOCK_FILE" 2>/dev/null || true

    if [ "$EMIT" = "true" ]; then
        echo "[planning-with-files] Update tasks.md with what you just did. If a phase is now complete, update tasks.md status. Read decisions.md before changing user decisions."
    fi
fi
exit 0
