#!/usr/bin/env bash
# Forwards to the canonical resolver in skills/planning-with-files/scripts/.
# Kept alongside the other Claude Code hook scripts (rather than only under
# skills/) so the global settings.json wrapper command can reach it through
# the same $HOME/.claude/hooks/planning-with-files symlink the other hook
# scripts already rely on, without a separate dependency on the skill being
# installed too.
set -u
REPO_ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
exec bash "$REPO_ROOT/skills/planning-with-files/scripts/resolve-project-root.sh" "$@"
