#!/usr/bin/env bash
# plan-files: resolve the true workspace root for hook scripts.
#
# Usage: resolve-project-root.sh [START_DIR]   (default START_DIR: $PWD)
# Always prints exactly one absolute path and exits 0.
#
# Resolution order:
#   1. Walk upward from START_DIR collecting every ancestor that has a
#      `.plan-files` pointer file (the file the skill already keeps at a
#      project root to name the active task — present, even empty, is
#      enough; no separate marker file is needed). FARTHEST (outermost)
#      match wins: a `.plan-files` can legitimately exist at more than
#      one nesting level (an outer workspace-level plan, plus a leftover one
#      inside a child repo), and picking the nearest one would silently
#      resolve to the wrong plan whenever cwd drifts into — or a session
#      simply starts inside — that child repo, which is the failure mode
#      this resolver exists to prevent. For a brand new workspace with no
#      `.plan-files` anywhere yet, `touch .plan-files` at the
#      intended root once, before creating the first task there.
#   2. Otherwise, fall back to `git rev-parse --show-toplevel`, then walk up
#      through every enclosing git superproject
#      (`--show-superproject-working-tree`) so a cwd inside a *registered git
#      submodule* still resolves to the outermost superproject root instead of
#      the submodule's own toplevel.
#   3. Otherwise, fall back to START_DIR itself.

set -u

start=${1:-$PWD}

# Tier 1: existing plan pointer file, farthest (outermost) ancestor wins.
dir=$start
outermost=""
while :; do
    # Accept the pre-rename pointer too, so an un-migrated workspace still
    # resolves to the same root instead of silently falling back to $PWD.
    { [ -e "$dir/.plan-files" ] || [ -e "$dir/.plan-with-files" ]; } && outermost=$dir
    [ "$dir" = "/" ] && break
    parent=$(dirname "$dir")
    [ "$parent" = "$dir" ] && break
    dir=$parent
done
if [ -n "$outermost" ]; then
    printf '%s' "$outermost"
    exit 0
fi

# Tier 2: git toplevel, walked out through every enclosing superproject.
if root=$(git -C "$start" rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ]; then
    while super=$(git -C "$root" rev-parse --show-superproject-working-tree 2>/dev/null) && [ -n "$super" ]; do
        root=$super
    done
    printf '%s' "$root"
    exit 0
fi

# Tier 3: no signal found anywhere — use the starting directory as-is.
printf '%s' "$start"
