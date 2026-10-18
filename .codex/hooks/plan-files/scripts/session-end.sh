#!/usr/bin/env bash
set -u
REPO_ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
# Codex terminates native tools before dispatching its exit event.
exec bash "$REPO_ROOT/skills/plan-files/scripts/hook-session-end.sh" codex --native-tools-stopped-on other
