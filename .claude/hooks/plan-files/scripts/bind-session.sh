#!/usr/bin/env bash
set -u
# Resolve the real file: `make install` also links this adapter as pwf-bind-claude.
REPO_ROOT=$(CDPATH= cd -P -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../../../.." && pwd)
exec bash "$REPO_ROOT/skills/plan-files/scripts/hook-bind-session.sh" \
    claude "$REPO_ROOT" "${PWF_SESSION_ID:-}" "$@"
