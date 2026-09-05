#!/usr/bin/env bash
set -u
set -o pipefail 2>/dev/null || true

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
INPUT=$(cat)
printf '%s' "$INPUT" | grok_input_has_verified_session || { printf '{}'; exit 0; }

# State updates (including first-write auto-claim) are required on every Grok
# version. Newer builds also deliver the emitted additionalContext; older
# builds safely ignore it, so correctness never depends on that delivery.
printf '%s' "$INPUT" \
    | bash "$GROK_REPO_ROOT/skills/plan-files/scripts/hook-post-tool-use.sh" \
        grok "$GROK_REPO_ROOT" "$GROK_ADAPTER_DIR/bind-session.sh"
