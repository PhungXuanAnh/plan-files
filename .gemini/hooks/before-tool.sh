#!/bin/bash
# Inject trusted hot sections before Gemini tools.

cat >/dev/null
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=planning-common.sh
source "$SCRIPT_DIR/planning-common.sh"
[ -f "$PLAN_FILE" ] || { echo '{}'; exit 0; }

CONTEXT=$(awk '
  /^## (Goal|Current Phase|Resume Checkpoint)[[:space:]]*$/ { capture=1; print; next }
  /^## / { capture=0 }
  capture { print }
' "$PLAN_FILE" 2>/dev/null)
[ -n "$CONTEXT" ] || { echo '{}'; exit 0; }
ESCAPED=$(printf '%s' "$CONTEXT" | gemini_json_string)
echo "{\"systemMessage\":$ESCAPED}"
exit 0
