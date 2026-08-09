#!/bin/bash
# Keep trusted hot plan state visible before Cursor tools; never block.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=planning-common.sh
source "$SCRIPT_DIR/planning-common.sh"

if [ -f "$PLAN_FILE" ]; then
    awk '
      /^## (Goal|Current Phase|Resume Checkpoint)[[:space:]]*$/ { capture=1; print; next }
      /^## / { capture=0 }
      capture { print }
    ' "$PLAN_FILE" >&2
fi

echo '{"decision":"allow"}'
exit 0
