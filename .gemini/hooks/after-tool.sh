#!/bin/bash
# planning-with-files: AfterTool hook for Gemini CLI
# Reminds the agent to update tasks.md after file writes.
# Reads stdin JSON, outputs JSON to stdout.

INPUT=$(cat)

PLAN_FILE="tasks.md"

if [ ! -f "$PLAN_FILE" ]; then
    echo '{}'
    exit 0
fi

echo '{"additionalContext":"[planning-with-files] Update tasks.md with what you just did. If a phase is now complete, update tasks.md status. Read decisions.md before changing user decisions."}'
exit 0
