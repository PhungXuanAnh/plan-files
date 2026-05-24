# planning-with-files: Post-tool-use hook for Codex (PowerShell)
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

# --- Remaining-in-phase snippet (cheap: count + first unchecked item) -------
$PhaseNum = ""
if ($PhaseRaw -match '(Phase\s+\d+)') { $PhaseNum = $Matches[1] -replace '\s+',' ' }
$RemainingLine = ""
if ($PhaseNum) {
    $count = 0
    $first = ""
    $inPhase = $false
    $inComment = $false
    $headerPattern = "^### " + [regex]::Escape($PhaseNum) + "([: ]|$)"
    foreach ($line in (Get-Content $PlanFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line -match '<!--') { $inComment = $true }
        if ($inComment) { if ($line -match '-->') { $inComment = $false }; continue }
        if ($line -match '^### ') {
            if ($inPhase) { break }
            if ($line -match $headerPattern) { $inPhase = $true }
            continue
        }
        if (-not $inPhase) { continue }
        if ($line -match '^-\s\[\s\]') {
            $count++
            if (-not $first) { $first = ($line -replace '^-\s\[\s\]\s*','') }
        }
    }
    if ($first.Length -gt 200) { $first = $first.Substring(0,200) + "..." }
    if ($count -eq 0) {
        $RemainingLine = "${PhaseNum}: 0 unchecked items in this phase — if all 'Done when' criteria genuinely verified (see anti-substitution rule), mark phase complete."
    } else {
        $RemainingLine = "${PhaseNum}: $count unchecked item(s). First: $first"
    }
    Log "remaining: count=$count first($($first.Length) chars)"
}

$parts = @()
if ($GoalBody)  { $parts += "## Goal`n$GoalBody" }
if ($PhaseBody) { $parts += "## Current Phase`n$PhaseBody" }
$PlanSummary = ($parts -join "`n`n")

$Nudge = "[planning-with-files] Update progress.md with what you just did. If a phase is now complete, update $PlanFile status. If you no longer see the planning-with-files SKILL.md rules in your context (post-/compact, or you have forgotten them), reload the planning-with-files skill by yourself before continuing."
if ($RemainingLine) { $Nudge = "$Nudge`n$RemainingLine" }

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
