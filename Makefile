.PHONY: help injected-content \
        install-hook-copilot install-hook-claude-code install-hook-codex install-hook-kiro install-hooks \
        sync-upstream sync-upstream-rebase sync-upstream-merge

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---------------------------------------------------------------------------
# Hook installation — wire planning-with-files hooks into each AI agent's
# global config. Each target is idempotent: re-running overwrites the hooks
# block without touching other settings. Uses absolute paths to this repo.
# ---------------------------------------------------------------------------
REPO_ROOT        := $(shell git rev-parse --show-toplevel)
COPILOT_HOOKS_DIR := $(HOME)/Dropbox/Work/copilot/hooks

# Python script written to a temp file then executed (avoids $ escaping in Make).
# chr(36) produces a literal $ at Python runtime so Make never expands it.

define _copilot_py
import json
repo = '$(REPO_ROOT)'
cfg = {
    'version': 1,
    'hooks': {
        'PostToolUse': [{'type': 'command',
            'bash':       repo + '/.github/hooks/scripts/post-tool-use.sh',
            'powershell': repo + '/.github/hooks/scripts/post-tool-use.ps1',
            'timeout': 5}],
        'Stop': [{'type': 'command',
            'bash':       repo + '/.github/hooks/scripts/agent-stop.sh',
            'powershell': repo + '/.github/hooks/scripts/agent-stop.ps1',
            'timeout': 10}],
        'ErrorOccurred': [{'type': 'command',
            'bash':       repo + '/.github/hooks/scripts/error-occurred.sh',
            'powershell': repo + '/.github/hooks/scripts/error-occurred.ps1',
            'timeout': 5}],
    }
}
dest = '$(COPILOT_HOOKS_DIR)/planning-with-files.json'
with open(dest, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
print('  written:', dest)
endef

define _claude_code_py
import json, os
repo = '$(REPO_ROOT)'
d = chr(36)
path = os.path.expanduser('~/.claude/settings.json')
try:
    s = json.load(open(path))
except FileNotFoundError:
    s = {}
pfx = (f'ROOT="{d}(git rev-parse --show-toplevel 2>/dev/null || pwd)"'
       f' && cd "{d}ROOT" && bash "')
s.setdefault('hooks', {})
s['hooks']['PostToolUse'] = [{'hooks': [{'type': 'command', 'timeout': 5,
    'command': pfx + repo + '/.claude/hooks/planning-with-files/scripts/post-tool-use.sh"'}]}]
s['hooks']['Stop'] = [{'hooks': [{'type': 'command', 'timeout': 10,
    'command': pfx + repo + '/.claude/hooks/planning-with-files/scripts/agent-stop.sh"'}]}]
with open(path, 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
print('  written:', path)
endef

define _codex_py
import json, os
repo = '$(REPO_ROOT)'
d = chr(36)
path = os.path.expanduser('~/.codex/hooks.json')
try:
    s = json.load(open(path))
except FileNotFoundError:
    s = {}
pfx_bash = (f'ROOT="{d}(git rev-parse --show-toplevel 2>/dev/null || pwd)"'
            f' && cd "{d}ROOT" && bash "')
pfx_ps   = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
            '"' + d + 'root = git rev-parse --show-toplevel 2>' + d + 'null; '
            'if (-not ' + d + 'root) { ' + d + 'root = (Get-Location).Path }; '
            'Set-Location ' + d + 'root; & \'')
s.setdefault('hooks', {})
s['hooks']['PostToolUse'] = [{'hooks': [{'type': 'command', 'timeout': 5,
    'statusMessage': 'Injecting planning context',
    'command':        pfx_bash + repo + '/.codex/hooks/planning-with-files/scripts/post-tool-use.sh"',
    'commandWindows': pfx_ps   + repo + '/.codex/hooks/planning-with-files/scripts/post-tool-use.ps1\'"'}]}]
s['hooks']['Stop'] = [{'hooks': [{'type': 'command', 'timeout': 10,
    'statusMessage': 'Checking planning completion',
    'command':        pfx_bash + repo + '/.codex/hooks/planning-with-files/scripts/agent-stop.sh"',
    'commandWindows': pfx_ps   + repo + '/.codex/hooks/planning-with-files/scripts/agent-stop.ps1\'"'}]}]
with open(path, 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
print('  written:', path)
endef

install-hook-copilot: ## Install planning-with-files hook into global GitHub Copilot
	@echo ">>> installing global GitHub Copilot hook..."
	@mkdir -p $(COPILOT_HOOKS_DIR)
	$(file > /tmp/_pwf_hook_copilot.py,$(_copilot_py))
	@python3 /tmp/_pwf_hook_copilot.py
	@rm -f /tmp/_pwf_hook_copilot.py
	@echo ">>> done. Restart VS Code to reload hooks."

install-hook-claude-code: ## Install planning-with-files hook into global Claude Code (~/.claude/settings.json)
	@echo ">>> installing global Claude Code hook..."
	$(file > /tmp/_pwf_hook_claude.py,$(_claude_code_py))
	@python3 /tmp/_pwf_hook_claude.py
	@rm -f /tmp/_pwf_hook_claude.py
	@echo ">>> done. Restart Claude Code to reload hooks."

install-hook-codex: ## Install planning-with-files hook into global Codex (~/.codex/hooks.json)
	@echo ">>> installing global Codex hook..."
	$(file > /tmp/_pwf_hook_codex.py,$(_codex_py))
	@python3 /tmp/_pwf_hook_codex.py
	@rm -f /tmp/_pwf_hook_codex.py
	@echo ">>> done. Restart Codex to reload hooks."

install-hook-kiro: ## Install planning-with-files hook into global Kiro hook 
	@echo ">>> installing global Kiro hook..."
	@mkdir -p ~/.kiro/hooks
	@ln -sf $(REPO_ROOT)/.kiro/hooks/planning-with-files.json ~/.kiro/hooks/planning-with-files.json
	@echo "  written: .kiro/hooks/planning-with-files.json"
	@echo "  symlinked: ~/.kiro/hooks/planning-with-files.json -> $(REPO_ROOT)/.kiro/hooks/planning-with-files.json"
	@echo ">>> done. Hooks will activate on next Kiro session start."

install-hooks: install-hook-copilot install-hook-claude-code install-hook-codex install-hook-kiro ## Install hooks for all AI agents

# ---------------------------------------------------------------------------
injected-content: ## Show what the post-tool-use hook would inject from task_plan.md
	awk '/^## (Goal|Current Phase)[[:space:]]*$$/{c=1;print;next} /^## /{c=0} c' task_plan.md | awk 'BEGIN{c=0} /<!--/{c=1} c==0{print} /-->/{c=0}'

# ----------------------------------------------------------------------------
# Upstream sync (origin = PhungXuanAnh fork, upstream = OthmanAdi original)
# ----------------------------------------------------------------------------

sync-upstream: sync-upstream-rebase ## Alias for sync-upstream-rebase

sync-upstream-rebase: ## Fetch upstream and rebase current branch onto upstream/<branch>
	@branch=$$(git rev-parse --abbrev-ref HEAD); \
	echo ">>> fetching upstream..."; \
	git fetch upstream --prune; \
	echo ">>> rebasing $$branch onto upstream/$$branch..."; \
	git rebase upstream/$$branch; \
	echo ">>> done. push with: git push --force-with-lease origin $$branch"

sync-upstream-merge: ## Fetch upstream and MERGE upstream/<branch> into current branch (no rebase)
	@branch=$$(git rev-parse --abbrev-ref HEAD); \
	echo ">>> fetching upstream..."; \
	git fetch upstream --prune; \
	echo ">>> merging upstream/$$branch into $$branch..."; \
	git merge upstream/$$branch --no-edit; \
	echo ">>> done. push with: git push origin $$branch"
