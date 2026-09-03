#!/usr/bin/env bash
set -u
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
BIND_TOOL="$REPO_ROOT/.codex/hooks/plan-files/scripts/bind-session.sh"
exec bash "$REPO_ROOT/skills/plan-files/scripts/hook-user-prompt-submit.sh" codex "$REPO_ROOT" "$BIND_TOOL"
