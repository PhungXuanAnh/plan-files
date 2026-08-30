#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SOURCE="$REPO_ROOT/.codex/hooks.json.sample"
DEST="$TMP_DIR/hooks.json"
PROJECT="$TMP_DIR/non-git-project"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$PROJECT"

python3 "$REPO_ROOT/scripts/install-codex-hooks.py" "$SOURCE" "$DEST"
python3 "$REPO_ROOT/scripts/install-codex-hooks.py" "$SOURCE" "$DEST"

# Derive the checkout path instead of hardcoding it, so renaming or relocating
# this clone does not break the suite.
PRE_TOOL_COMMAND=$(python3 - "$DEST" "$REPO_ROOT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    hooks = json.load(handle)["hooks"]
repo_root = sys.argv[2]

for event in ("UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"):
    command = hooks[event][0]["hooks"][0]["command"]
    assert repo_root in command, command
    assert "skills/plan-files/scripts/resolve-project-root.sh" in command, command

print(hooks["PreToolUse"][0]["hooks"][0]["command"])
PY
)

HOOK_STDERR="$TMP_DIR/hook.stderr"
HOOK_OUTPUT=$(cd "$PROJECT" && printf '%s\n' \
    '{"session_id":"codex-global","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"README.md"}}' \
    | PLANNING_DISABLED=1 bash -c "$PRE_TOOL_COMMAND" 2>"$HOOK_STDERR")

[ "$HOOK_OUTPUT" = "{}" ] || fail "non-Git PreToolUse hook returned: $HOOK_OUTPUT"
[ ! -s "$HOOK_STDERR" ] || fail "non-Git PreToolUse hook wrote: $(cat "$HOOK_STDERR")"

echo "codex global hook installer tests: PASS"
