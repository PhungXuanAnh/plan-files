#!/usr/bin/env bash
set -u
set -o pipefail 2>/dev/null || true

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
INPUT=$(cat)
printf '%s' "$INPUT" | grok_input_has_verified_session || { printf '{}'; exit 0; }
REASON=$(printf '%s' "$INPUT" | grok_input_string reason reason 2>/dev/null || true)

# Shutdown is observe-only: release authority through the shared lifecycle core.
if [ "$REASON" = "shutdown" ] || [ "$REASON" = "channel_closed" ]; then
    printf '%s' "$INPUT" | bash "$GROK_REPO_ROOT/skills/plan-files/scripts/hook-session-end.sh" grok
    exit 0
fi
# Only a genuine turn end is gateable.
if [ "$REASON" != "end_turn" ]; then
    printf '{}'
    exit 0
fi

printf '%s' "$INPUT" \
    | bash "$GROK_REPO_ROOT/skills/plan-files/scripts/hook-agent-stop.sh" \
        grok "$GROK_REPO_ROOT" 1 top "$GROK_ADAPTER_DIR/bind-session.sh"
