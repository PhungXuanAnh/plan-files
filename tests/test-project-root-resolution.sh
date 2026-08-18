#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RESOLVER="$REPO_ROOT/skills/planning-with-files/scripts/resolve-project-root.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; }

# --- Tier 2 fallback: real git submodule, no .plan-with-files anywhere ------
SUB="$TEST_DIR/sub"
mkdir -p "$SUB"
(cd "$SUB" && git init -q && git commit -q --allow-empty -m init)
WS1="$TEST_DIR/ws1"
git init -q "$WS1"
(cd "$WS1" && git -c protocol.file.allow=always submodule add -q "$SUB" mod && git commit -q -m add)
assert_eq "$(bash "$RESOLVER" "$WS1/mod")" "$WS1" \
    "submodule cwd must resolve to the superproject root, not the submodule's own toplevel"

# --- Tier 1: plain non-git folder with independent repo checkouts, only the
#     outer folder has a .plan-with-files pointer ----------------------------
WS2="$TEST_DIR/ws2"
mkdir -p "$WS2/repoA"
(cd "$WS2/repoA" && git init -q && git commit -q --allow-empty -m init)
printf 'SOME-TASK\n' > "$WS2/.plan-with-files"
assert_eq "$(bash "$RESOLVER" "$WS2/repoA")" "$WS2" \
    "a plain non-git folder's existing .plan-with-files must resolve as root even with no git relationship to the inner repo"

# --- Tier 1 ambiguity: BOTH the outer root and an inner child repo have their
#     own .plan-with-files (for example because a session was once opened
#     directly inside the child repo). Outermost must win so the outer
#     workspace-level plan stays authoritative whenever cwd drifts into — or
#     a session simply starts inside — the child, instead of silently
#     resolving to the child's (possibly stale) plan. ------------------------
WS3="$TEST_DIR/ws3"
mkdir -p "$WS3/viralize"
printf 'WORKSPACE-TASK\n' > "$WS3/.plan-with-files"
printf 'CHILD-ONLY-TASK\n' > "$WS3/viralize/.plan-with-files"
(cd "$WS3/viralize" && git init -q && git commit -q --allow-empty -m init)
assert_eq "$(bash "$RESOLVER" "$WS3/viralize")" "$WS3" \
    "when both an outer and inner .plan-with-files exist, the outermost must win"

# --- A session opened directly inside a child repo that is nested in a
#     workspace with no .plan-with-files of its own must still resolve to the
#     outer workspace root, not the child's own toplevel. --------------------
WS4="$TEST_DIR/ws4"
mkdir -p "$WS4/viralize"
printf 'WORKSPACE-TASK\n' > "$WS4/.plan-with-files"
(cd "$WS4/viralize" && git init -q && git commit -q --allow-empty -m init)
assert_eq "$(bash "$RESOLVER" "$WS4/viralize")" "$WS4" \
    "opening a session directly inside a nested child repo must still resolve to the outer workspace root"

# --- A repo genuinely opened standalone (no workspace ancestor at all) must
#     resolve to its own git toplevel, independent of any other project. -----
WS5="$TEST_DIR/standalone-repo"
mkdir -p "$WS5"
(cd "$WS5" && git init -q && git commit -q --allow-empty -m init)
assert_eq "$(bash "$RESOLVER" "$WS5")" "$WS5" \
    "a standalone repo with no workspace ancestor must resolve to its own root"

# --- Bootstrap for a brand new, non-git-related workspace with no
#     .plan-with-files anywhere yet: an empty .plan-with-files at the intended
#     root (created once, before the first task) is enough — no separate
#     marker file is needed. --------------------------------------------------
WS6="$TEST_DIR/ws6"
mkdir -p "$WS6/repoA"
(cd "$WS6/repoA" && git init -q && git commit -q --allow-empty -m init)
: > "$WS6/.plan-with-files"
assert_eq "$(bash "$RESOLVER" "$WS6/repoA")" "$WS6" \
    "an empty .plan-with-files at the intended root must resolve as root before any task exists"

# --- No signal anywhere: falls back to the starting directory itself -------
WS7="$TEST_DIR/ws7/deep/nested"
mkdir -p "$WS7"
assert_eq "$(bash "$RESOLVER" "$WS7")" "$WS7" \
    "with no .plan-with-files and no git repo, the resolver must fall back to the starting directory"

echo "project root resolution tests: PASS"
