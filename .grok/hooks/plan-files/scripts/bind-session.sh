#!/usr/bin/env bash
set -u

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
exec bash "$GROK_REPO_ROOT/skills/plan-files/scripts/hook-bind-session.sh" \
    grok "$GROK_REPO_ROOT" "${GROK_SESSION_ID:-}" "$@"
