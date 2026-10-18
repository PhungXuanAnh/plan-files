#!/usr/bin/env bash
set -u
REPO_ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
# Exit drains native shell cleanup; clear/resume may preserve background work.
exec bash "$REPO_ROOT/skills/plan-files/scripts/hook-session-end.sh" claude --native-tools-stopped-on prompt_input_exit,logout,bypass_permissions_disabled,other
