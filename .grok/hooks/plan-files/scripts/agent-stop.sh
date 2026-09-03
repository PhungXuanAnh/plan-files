#!/usr/bin/env bash
set -u
set -o pipefail 2>/dev/null || true

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
INPUT=$(cat)
printf '%s' "$INPUT" | grok_input_has_verified_session || { printf '{}'; exit 0; }
REASON=$(printf '%s' "$INPUT" | grok_input_string reason reason 2>/dev/null || true)

# Grok also emits observe-only Stop events while closing a session. Do not let
# those mutate finish/no-progress state; only a genuine turn end is gateable.
if [ "$REASON" != "end_turn" ]; then
    printf '{}'
    exit 0
fi

printf '%s' "$INPUT" \
    | bash "$GROK_REPO_ROOT/skills/plan-files/scripts/hook-agent-stop.sh" \
        grok "$GROK_REPO_ROOT" 1 top "$GROK_ADAPTER_DIR/bind-session.sh"
