#!/usr/bin/env bash
# plan-files: resolve the true workspace root for hook scripts.
#
# Usage: resolve-project-root.sh [START_DIR]   (default START_DIR: $PWD)
#        Always prints exactly one absolute path and exits 0.
#        resolve-project-root.sh --accepts-state ROOT
#        Exits 0 when ROOT may hold hook logs and session state: it has a
#        `.plan-files` pointer, a `tmp/plan-files` directory, or a `.git`
#        entry. A root reached only through tier 4 below has none of these,
#        and hooks must not litter it with a `tmp/` tree.
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
#   2. Otherwise, walk upward the same way from the host-declared project
#      directory (CLAUDE_PROJECT_DIR, which Claude Code sets for every hook).
#      Claude Code runs hooks in the session's drifting shell cwd and records
#      it as a physical path. When `<root>/tmp` is a symlink to storage
#      outside the project (for example Dropbox), a cwd under the plan
#      directory has no `.plan-files` ancestor at all, and resolving from it
#      would route the prompt to an empty stray root instead of the lease.
#   3. Otherwise, fall back to `git rev-parse --show-toplevel`, then walk up
#      through every enclosing git superproject
#      (`--show-superproject-working-tree`) so a cwd inside a *registered git
#      submodule* still resolves to the outermost superproject root instead of
#      the submodule's own toplevel.
#   4. Otherwise, fall back to START_DIR itself.

set -u

has_pointer() {
    # Accept the pre-rename pointer too, so an un-migrated workspace still
    # resolves to the same root instead of silently falling back to $PWD.
    [ -e "$1/.plan-files" ] || [ -e "$1/.plan-with-files" ]
}

if [ "${1:-}" = "--accepts-state" ]; then
    root=${2:-$PWD}
    has_pointer "$root" || [ -d "$root/tmp/plan-files" ] \
        || [ -d "$root/tmp/plan-with-files" ] || [ -e "$root/.git" ]
    exit
fi

start=${1:-$PWD}

# outermost_pointer DIR — farthest ancestor of DIR (inclusive) with a pointer.
outermost_pointer() {
    local dir=$1 outermost="" parent
    while :; do
        has_pointer "$dir" && outermost=$dir
        [ "$dir" = "/" ] && break
        parent=$(dirname "$dir")
        [ "$parent" = "$dir" ] && break
        dir=$parent
    done
    [ -n "$outermost" ] && printf '%s' "$outermost"
}

# Tier 1: existing plan pointer file, farthest (outermost) ancestor wins.
# Tier 2: the same walk from the host-declared project directory.
for dir in "$start" "${CLAUDE_PROJECT_DIR:-}"; do
    [ -n "$dir" ] || continue
    if root=$(outermost_pointer "$dir"); then
        printf '%s' "$root"
        exit 0
    fi
done

# Tier 3: git toplevel, walked out through every enclosing superproject.
if root=$(git -C "$start" rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ]; then
    while super=$(git -C "$root" rev-parse --show-superproject-working-tree 2>/dev/null) && [ -n "$super" ]; do
        root=$super
    done
    printf '%s' "$root"
    exit 0
fi

# Tier 4: no signal found anywhere — use the starting directory as-is.
printf '%s' "$start"
