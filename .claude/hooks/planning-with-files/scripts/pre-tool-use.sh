#!/usr/bin/env bash
set -u
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
exec bash "$REPO_ROOT/skills/planning-with-files/scripts/pre-tool-gate.sh" \
    claude "$REPO_ROOT/.claude/hooks/planning-with-files/scripts/bind-session.sh" "Claude Code"
