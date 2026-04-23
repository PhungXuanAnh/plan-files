# planning-with-files: Agent stop hook for GitHub Copilot (PowerShell)
# Checks if all phases in task_plan.md are complete. Always exits 0.
# Debug log at: tmp/hook-logs/plan-with-files/agent-stop.log

$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$InputData = [Console]::In.ReadToEnd()

# --- Resolve plan directory (see post-tool-use.ps1 for full doc) ------------
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
$LogFile = Join-Path $LogDir "agent-stop.log"
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

Log "=== agent-stop ==="
Log "cwd: $(Get-Location)"
Log "plan source: $PlanSource -> $PlanFile"
$InputPreview = ($InputData -replace "`r?`n", " ")
if ($InputPreview.Length -gt 300) { $InputPreview = $InputPreview.Substring(0, 300) }
Log "stdin (first 300 chars, $($InputData.Length) total): $InputPreview"

if (-not (Test-Path $PlanFile)) {
    Log "$(if($PlanFile){$PlanFile}else{"task_plan.md"}): ABSENT -> emitting {} (no-op)"
    Write-Output '{}'
    exit 0
}
Log "$PlanFile: present ($((Get-Item $PlanFile).Length) bytes)"

$content = Get-Content $PlanFile -Raw -Encoding UTF8

$TOTAL = ([regex]::Matches($content, "### Phase")).Count
$COMPLETE = ([regex]::Matches($content, "\*\*Status:\*\* complete")).Count
$IN_PROGRESS = ([regex]::Matches($content, "\*\*Status:\*\* in_progress")).Count
$PENDING = ([regex]::Matches($content, "\*\*Status:\*\* pending")).Count
$Format = "Status:"

if ($COMPLETE -eq 0 -and $IN_PROGRESS -eq 0 -and $PENDING -eq 0) {
    $COMPLETE = ([regex]::Matches($content, "\[complete\]")).Count
    $IN_PROGRESS = ([regex]::Matches($content, "\[in_progress\]")).Count
    $PENDING = ([regex]::Matches($content, "\[pending\]")).Count
    $Format = "[bracket]"
}

Log "format detected: $Format"
Log "phases: total=$TOTAL complete=$COMPLETE in_progress=$IN_PROGRESS pending=$PENDING"

if ($COMPLETE -eq $TOTAL -and $TOTAL -gt 0) {
    $msg = "[planning-with-files] ALL PHASES COMPLETE ($COMPLETE/$TOTAL). If the user has additional work, add new phases to $PlanFile before starting."
    Log "decision: ALL COMPLETE"
    $output = @{
        hookSpecificOutput = @{
            hookEventName = "AgentStop"
            additionalContext = $msg
        }
    }
    $json = $output | ConvertTo-Json -Depth 3 -Compress
    Log "stdout: $($json.Length) chars"
    $json
    exit 0
}

$msg = "[planning-with-files] Task incomplete ($COMPLETE/$TOTAL phases done). Update progress.md, then read $PlanFile and continue working on the remaining phases."
Log "decision: INCOMPLETE"
$output = @{
    hookSpecificOutput = @{
        hookEventName = "AgentStop"
        additionalContext = $msg
    }
}
$json = $output | ConvertTo-Json -Depth 3 -Compress
Log "stdout: $($json.Length) chars"
$json
exit 0
# planning-with-files: Agent stop hook for GitHub Copilot (PowerShell)
# Checks if all phases in task_plan.md are complete.
# Injects continuation context if phases are incomplete.
# Always exits 0 — outputs JSON to stdout.

# Read stdin (required — Copilot pipes JSON to stdin)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$InputData = [Console]::In.ReadToEnd()

$PlanFile = "task_plan.md"

if (-not (Test-Path $PlanFile)) {
    Write-Output '{}'
    exit 0
}

$content = Get-Content $PlanFile -Raw -Encoding UTF8

# Count total phases
$TOTAL = ([regex]::Matches($content, "### Phase")).Count

# Check for **Status:** format first
$COMPLETE = ([regex]::Matches($content, "\*\*Status:\*\* complete")).Count
$IN_PROGRESS = ([regex]::Matches($content, "\*\*Status:\*\* in_progress")).Count
$PENDING = ([regex]::Matches($content, "\*\*Status:\*\* pending")).Count

# Fallback: check for [complete] inline format
if ($COMPLETE -eq 0 -and $IN_PROGRESS -eq 0 -and $PENDING -eq 0) {
    $COMPLETE = ([regex]::Matches($content, "\[complete\]")).Count
    $IN_PROGRESS = ([regex]::Matches($content, "\[in_progress\]")).Count
    $PENDING = ([regex]::Matches($content, "\[pending\]")).Count
}

if ($COMPLETE -eq $TOTAL -and $TOTAL -gt 0) {
    $msg = "[planning-with-files] ALL PHASES COMPLETE ($COMPLETE/$TOTAL). If the user has additional work, add new phases to $PlanFile before starting."
    $output = @{
        hookSpecificOutput = @{
            hookEventName = "AgentStop"
            additionalContext = $msg
        }
    }
    $output | ConvertTo-Json -Depth 3 -Compress
    exit 0
}

$msg = "[planning-with-files] Task incomplete ($COMPLETE/$TOTAL phases done). Update progress.md, then read $PlanFile and continue working on the remaining phases."
$output = @{
    hookSpecificOutput = @{
        hookEventName = "AgentStop"
        additionalContext = $msg
    }
}
$output | ConvertTo-Json -Depth 3 -Compress
exit 0
