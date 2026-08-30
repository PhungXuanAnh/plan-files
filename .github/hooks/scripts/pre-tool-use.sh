#!/usr/bin/env bash
set -u
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
exec bash "$REPO_ROOT/skills/plan-files/scripts/pre-tool-gate.sh" \
    copilot "$REPO_ROOT/.github/hooks/scripts/bind-session.sh" "GitHub Copilot"
