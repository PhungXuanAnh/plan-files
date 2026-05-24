# planning-with-files: Agent stop hook for Codex (PowerShell)
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

# --- stop_hook_active guard --------------------------------------------------
# Per Codex docs: if Codex is calling Stop again because we previously blocked,
# stop_hook_active=true is in stdin. Emit {} to break the loop.
$StopHookActive = $false
try {
    $_inObj = $InputData | ConvertFrom-Json -ErrorAction Stop
    if ($_inObj.stop_hook_active) { $StopHookActive = $true }
} catch {}
Log "stop_hook_active: $StopHookActive"
if ($StopHookActive) {
    Log "decision: GUARDED (stop_hook_active=true) -> emitting {} to break loop"
    Write-Output '{}'
    exit 0
}

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
# Deferred: only count when "(reason)" with at least one non-whitespace char is present.
$DEFERRED = ([regex]::Matches($content, "\*\*Status:\*\*\s*deferred\s*\(\s*[^)\s][^)]*\)")).Count
# Detect malformed deferred markers (bare "deferred" or "deferred ()") so we can BLOCK.
$DeferredBad = $false
$_deferredLines = [regex]::Matches($content, "\*\*Status:\*\*\s*deferred[^\r\n]*")
foreach ($m in $_deferredLines) {
    if ($m.Value -notmatch '\*\*Status:\*\*\s*deferred\s*\(\s*[^)\s][^)]*\)') {
        $DeferredBad = $true
        break
    }
}
$Format = "Status:"

if ($COMPLETE -eq 0 -and $IN_PROGRESS -eq 0 -and $PENDING -eq 0 -and $DEFERRED -eq 0) {
    $COMPLETE = ([regex]::Matches($content, "\[complete\]")).Count
    $IN_PROGRESS = ([regex]::Matches($content, "\[in_progress\]")).Count
    $PENDING = ([regex]::Matches($content, "\[pending\]")).Count
    $Format = "[bracket]"
}

Log "format detected: $Format"
Log "phases: total=$TOTAL complete=$COMPLETE in_progress=$IN_PROGRESS pending=$PENDING deferred=$DEFERRED deferred_bad=$DeferredBad"

# --- Remaining-in-current-phase snippet (count + first unchecked) ----------
$PhaseRaw = ""
$capture = $false
$inComment = $false
foreach ($line in (Get-Content $PlanFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
    if ($line -match '^## Current Phase\s*$') { $capture = $true; continue }
    if ($line -match '^## ') { $capture = $false }
    if ($capture) {
        if ($line -match '<!--') { $inComment = $true }
        if (-not $inComment) { $PhaseRaw += "$line`n" }
        if ($line -match '-->') { $inComment = $false }
    }
}
$PhaseRaw = $PhaseRaw.Trim()
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
    if ($count -gt 0) {
        $RemainingLine = " ${PhaseNum}: $count unchecked item(s). First: $first"
    }
    Log "remaining: count=$count"
}

if ($TOTAL -eq 0) {
    # Plan file present but contains zero `### Phase N:` headings.
    # Almost always a FORMAT-CONTRACT violation: the agent paraphrased
    # headings (e.g. `## Phase 0 — Preparation \`[done]\``) instead of using
    # the strict template. BLOCK with a precise actionable message.
    $reason = "[planning-with-files] FORMAT CONTRACT VIOLATION in ${PlanFile}: 0 phases detected. Required heading format is exactly '### Phase N: Title' (level-3, colon, no decorations, no backticks), and each phase MUST end with a line '- **Status:** pending|in_progress|complete|deferred (reason)'. See skills/planning-with-files/SKILL.md > FORMAT CONTRACT. Fix the plan file headings/status markers, then continue."
    Log "decision: BLOCK (FORMAT CONTRACT - TOTAL=0)"
    $output = @{ decision = "block"; reason = $reason }
    $json = $output | ConvertTo-Json -Depth 3 -Compress
    Log "stdout: $($json.Length) chars"
    $json
    exit 0
}

if ($DeferredBad) {
    # A `**Status:** deferred` line exists but is missing the required
    # `(non-empty reason)` parenthetical. Always BLOCK — bare deferred is
    # never valid, regardless of completion state.
    $reason = "[planning-with-files] FORMAT CONTRACT VIOLATION in ${PlanFile}: a phase has '**Status:** deferred' but is missing the REQUIRED parenthesised reason. The only valid form is '- **Status:** deferred (explicit reason)' where the reason names the blocker - e.g. '- **Status:** deferred (blocked by upstream API change)' or '- **Status:** deferred (user asked to split into follow-up PR)'. Bare 'deferred', 'deferred ()', or vague reasons are NOT accepted. Do NOT use 'deferred' to silence the stop hook after a transient error - use the 3-strike protocol and escalate to the user instead. See skills/planning-with-files/SKILL.md > FORMAT CONTRACT > Phase status."
    Log "decision: BLOCK (DEFERRED_NO_REASON)"
    $output = @{ decision = "block"; reason = $reason }
    $json = $output | ConvertTo-Json -Depth 3 -Compress
    Log "stdout: $($json.Length) chars"
    $json
    exit 0
}

if ($COMPLETE -eq 0 -and $IN_PROGRESS -eq 0 -and $PENDING -eq 0 -and $DEFERRED -eq 0) {
    # Phases exist but no status markers were recognized at all.
    $reason = "[planning-with-files] FORMAT CONTRACT VIOLATION in ${PlanFile}: $TOTAL phase heading(s) found but ZERO recognized status markers. Each phase MUST end with a line: '- **Status:** pending' OR '- **Status:** in_progress' OR '- **Status:** complete' OR '- **Status:** deferred (reason)'. The inline form '[complete]'/'[in_progress]'/'[pending]' on the heading is also accepted. Backtick-wrapped or paraphrased markers (e.g. ``[done]``, ``[not started]``, (in progress)) are NOT recognized. See skills/planning-with-files/SKILL.md > FORMAT CONTRACT. Fix the markers, then continue."
    Log "decision: BLOCK (FORMAT CONTRACT - no recognized status markers across $TOTAL phases)"
    $output = @{ decision = "block"; reason = $reason }
    $json = $output | ConvertTo-Json -Depth 3 -Compress
    Log "stdout: $($json.Length) chars"
    $json
    exit 0
}

# --- Non-Phase work check ---------------------------------------------------
# Catches the bypass pattern where the agent invents `### Step N:` /
# `### Task N:` etc. to hide unchecked work from the `### Phase` scanner.
# Runs regardless of COMPLETE/TOTAL. Heading-only sections (no `- [ ]`
# items) are not flagged.
$NonPhaseHeading = ""
$cur = ""
$curIsPhase = $false
$curUnchecked = 0
$inCmt = $false
foreach ($line in (Get-Content $PlanFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
    if ($line -match '<!--') { $inCmt = $true }
    if ($inCmt) { if ($line -match '-->') { $inCmt = $false }; continue }
    if ($line -match '^### ') {
        if ($cur -and $curUnchecked -gt 0 -and -not $curIsPhase) {
            $NonPhaseHeading = $cur; break
        }
        $cur = ($line -replace '^###\s*','')
        $curIsPhase = ($line -match '^###\s+Phase\s+\d')
        $curUnchecked = 0
        continue
    }
    if ($line -match '^## ') {
        if ($cur -and $curUnchecked -gt 0 -and -not $curIsPhase) {
            $NonPhaseHeading = $cur; break
        }
        $cur = ""; $curIsPhase = $false; $curUnchecked = 0
        continue
    }
    if (-not $cur) { continue }
    if ($line -match '^-\s\[\s\]') { $curUnchecked++ }
}
if (-not $NonPhaseHeading -and $cur -and $curUnchecked -gt 0 -and -not $curIsPhase) {
    $NonPhaseHeading = $cur
}
if ($NonPhaseHeading) {
    if ($NonPhaseHeading.Length -gt 200) { $NonPhaseHeading = $NonPhaseHeading.Substring(0,200) + "..." }
    $reason = "[planning-with-files] FORMAT CONTRACT VIOLATION in ${PlanFile}: heading '### $NonPhaseHeading' contains unchecked '- [ ]' work items but is NOT a recognized phase heading. The ONLY heading form recognized as work is '### Phase N: Title' (level-3, the literal word 'Phase', a number, a colon). 'Step', 'Task', 'Stage', 'Iteration', 'Milestone', etc. are NOT accepted - they hide work from the gate. Rename the heading to '### Phase N: ...' (pick the next free N) and add '- **Status:** pending|in_progress' on its last line. See skills/planning-with-files/SKILL.md > FORMAT CONTRACT. Do NOT stop until every block of unchecked work lives under a '### Phase N:' heading."
    Log "decision: BLOCK (NON-PHASE WORK - '$NonPhaseHeading' has unchecked items)"
    $output = @{ decision = "block"; reason = $reason }
    $json = $output | ConvertTo-Json -Depth 3 -Compress
    Log "stdout: $($json.Length) chars"
    $json
    exit 0
}

if ($COMPLETE + $DEFERRED -ge $TOTAL -and $TOTAL -gt 0) {
    # All phases settled (complete or deferred-with-reason) -> let the agent stop.
    Log "decision: ALL SETTLED (complete=$COMPLETE deferred=$DEFERRED total=$TOTAL) -> emitting {} (allow stop)"
    Write-Output '{}'
    exit 0
}

# Task incomplete -> BLOCK the stop and tell the agent why to continue.
# Per Codex docs: Stop continuation uses top-level decision="block" + reason.
$Settled = $COMPLETE + $DEFERRED
$DeferredNote = ""
if ($DEFERRED -gt 0) { $DeferredNote = " (including $DEFERRED deferred)" }
$reason = "[planning-with-files] Task incomplete ($Settled/$TOTAL phases settled$DeferredNote).${RemainingLine} Update progress.md, then read $PlanFile and continue working on the remaining phases. If you genuinely cannot continue (blocked / waiting on user), either say so explicitly so the user can intervene, or mark the phase '- **Status:** deferred (explicit reason - blocker or user request)' if the deferral was explicitly agreed."
Log "decision: BLOCK ($Settled/$TOTAL phases settled, deferred=$DEFERRED)"
$output = @{ decision = "block"; reason = $reason }
$json = $output | ConvertTo-Json -Depth 3 -Compress
Log "stdout: $($json.Length) chars"
$json
exit 0
