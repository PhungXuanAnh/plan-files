#!/bin/bash
# planning-with-files: SessionEnd hook for Gemini CLI
# Checks all phases are complete before session ends.
# Receives JSON on stdin, must output ONLY JSON to stdout.

INPUT=$(cat)

ROOT="${GEMINI_PROJECT_DIR:-.}"
TASK_ID=$(cat "$ROOT/.plan-with-files" 2>/dev/null || true)

case "$TASK_ID" in
    ""|.|*/*|*..*|*" "*)
        echo '{}'
        exit 0
        ;;
esac

TASKS_FILE="$ROOT/tmp/plan-with-files/$TASK_ID/tasks.md"

if [ ! -f "$TASKS_FILE" ]; then
    echo '{}'
    exit 0
fi

if grep -Eq 'Status:\*\*[[:space:]]*(pending|in_progress)|\[(pending|in_progress)\]' "$TASKS_FILE"; then
    RESULT="[planning-with-files] Active task '$TASK_ID' has pending or in-progress phases. Update tasks.md before stopping, or mark blocked work as deferred with a reason."
    PYTHON=$(command -v python3 || command -v python)
    ESCAPED=$($PYTHON -c "import sys,json; print(json.dumps(sys.stdin.read(), ensure_ascii=False))" <<< "$RESULT" 2>/dev/null || echo "\"$RESULT\"")
    echo "{\"systemMessage\":$ESCAPED}"
    exit 0
fi

echo '{}'
exit 0
