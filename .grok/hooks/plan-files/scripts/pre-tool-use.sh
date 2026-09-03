#!/usr/bin/env bash
set -u
set -o pipefail 2>/dev/null || true

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
INPUT=$(cat)
printf '%s' "$INPUT" | grok_input_has_verified_session \
    || { printf '{"decision":"allow"}'; exit 0; }

OUTPUT=$(printf '%s' "$INPUT" \
    | bash "$GROK_REPO_ROOT/skills/plan-files/scripts/pre-tool-gate.sh" \
        grok "$GROK_ADAPTER_DIR/bind-session.sh" "Grok Build")

# The shared core uses the provider-neutral block verdict. Grok's canonical
# PreToolUse vocabulary is deny/allow, so translate only the envelope.
printf '%s' "$OUTPUT" | python3 -c 'import json, sys
try:
    value = json.load(sys.stdin)
except Exception:
    value = {}
if not isinstance(value, dict):
    value = {}
if value.get("decision") == "block":
    value["decision"] = "deny"
elif value.get("decision") not in {"deny", "ask"}:
    value = {"decision": "allow"}
json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))'
