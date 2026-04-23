.PHONY: help injected-content sync-upstream sync-upstream-rebase sync-upstream-merge

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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
