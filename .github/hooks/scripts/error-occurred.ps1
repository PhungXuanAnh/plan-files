# planning-with-files: Error hook for GitHub Copilot (Windows PowerShell)
# Logs errors to task_plan.md when the agent encounters an error.
# Debug log at: tmp/hook-logs/plan-with-files/error-occurred.log

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
$planFile = if ($PlanDir) { Join-Path $PlanDir "task_plan.md" } else { "" }

# --- Logging setup -----------------------------------------------------------
$LogDir = "tmp/hook-logs/plan-with-files"
$LogFile = Join-Path $LogDir "error-occurred.log"
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

Log "=== error-occurred ==="
Log "cwd: $(Get-Location)"
Log "plan source: $PlanSource -> $planFile"

# Read stdin
$input = [Console]::In.ReadToEnd()
$InputPreview = ($input -replace "`r?`n", " ")
if ($InputPreview.Length -gt 500) { $InputPreview = $InputPreview.Substring(0, 500) }
Log "stdin (first 500 chars, $($input.Length) total): $InputPreview"

if (-not (Test-Path $planFile)) {
    Log "$(if($PlanFile){$PlanFile}else{"task_plan.md"}): ABSENT -> emitting {} (no-op)"
    Write-Output '{}'
    exit 0
}
Log "${PlanFile}: present"

try {
    $data = $input | ConvertFrom-Json
    $errorMsg = ""
    if ($data.error -is [PSCustomObject]) {
        $errorMsg = $data.error.message
    } elseif ($data.error) {
        $errorMsg = [string]$data.error
    }

    if ($errorMsg) {
        $truncated = $errorMsg.Substring(0, [Math]::Min(200, $errorMsg.Length))
        Log "extracted error.message (truncated to 200): $truncated"
        $context = "[planning-with-files] Error detected: $truncated. Log this error in $PlanFile under Errors Encountered with the attempt number and resolution."
        $escaped = $context | ConvertTo-Json
        $output = "{`"hookSpecificOutput`":{`"hookEventName`":`"ErrorOccurred`",`"additionalContext`":$escaped}}"
        Log "stdout: $($output.Length) chars"
        Write-Output $output
    } else {
        Log "no error.message found in stdin -> emitting {}"
        Write-Output '{}'
    }
} catch {
    Log "exception parsing stdin: $($_.Exception.Message) -> emitting {}"
    Write-Output '{}'
}

exit 0
# planning-with-files: Error hook for GitHub Copilot (Windows PowerShell)
# Logs errors to task_plan.md when the agent encounters an error.

$planFile = "task_plan.md"

if (-not (Test-Path $planFile)) {
    Write-Output '{}'
    exit 0
}

# Read stdin
$input = [Console]::In.ReadToEnd()

try {
    $data = $input | ConvertFrom-Json
    $errorMsg = ""
    if ($data.error -is [PSCustomObject]) {
        $errorMsg = $data.error.message
    } elseif ($data.error) {
        $errorMsg = [string]$data.error
    }

    if ($errorMsg) {
        $truncated = $errorMsg.Substring(0, [Math]::Min(200, $errorMsg.Length))
        $context = "[planning-with-files] Error detected: $truncated. Log this error in $PlanFile under Errors Encountered with the attempt number and resolution."
        $escaped = $context | ConvertTo-Json
        Write-Output "{`"hookSpecificOutput`":{`"hookEventName`":`"ErrorOccurred`",`"additionalContext`":$escaped}}"
    } else {
        Write-Output '{}'
    }
} catch {
    Write-Output '{}'
}

exit 0
