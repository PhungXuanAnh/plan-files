#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SOURCE="$REPO_ROOT/.codex/hooks.json"
DEST="$TMP_DIR/hooks.json"

python3 "$REPO_ROOT/scripts/install-codex-hooks.py" "$SOURCE" "$DEST"
python3 "$REPO_ROOT/scripts/install-codex-hooks.py" "$SOURCE" "$DEST"

python3 - "$DEST" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    hooks = json.load(handle)["hooks"]

for event in ("UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"):
    command = hooks[event][0]["hooks"][0]["command"]
    assert "/home/xuananh/repo/planning-with-files" in command, command
PY

echo "codex global hook installer tests: PASS"
