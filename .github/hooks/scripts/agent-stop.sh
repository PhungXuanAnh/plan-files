#!/usr/bin/env bash
set -u
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
exec bash "$REPO_ROOT/skills/plan-files/scripts/hook-agent-stop.sh" copilot "$REPO_ROOT" 1 copilot "$REPO_ROOT/.github/hooks/scripts/bind-session.sh"
