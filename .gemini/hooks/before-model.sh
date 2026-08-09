#!/bin/bash
# Inject the exact Current Phase pointer before each Gemini model call.

cat >/dev/null
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=planning-common.sh
source "$SCRIPT_DIR/planning-common.sh"
[ -f "$PLAN_FILE" ] || { echo '{}'; exit 0; }

CURRENT_PHASE=$(current_phase_pointer "$PLAN_FILE")
[ -n "$CURRENT_PHASE" ] || { echo '{}'; exit 0; }
ESCAPED=$(printf '[planning-with-files] Current: %s' "$CURRENT_PHASE" | gemini_json_string)
echo "{\"additionalContext\":$ESCAPED}"
exit 0
