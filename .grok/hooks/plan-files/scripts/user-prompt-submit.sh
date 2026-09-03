#!/usr/bin/env bash
set -u
set -o pipefail 2>/dev/null || true

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
INPUT=$(cat)
printf '%s' "$INPUT" | grok_input_has_verified_session || { printf '{}'; exit 0; }
BIND_TOOL="$GROK_ADAPTER_DIR/bind-session.sh"

# Grok does not deliver additionalContext from an allowing UserPromptSubmit
# hook. Keep the shared pending transition and surface its context from the
# next PreToolUse denial or pending Stop instead.
printf '%s' "$INPUT" \
    | bash "$GROK_REPO_ROOT/skills/plan-files/scripts/hook-user-prompt-submit.sh" \
        grok "$GROK_REPO_ROOT" "$BIND_TOOL" >/dev/null
printf '{}'
