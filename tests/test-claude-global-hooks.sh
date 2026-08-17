#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
NON_GIT_PROJECT="$TMP_DIR/non-git-project"
GIT_PROJECT="$TMP_DIR/git-project"
SETTINGS="$TEST_HOME/.claude/settings.json"
HOOKS="$TEST_HOME/.claude/hooks/planning-with-files"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$NON_GIT_PROJECT" "$GIT_PROJECT"
git -C "$GIT_PROJECT" init -q

HOME="$TEST_HOME" make -s -C "$REPO_ROOT" install-hook-claude-code >/dev/null
HOME="$TEST_HOME" make -s -C "$REPO_ROOT" install-hook-claude-code >/dev/null

[ "$(readlink "$SETTINGS")" = "$REPO_ROOT/.claude/settings.json.sample" ] \
    || fail "Claude settings are not linked globally"
[ "$(readlink "$HOOKS")" = "$REPO_ROOT/.claude/hooks/planning-with-files" ] \
    || fail "Claude hook scripts are not linked globally"

PRE_TOOL_COMMAND=$(python3 - "$SETTINGS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    hooks = json.load(handle)["hooks"]

scripts = {
    "PreToolUse": "pre-tool-use.sh",
    "SessionStart": "session-start.sh",
    "UserPromptSubmit": "user-prompt-submit.sh",
    "PostToolUse": "post-tool-use.sh",
    "Stop": "agent-stop.sh",
}
for event, script in scripts.items():
    command = hooks[event][0]["hooks"][0]["command"]
    expected = f'$HOME/.claude/hooks/planning-with-files/scripts/{script}'
    assert expected in command, command
    assert '$ROOT/.claude/hooks/planning-with-files' not in command, command
    assert 'git rev-parse --show-toplevel 2>/dev/null || pwd' in command, command

print(hooks["PreToolUse"][0]["hooks"][0]["command"])
PY
)

run_pre_tool_hook() {
    local project=$1 label=$2 stderr_file="$TMP_DIR/$2.stderr" output
    output=$(cd "$project" && printf '%s\n' \
        '{"session_id":"claude-global","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"README.md"}}' \
        | HOME="$TEST_HOME" bash -c "$PRE_TOOL_COMMAND" 2>"$stderr_file")
    [ "$output" = "{}" ] || fail "$label PreToolUse hook returned: $output"
    [ ! -s "$stderr_file" ] || fail "$label PreToolUse hook wrote: $(cat "$stderr_file")"
}

run_pre_tool_hook "$NON_GIT_PROJECT" non-git
run_pre_tool_hook "$GIT_PROJECT" git

echo "claude global hook installer tests: PASS"
