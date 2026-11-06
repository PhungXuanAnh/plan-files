#!/usr/bin/env bash
set -u
# Resolve the real file: `make install` also links this adapter as pwf-bind-copilot.
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../../.." && pwd)
exec bash "$REPO_ROOT/skills/plan-files/scripts/hook-bind-session.sh" \
    copilot "$REPO_ROOT" "${COPILOT_AGENT_SESSION_ID:-}" "$@"
