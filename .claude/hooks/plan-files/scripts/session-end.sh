#!/usr/bin/env bash
set -u
REPO_ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
exec bash "$REPO_ROOT/skills/plan-files/scripts/hook-session-end.sh" claude
