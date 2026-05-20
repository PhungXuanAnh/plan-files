# Check if all phases in task_plan.md are complete
# Always exits 0 -- uses stdout for status reporting
# Used by Stop hook to report task completion status

param(
    [string]$PlanFile = "task_plan.md"
)

if (-not (Test-Path $PlanFile)) {
    Write-Host '[planning-with-files] No task_plan.md found -- no active planning session.'
    exit 0
}

# Read file content
$content = Get-Content $PlanFile -Raw

# Count total phases
$TOTAL = ([regex]::Matches($content, "### Phase")).Count

# Check for **Status:** format first
$COMPLETE = ([regex]::Matches($content, "\*\*Status:\*\* complete")).Count
$IN_PROGRESS = ([regex]::Matches($content, "\*\*Status:\*\* in_progress")).Count
$PENDING = ([regex]::Matches($content, "\*\*Status:\*\* pending")).Count
# Deferred: only count when "(non-empty reason)" is present.
$DEFERRED = ([regex]::Matches($content, "\*\*Status:\*\*\s*deferred\s*\(\s*[^)\s][^)]*\)")).Count

# Fallback: check for [complete] inline format if **Status:** not found
if ($COMPLETE -eq 0 -and $IN_PROGRESS -eq 0 -and $PENDING -eq 0 -and $DEFERRED -eq 0) {
    $COMPLETE = ([regex]::Matches($content, "\[complete\]")).Count
    $IN_PROGRESS = ([regex]::Matches($content, "\[in_progress\]")).Count
    $PENDING = ([regex]::Matches($content, "\[pending\]")).Count
}

$SETTLED = $COMPLETE + $DEFERRED

# Report status -- always exit 0, incomplete task is a normal state
if ($SETTLED -eq $TOTAL -and $TOTAL -gt 0) {
    if ($DEFERRED -gt 0) {
        Write-Host ('[planning-with-files] ALL PHASES SETTLED (' + $COMPLETE + ' complete + ' + $DEFERRED + ' deferred / ' + $TOTAL + '). If the user has additional work, add new phases to task_plan.md before starting.')
    } else {
        Write-Host ('[planning-with-files] ALL PHASES COMPLETE (' + $COMPLETE + '/' + $TOTAL + '). If the user has additional work, add new phases to task_plan.md before starting.')
    }
} else {
    Write-Host ('[planning-with-files] Task in progress (' + $SETTLED + '/' + $TOTAL + ' phases settled -- ' + $COMPLETE + ' complete, ' + $DEFERRED + ' deferred). Update progress.md before stopping.')
    if ($IN_PROGRESS -gt 0) {
        Write-Host ('[planning-with-files] ' + $IN_PROGRESS + ' phase(s) still in progress.')
    }
    if ($PENDING -gt 0) {
        Write-Host ('[planning-with-files] ' + $PENDING + ' phase(s) pending.')
    }
}
exit 0
