#!/bin/bash
# Initialize planning files for a new session
# Usage: ./init-session.sh [--template TYPE] [project-name]
# Templates: default, analytics

set -e

TEMPLATE="default"
PROJECT_NAME="project"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --template|-t)
            TEMPLATE="$2"
            shift 2
            ;;
        *)
            PROJECT_NAME="$1"
            shift
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(dirname "$SCRIPT_DIR")"
TEMPLATE_DIR="$SKILL_ROOT/templates"

echo "Initializing planning files for: $PROJECT_NAME (template: $TEMPLATE)"

if [ "$TEMPLATE" != "default" ] && [ "$TEMPLATE" != "analytics" ]; then
    echo "Unknown template: $TEMPLATE (available: default, analytics). Using default."
    TEMPLATE="default"
fi

copy_or_create() {
    local target="$1"
    local template="$2"
    local fallback="$3"

    if [ -f "$target" ]; then
        echo "$target already exists, skipping"
        return
    fi

    if [ -f "$template" ]; then
        cp "$template" "$target"
    else
        printf '%s\n' "$fallback" > "$target"
    fi
    echo "Created $target"
}

if [ "$TEMPLATE" = "analytics" ] && [ -f "$TEMPLATE_DIR/analytics_tasks.md" ]; then
    TASKS_TEMPLATE="$TEMPLATE_DIR/analytics_tasks.md"
else
    TASKS_TEMPLATE="$TEMPLATE_DIR/tasks.md"
fi

if [ "$TEMPLATE" = "analytics" ] && [ -f "$TEMPLATE_DIR/analytics_findings.md" ]; then
    FINDINGS_TEMPLATE="$TEMPLATE_DIR/analytics_findings.md"
else
    FINDINGS_TEMPLATE="$TEMPLATE_DIR/findings.md"
fi

DECISIONS_TEMPLATE="$TEMPLATE_DIR/decisions.md"

copy_or_create "tasks.md" "$TASKS_TEMPLATE" "# Tasks: $PROJECT_NAME

## Goal
[One sentence describing the end state]

## Current Phase
Phase 1

## Workflow Profile
**Profile:** [A | B | C]

## Resume Checkpoint
- **Next action:** [exact next command or edit]
- **Blocker:** none
- **Details:** none

## Phases

### Phase 1: Requirements & Discovery
- [ ] Understand user intent
- [ ] Identify constraints
- [ ] Document findings in findings.md
- [ ] Document user decisions in decisions.md
- **Status:** in_progress

## Progress Notes
- Created plan.

## Errors Encountered
| Error | Attempt | Resolution |
|-------|---------|------------|"

copy_or_create "findings.md" "$FINDINGS_TEMPLATE" "# Findings

## Current Summary
-

## Requirements
-

## Discoveries
-

## Known Gotchas
| Symptom | Root Cause | Workaround |
|---------|------------|------------|

## Sources
-"

copy_or_create "decisions.md" "$DECISIONS_TEMPLATE" "# Decisions

## Active Decisions
| ID | Decision | Rationale | Date |
|----|----------|-----------|------|

## Superseded Decisions
| ID | Old Decision | Replaced By | Reason |
|----|--------------|-------------|--------|

## Open Decision Questions
- [ ]"

echo ""
echo "Planning files initialized!"
echo "Files: tasks.md, findings.md, decisions.md"
echo "Optional templates: history.md (cold archive), handoff.md (intentional pause only)"
