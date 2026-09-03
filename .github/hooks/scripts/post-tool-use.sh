#!/usr/bin/env bash
set -u
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
exec bash "$REPO_ROOT/skills/plan-files/scripts/hook-post-tool-use.sh" copilot "$REPO_ROOT"
