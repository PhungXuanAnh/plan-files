#!/bin/bash
# planning-with-files: SessionStart hook for Gemini CLI
# Injects active pointer-based planning context.
# Receives JSON on stdin, must output ONLY JSON to stdout.
# Stderr is for logging only.

INPUT=$(cat)

ROOT="${GEMINI_PROJECT_DIR:-.}"
TASK_ID=$(cat "$ROOT/.plan-with-files" 2>/dev/null || true)

case "$TASK_ID" in
    ""|.|*/*|*..*|*" "*)
        echo '{}'
        exit 0
        ;;
esac

PLAN_DIR="$ROOT/tmp/plan-with-files/$TASK_ID"
TASKS_FILE="$PLAN_DIR/tasks.md"
DECISIONS_FILE="$PLAN_DIR/decisions.md"

if [ ! -f "$TASKS_FILE" ]; then
    echo '{}'
    exit 0
fi

PYTHON=$(command -v python3 || command -v python)
CONTEXT=$(printf '[planning-with-files] Active plan: %s\n\n=== tasks.md ===\n' "$TASK_ID"; head -80 "$TASKS_FILE"; if [ -f "$DECISIONS_FILE" ]; then printf '\n=== decisions.md ===\n'; head -60 "$DECISIONS_FILE"; fi)

if [ -n "$PYTHON" ]; then
    ESCAPED=$($PYTHON -c "import sys,json; print(json.dumps(sys.stdin.read(), ensure_ascii=False))" <<< "$CONTEXT" 2>/dev/null || echo "\"[planning-with-files] Active plan detected. Read tasks.md, decisions.md, and findings.md.\"")
    echo "{\"hookSpecificOutput\":{\"additionalContext\":$ESCAPED}}"
else
    echo '{"hookSpecificOutput":{"additionalContext":"[planning-with-files] Active plan detected. Read tasks.md, decisions.md, and findings.md before proceeding."}}'
fi

exit 0
