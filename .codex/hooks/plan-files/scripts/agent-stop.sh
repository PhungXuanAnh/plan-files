#!/usr/bin/env bash
set -u
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
exec bash "$REPO_ROOT/skills/plan-files/scripts/hook-agent-stop.sh" codex "$REPO_ROOT" 1 top "$REPO_ROOT/.codex/hooks/plan-files/scripts/bind-session.sh"
