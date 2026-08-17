.PHONY: help test check-installs injected-content \
        install-skill-copilot install-skill-claude-code install-skill-codex install-skill-kiro install-skills \
        install-hook-copilot install-hook-claude-code install-hook-codex install-hooks \
        install-copilot install-claude-code install-codex install-global install \
        sync-upstream sync-upstream-rebase sync-upstream-merge install-hooks-json

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

test: ## Run planning contract tests
	@bash tests/test-planning-contract.sh
	@bash tests/test-session-ownership.sh
	@bash tests/test-codex-global-hooks.sh
	@bash tests/test-claude-global-hooks.sh

# ---------------------------------------------------------------------------
# Global installation. Hook configs are samples so this repository does not
# register a second project-local hook layer. Claude Code and Copilot link the
# samples globally. Codex merges its sample into ~/.codex/hooks.json so unrelated
# global hooks survive; generated commands still dispatch to this repository.
# ---------------------------------------------------------------------------
REPO_ROOT := $(shell git rev-parse --show-toplevel)
SKILL_SRC := $(REPO_ROOT)/skills/planning-with-files

CODEX_SKILL := $(HOME)/.codex/skills/planning-with-files
CODEX_HOOKS := $(HOME)/.codex/hooks.json
CLAUDE_CODE_SKILL := $(HOME)/.claude/skills/planning-with-files
CLAUDE_CODE_SETTINGS := $(HOME)/.claude/settings.json
CLAUDE_CODE_HOOKS := $(HOME)/.claude/hooks/planning-with-files
COPILOT_SKILL := $(HOME)/Dropbox/Work/copilot/skills/planning-with-files
COPILOT_HOOKS := $(HOME)/Dropbox/Work/copilot/hooks/planning-with-files.json
KIRO_SKILL := $(HOME)/.kiro/skills/planning-with-files

CODEX_HOOKS_SRC := $(REPO_ROOT)/.codex/hooks.json.sample
CLAUDE_CODE_SETTINGS_SRC := $(REPO_ROOT)/.claude/settings.json.sample
CLAUDE_CODE_HOOKS_SRC := $(REPO_ROOT)/.claude/hooks/planning-with-files
COPILOT_HOOKS_SRC := $(REPO_ROOT)/.github/hooks/planning-with-files.json.sample

define link_path
	@target='$(1)'; dest='$(2)'; \
	mkdir -p "$$(dirname "$$dest")"; \
	if [ -L "$$dest" ]; then \
		current=$$(readlink "$$dest"); \
		if [ "$$current" = "$$target" ]; then \
			echo "  already linked: $$dest -> $$target"; \
		else \
			ln -sfn "$$target" "$$dest"; \
			echo "  relinked: $$dest -> $$target"; \
		fi; \
	elif [ -e "$$dest" ]; then \
		backup="$$dest.bak.$$(date +%Y%m%d%H%M%S)"; \
		mv "$$dest" "$$backup"; \
		ln -s "$$target" "$$dest"; \
		echo "  backed up: $$backup"; \
		echo "  linked: $$dest -> $$target"; \
	else \
		ln -s "$$target" "$$dest"; \
		echo "  linked: $$dest -> $$target"; \
	fi
endef

define check_path
	@if [ -L '$(1)' ]; then \
		echo "LINK    $(1) -> $$(readlink '$(1)')"; \
	elif [ -e '$(1)' ]; then \
		echo "FILE    $(1)"; \
	else \
		echo "MISSING $(1)"; \
	fi
endef

check-installs: ## Show global skill/hook install status
	$(call check_path,$(CODEX_SKILL))
	$(call check_path,$(CODEX_HOOKS))
	$(call check_path,$(CLAUDE_CODE_SKILL))
	$(call check_path,$(CLAUDE_CODE_SETTINGS))
	$(call check_path,$(CLAUDE_CODE_HOOKS))
	$(call check_path,$(COPILOT_SKILL))
	$(call check_path,$(COPILOT_HOOKS))
	$(call check_path,$(KIRO_SKILL))

install-skill-codex: ## Link skill into global Codex skills
	$(call link_path,$(SKILL_SRC),$(CODEX_SKILL))

install-hook-codex: ## Install global Codex hook wrapper without overwriting unrelated hooks
	@python3 scripts/install-codex-hooks.py "$(CODEX_HOOKS_SRC)" "$(CODEX_HOOKS)"

install-codex: install-skill-codex install-hook-codex ## Link Codex skill and hook JSON globally

install-skill-claude-code: ## Link skill into global Claude Code skills
	$(call link_path,$(SKILL_SRC),$(CLAUDE_CODE_SKILL))

install-hook-claude-code: ## Link Claude Code hooks and sample settings globally
	$(call link_path,$(CLAUDE_CODE_HOOKS_SRC),$(CLAUDE_CODE_HOOKS))
	$(call link_path,$(CLAUDE_CODE_SETTINGS_SRC),$(CLAUDE_CODE_SETTINGS))

install-claude-code: install-skill-claude-code install-hook-claude-code ## Link Claude Code skill and settings globally

install-skill-copilot: ## Link skill into global GitHub Copilot skills
	$(call link_path,$(SKILL_SRC),$(COPILOT_SKILL))

install-hook-copilot: ## Link sample hook JSON into global GitHub Copilot hooks
	$(call link_path,$(COPILOT_HOOKS_SRC),$(COPILOT_HOOKS))

install-copilot: install-skill-copilot install-hook-copilot ## Link GitHub Copilot skill and hook JSON globally

install-skill-kiro: ## Link skill into global Kiro skills
	$(call link_path,$(SKILL_SRC),$(KIRO_SKILL))

install-skills: install-skill-codex install-skill-claude-code install-skill-copilot install-skill-kiro ## Link skills globally

install-hooks: install-hook-codex install-hook-claude-code install-hook-copilot ## Link hook JSON/settings globally

install-global install: install-skills install-hooks ## Link skills and available hook JSON/settings globally

# ---------------------------------------------------------------------------
injected-content: ## Show what the post-tool-use hook would inject from the active tasks.md
	@id=$$(cat .plan-with-files 2>/dev/null || true); \
	case "$$id" in ""|.|*/*|*..*|*" "*) echo "no valid active plan"; exit 0;; esac; \
	file="tmp/plan-with-files/$$id/tasks.md"; \
	if [ ! -f "$$file" ]; then echo "active tasks.md not found: $$file"; exit 0; fi; \
	awk '/^## (Goal|Current Phase)[[:space:]]*$$/{c=1;print;next} /^## /{c=0} c' "$$file" | awk 'BEGIN{c=0} /<!--/{c=1} c==0{print} /-->/{c=0}'

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
