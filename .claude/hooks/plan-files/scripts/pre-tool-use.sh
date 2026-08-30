#!/usr/bin/env bash
set -u
REPO_ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
exec bash "$REPO_ROOT/skills/plan-files/scripts/pre-tool-gate.sh" \
    claude "$REPO_ROOT/.claude/hooks/plan-files/scripts/bind-session.sh" "Claude Code"
