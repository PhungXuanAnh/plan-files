#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

FRESH_HOME="$TMP_DIR/fresh-home"
MERGE_HOME="$TMP_DIR/merge-home"
LEGACY_HOME="$TMP_DIR/legacy-home"
NON_GIT_PROJECT="$TMP_DIR/non-git-project"
GIT_PROJECT="$TMP_DIR/git-project"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_regular_settings_with_sample_hooks() {
    local settings=$1
    [ -f "$settings" ] && [ ! -L "$settings" ] \
        || fail "Claude settings are not a regular file: $settings"
    python3 - "$REPO_ROOT/.claude/settings.json.sample" "$settings" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    expected = json.load(handle)["hooks"]
with open(sys.argv[2], encoding="utf-8") as handle:
    actual = json.load(handle)["hooks"]
for event, definitions in expected.items():
    planning = [
        group
        for group in actual[event]
        if any(
            "planning-with-files/scripts/" in hook.get("command", "")
            for hook in group.get("hooks", [])
        )
    ]
    assert planning == definitions, event
PY
}

mkdir -p "$NON_GIT_PROJECT" "$GIT_PROJECT"
git -C "$GIT_PROJECT" init -q

# Missing settings are created as a regular file with every sample hook.
HOME="$FRESH_HOME" make -s -C "$REPO_ROOT" install-hook-claude-code >/dev/null
FRESH_SETTINGS="$FRESH_HOME/.claude/settings.json"
assert_regular_settings_with_sample_hooks "$FRESH_SETTINGS"

# Existing unrelated settings/hooks survive while stale and missing planning
# event groups converge to the sample definitions.
MERGE_SETTINGS="$MERGE_HOME/.claude/settings.json"
mkdir -p "$(dirname -- "$MERGE_SETTINGS")"
python3 - "$MERGE_SETTINGS" <<'PY'
import json
import sys

settings = {
    "autoMode": {"enabled": True},
    "hooks": {
        "Notification": [{"matcher": "*", "hooks": []}],
        "PreToolUse": [
            {
                "matcher": "unrelated-before",
                "hooks": [{"type": "command", "command": "echo before"}],
            },
            {
                "matcher": "stale-planning",
                "hooks": [
                    {
                        "type": "command",
                        "command": "bash /old/planning-with-files/scripts/pre-tool-use.sh",
                    }
                ],
            },
            {
                "matcher": "duplicate-planning",
                "hooks": [
                    {
                        "type": "command",
                        "command": "bash /duplicate/planning-with-files/scripts/pre-tool-use.sh",
                    }
                ],
            },
            {
                "matcher": "unrelated-after",
                "hooks": [{"type": "command", "command": "echo after"}],
            },
        ],
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(settings, handle, indent=4)
    handle.write("\n")
PY
HOME="$MERGE_HOME" make -s -C "$REPO_ROOT" install-hook-claude-code >/dev/null
assert_regular_settings_with_sample_hooks "$MERGE_SETTINGS"
python3 - "$MERGE_SETTINGS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    settings = json.load(handle)
assert settings["autoMode"] == {"enabled": True}
assert settings["hooks"]["Notification"] == [{"matcher": "*", "hooks": []}]
pre_tool_use = settings["hooks"]["PreToolUse"]
assert pre_tool_use[0]["matcher"] == "unrelated-before"
assert pre_tool_use[-1]["matcher"] == "unrelated-after"
assert len(pre_tool_use) == 3
PY

# A matching installation is a byte-for-byte no-op on repeat runs.
BEFORE_SUM=$(sha256sum "$MERGE_SETTINGS" | cut -d' ' -f1)
HOME="$MERGE_HOME" make -s -C "$REPO_ROOT" install-hook-claude-code >/dev/null
AFTER_SUM=$(sha256sum "$MERGE_SETTINGS" | cut -d' ' -f1)
[ "$BEFORE_SUM" = "$AFTER_SUM" ] || fail "repeat install rewrote matching settings"

# Migrate the legacy sample symlink without mutating the repository sample.
mkdir -p "$LEGACY_HOME/.claude"
ln -s "$REPO_ROOT/.claude/settings.json.sample" "$LEGACY_HOME/.claude/settings.json"
SAMPLE_SUM=$(sha256sum "$REPO_ROOT/.claude/settings.json.sample" | cut -d' ' -f1)
HOME="$LEGACY_HOME" make -s -C "$REPO_ROOT" install-hook-claude-code >/dev/null
assert_regular_settings_with_sample_hooks "$LEGACY_HOME/.claude/settings.json"
[ "$SAMPLE_SUM" = "$(sha256sum "$REPO_ROOT/.claude/settings.json.sample" | cut -d' ' -f1)" ] \
    || fail "legacy migration changed the repository sample"

HOOKS="$MERGE_HOME/.claude/hooks/planning-with-files"
[ "$(readlink "$HOOKS")" = "$REPO_ROOT/.claude/hooks/planning-with-files" ] \
    || fail "Claude hook scripts are not linked globally"

PRE_TOOL_COMMAND=$(python3 - "$MERGE_SETTINGS" <<'PY'
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


def planning_command(event):
    for group in hooks[event]:
        for hook in group.get("hooks", []):
            command = hook.get("command", "")
            if "planning-with-files/scripts/" in command:
                return command
    raise AssertionError(f"missing planning command for {event}")


for event, script in scripts.items():
    command = planning_command(event)
    expected = f'$HOME/.claude/hooks/planning-with-files/scripts/{script}'
    assert expected in command, command
    assert '$ROOT/.claude/hooks/planning-with-files' not in command, command
    assert 'git rev-parse --show-toplevel 2>/dev/null || pwd' in command, command

print(planning_command("PreToolUse"))
PY
)

run_pre_tool_hook() {
    local project=$1 label=$2 stderr_file="$TMP_DIR/$2.stderr" output
    output=$(cd "$project" && printf '%s\n' \
        '{"session_id":"claude-global","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"README.md"}}' \
        | HOME="$MERGE_HOME" bash -c "$PRE_TOOL_COMMAND" 2>"$stderr_file")
    [ "$output" = "{}" ] || fail "$label PreToolUse hook returned: $output"
    [ ! -s "$stderr_file" ] || fail "$label PreToolUse hook wrote: $(cat "$stderr_file")"
}

run_pre_tool_hook "$NON_GIT_PROJECT" non-git
run_pre_tool_hook "$GIT_PROJECT" git

echo "claude global hook installer tests: PASS"
