# planning-with-files: Post-tool-use hook for GitHub Copilot (PowerShell)
# Anchors goals + nudges progress logging on every tool call. No-op when
# task_plan.md absent. Always exits 0. Debug log at:
#   tmp/hook-logs/plan-with-files/post-tool-use.log

$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$InputData = [Console]::In.ReadToEnd()

# --- Resolve plan directory --------------------------------------------------
# Strict resolution: requires `.plan-with-files` pointer (workspace root) whose
# first line is a task id, e.g.
#   JIRA-1234
# -> hook reads tmp/plan-with-files/JIRA-1234/task_plan.md
# If pointer missing / invalid / target dir missing -> no-op (zero pollution).
# The planning-with-files skill is responsible for creating both the pointer
# and the per-task directory; hooks never write files.
$PlanDir = ""
$PlanSource = ""
if (Test-Path ".plan-with-files") {
    $TaskId = (Get-Content ".plan-with-files" -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($TaskId) { $TaskId = $TaskId.Trim() }
    if ($TaskId -and ($TaskId -match '^[A-Za-z0-9._-]+$') -and ($TaskId -ne '.') -and ($TaskId -ne '..')) {
        $Candidate = "tmp/plan-with-files/$TaskId"
        if (Test-Path $Candidate -PathType Container) {
            $PlanDir = $Candidate
            $PlanSource = ".plan-with-files -> $Candidate"
        } else {
            $PlanSource = ".plan-with-files -> $Candidate (DIR MISSING -> no-op)"
        }
    } else {
        $PlanSource = ".plan-with-files -> '$TaskId' (INVALID id -> no-op)"
    }
} else {
    $PlanSource = "no .plan-with-files pointer -> no-op"
}
$PlanFile = if ($PlanDir) { Join-Path $PlanDir "task_plan.md" } else { "" }

# --- Logging setup -----------------------------------------------------------
$LogDir = "tmp/hook-logs/plan-with-files"
$LogFile = Join-Path $LogDir "post-tool-use.log"
New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction SilentlyContinue | Out-Null
# Rotate log: trigger at 3000 lines, keep last 2500 (hysteresis avoids per-call rotation)
$LogMaxLines = 3000
$LogKeepLines = 2500
if (Test-Path $LogFile) {
    try {
        $_lines = Get-Content -Path $LogFile -ErrorAction Stop
        if ($_lines.Count -gt $LogMaxLines) {
            $_kept = $_lines[-$LogKeepLines..-1]
            Set-Content -Path $LogFile -Value $_kept -Encoding UTF8
        }
    } catch {}
}
$Ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
function Log([string]$m) {
    try { Add-Content -Path $LogFile -Value "[$Ts] $m" -Encoding UTF8 } catch {}
}

Log "=== post-tool-use ==="
Log "cwd: $(Get-Location)"
Log "plan source: $PlanSource -> $PlanFile"
$InputPreview = ($InputData -replace "`r?`n", " ")
if ($InputPreview.Length -gt 300) { $InputPreview = $InputPreview.Substring(0, 300) }
Log "stdin (first 300 chars, $($InputData.Length) total): $InputPreview"

if (-not (Test-Path $PlanFile)) {
    Log "$(if($PlanFile){$PlanFile}else{"task_plan.md"}): ABSENT -> emitting {} (no-op, zero pollution)"
    Write-Output '{}'
    exit 0
}
$PlanBytes = (Get-Item $PlanFile).Length
Log "${PlanFile}: present ($PlanBytes bytes)"

$MaxGoalChars  = 700
$MaxPhaseChars = 100
$TruncMarker = "[truncated by post-tool-use hook — full text in $PlanFile; this section is too long for per-call injection, consider shortening it there]"

function Extract-Section {
    param([string]$Name)
    $hdrPattern = "^## $([regex]::Escape($Name))\s*$"
    $rawLines = Get-Content $PlanFile -Encoding UTF8 -ErrorAction SilentlyContinue
    $capture = $false
    $collected = New-Object System.Collections.Generic.List[string]
    foreach ($line in $rawLines) {
        if ($line -match $hdrPattern) { $capture = $true; continue }
        if ($line -match '^## ') { $capture = $false }
        if ($capture) { $collected.Add($line) | Out-Null }
    }
    $inComment = $false
    $filtered = New-Object System.Collections.Generic.List[string]
    foreach ($line in $collected) {
        if ($line -match '<!--') { $inComment = $true }
        if (-not $inComment) { $filtered.Add($line) | Out-Null }
        if ($line -match '-->') { $inComment = $false }
    }
    return ($filtered -join "`n").Trim()
}

function Cap-Text {
    param([string]$Text, [int]$Max, [string]$Label)
    if ($Text.Length -gt $Max) {
        Log "${Label}: $($Text.Length) chars -> TRUNCATED to $Max"
        return $Text.Substring(0, $Max) + "`n$TruncMarker"
    }
    Log "${Label}: $($Text.Length) chars (within cap $Max)"
    return $Text
}

$GoalRaw  = Extract-Section 'Goal'
$PhaseRaw = Extract-Section 'Current Phase'
Log "extracted Goal: $($GoalRaw.Length) chars; Current Phase: $($PhaseRaw.Length) chars"

$GoalBody  = Cap-Text $GoalRaw  $MaxGoalChars  'Goal'
$PhaseBody = Cap-Text $PhaseRaw $MaxPhaseChars 'Current Phase'

$parts = @()
if ($GoalBody)  { $parts += "## Goal`n$GoalBody" }
if ($PhaseBody) { $parts += "## Current Phase`n$PhaseBody" }
$PlanSummary = ($parts -join "`n`n")

$Nudge = "[planning-with-files] Update progress.md with what you just did. If a phase is now complete, update $PlanFile status. If you no longer see the planning-with-files SKILL.md rules in your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing."

if ($PlanSummary) {
    $Context = "=== Current task (Goal + Current Phase from $PlanFile) ===`n$PlanSummary`n`n$Nudge"
} else {
    $Context = $Nudge
}
Log "additionalContext: $($Context.Length) chars"
Log "--- additionalContext begin ---"
try { Add-Content -Path $LogFile -Value $Context -Encoding UTF8 } catch {}
Log "--- additionalContext end ---"

$output = @{
    hookSpecificOutput = @{
        hookEventName = "PostToolUse"
        additionalContext = $Context
    }
}
$json = $output | ConvertTo-Json -Depth 3 -Compress
Log "stdout: $($json.Length) chars"
$json
exit 0
# planning-with-files: Post-tool-use hook for GitHub Copilot (PowerShell)
# Runs AFTER every tool call. The pre-tool-use hook has been retired; this
# hook now does double duty:
#   1. Anchors goals by re-injecting the '## Goal' and '## Current Phase'
#      sections of task_plan.md (size-bounded, always relevant -- unlike
#      a fixed 'head -N' which can miss the goal once the file grows).
#   2. Nudges the model to update progress.md.
# No-op when task_plan.md does not exist -- zero pollution on non-planning sessions.
# Always exits 0 - outputs JSON to stdout.

$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$InputData = [Console]::In.ReadToEnd()

$PlanFile = "task_plan.md"

if (-not (Test-Path $PlanFile)) {
    Write-Output '{}'
    exit 0
}

# Per-section hard caps. Prevents runaway model verbosity from inflating
# per-tool-call cost while preserving BOTH sections (the previous combined
# 800-char cap could starve Current Phase if Goal exhausted the budget).
$MaxGoalChars  = 700    # ~100 words / 2-3 sentences
$MaxPhaseChars = 100    # ~15 words; Current Phase is meant to be a label
$TruncMarker = "[truncated by post-tool-use hook — full text in $PlanFile; this section is too long for per-call injection, consider shortening it there]"

function Extract-Section {
    param([string]$Name)
    $hdrPattern = "^## $([regex]::Escape($Name))\s*$"
    $rawLines = Get-Content $PlanFile -Encoding UTF8 -ErrorAction SilentlyContinue
    $capture = $false
    $collected = New-Object System.Collections.Generic.List[string]
    foreach ($line in $rawLines) {
        if ($line -match $hdrPattern) { $capture = $true; continue }
        if ($line -match '^## ') { $capture = $false }
        if ($capture) { $collected.Add($line) | Out-Null }
    }
    # Strip HTML comment blocks
    $inComment = $false
    $filtered = New-Object System.Collections.Generic.List[string]
    foreach ($line in $collected) {
        if ($line -match '<!--') { $inComment = $true }
        if (-not $inComment) { $filtered.Add($line) | Out-Null }
        if ($line -match '-->') { $inComment = $false }
    }
    return ($filtered -join "`n").Trim()
}

function Cap-Text {
    param([string]$Text, [int]$Max)
    if ($Text.Length -gt $Max) {
        return $Text.Substring(0, $Max) + "`n$TruncMarker"
    }
    return $Text
}

$GoalBody  = Cap-Text (Extract-Section 'Goal')          $MaxGoalChars
$PhaseBody = Cap-Text (Extract-Section 'Current Phase') $MaxPhaseChars

$parts = @()
if ($GoalBody)  { $parts += "## Goal`n$GoalBody" }
if ($PhaseBody) { $parts += "## Current Phase`n$PhaseBody" }
$PlanSummary = ($parts -join "`n`n")

$Nudge = "[planning-with-files] Update progress.md with what you just did. If a phase is now complete, update $PlanFile status. If you no longer see the planning-with-files SKILL.md rules in your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing."

if ($PlanSummary) {
    $Context = "=== Current task (Goal + Current Phase from $PlanFile) ===`n$PlanSummary`n`n$Nudge"
} else {
    $Context = $Nudge
}

$output = @{
    hookSpecificOutput = @{
        hookEventName = "PostToolUse"
        additionalContext = $Context
    }
}
$output | ConvertTo-Json -Depth 3 -Compress
exit 0
