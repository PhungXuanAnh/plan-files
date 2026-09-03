#!/usr/bin/env bash
set -u
REPO_ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
BIND_TOOL="$REPO_ROOT/.claude/hooks/plan-files/scripts/bind-session.sh"
exec bash "$REPO_ROOT/skills/plan-files/scripts/hook-user-prompt-submit.sh" claude "$REPO_ROOT" "$BIND_TOOL"
