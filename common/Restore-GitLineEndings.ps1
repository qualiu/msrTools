<#
.SYNOPSIS
    After running msr -R (or any tool that rewrites files with OS-native EOL), restore each modified file's original EOL bytes by delegating all diff
    computation to git itself. Only the lines that actually changed at the content level are kept; everything else is copied byte-for-byte from the git
    index blob.

.DESCRIPTION
    Why this tool exists
    --------------------
    msr -R is the fastest way to do regex find-and-replace across many files, but on Windows it rewrites files with CRLF even when the index stored them
    as LF (or historical mixed LF+CRLF). A 1-line logical change then looks like "every line changed" in `git diff --numstat`, polluting commits and PR
    reviews.

    Algorithm (batched)
    -------------------
      1. ONE call to `git diff --numstat --ignore-cr-at-eol -- <f1> <f2> ...` classifies each file as:
           - PureEol  (add=0, del=0)   -> content identical, only EOL noise
           - RealDiff (add+del > 0)    -> actual content changed
           - Binary   (add='-')        -> skip
      2. If any RealDiff files existed, ONE `git diff --ignore-cr-at-eol --no-color --binary -- <realdiff files>` captures their patch BEFORE step 3.
      3. ONE `git checkout -- <all targets>` restores every file from the index blob (byte-exact original).
      4. ONE `git apply --ignore-whitespace` re-applies the captured patch on top of the restored bytes — only real-change lines get re-written, every
         other line keeps its original EOL.
    Total git calls: 3-4 for the entire batch (chunked only to avoid OS command-line length overflow). Typical 38-file reconcile: ~2-3s on Windows.

    Non-destructive guarantees
    --------------------------
      - Only files listed by `git status --porcelain` are considered.
      - Untracked files / binary files are skipped (no index blob, or no textual diff).
      - `-DryRun` prints the plan without modifying any file.
      - If `git apply` fails, files are left in index-restored state and the error is reported (safer than leaving CRLF-polluted noise).

.PARAMETER WorkingDir
    Git working directory. Defaults to current location.

.PARAMETER Files
    Optional explicit list of relative paths. When omitted, auto-detects via `git status --porcelain`.

.PARAMETER DryRun
    Print the plan without changing the working tree.

.PARAMETER IncludeUntracked
    Include untracked files (`??`) in the report. They are still skipped.

.PARAMETER Force
    Bypass the >20 RealDiff guard rail. See ⚠️ NOTES below — only use when you have confirmed via -DryRun that the batched reapply will succeed, OR when
    you have a recent commit/stash to recover from if the apply step fails.

.EXAMPLE
    msr -rp src/ -f "\.cs$" -t "\bOldName\b" -o "NewName" -R
    .\Restore-GitLineEndings.ps1
    git diff --numstat           # shows only real N/N counts

.NOTES
    Requirements: git 2.19+ (for `--ignore-cr-at-eol`).

    ⚠️ DESTRUCTIVE-ON-LARGE-BATCH FOOTGUN
    -------------------------------------
    The batched phase 4 (`git apply`) can silently fail to reapply when a single huge patch combines many RealDiff files with complex hunks. When the
    apply call exits non-zero, every RealDiff file is left in index-restored state — meaning your msr -R replacements are GONE from those files. The
    summary will show `Errors > N`, but if you skim past it you will lose work.

    Safe usage windows (no -Force needed):
      (a) Single-file edits.
      (b) Batches where ALL files are PureEolOnly (e.g. you ran `git checkout` then accidentally introduced EOL noise without content change).
      (c) Batches with <=20 RealDiff files.

    Outside these windows the script REFUSES to run unless you pass `-Force`. In that case: either commit/stash beforehand so msr -R can be re-applied
    if needed, OR accept the EOL noise — msbuild does not care about EOL style in csproj/.cs files.

    Why not just remove the tool? It's still the fastest way to get clean `git diff --numstat` on small replace batches, which matters for PR review and
    `git blame`. Keep it; cap the blast radius.

    Notes
    -----
      - We deliberately do NOT name the function parameter $Args (it's a reserved automatic variable in PowerShell). We splat a normal array directly to git.
      - We use `2>&1` + ErrorRecord filtering, not `2>$null`, because the latter has been flaky in PS 5.1 when git writes nothing to stderr.
      - File-list chunking uses a conservative 6000-char budget per git invocation; long path repos may need a larger budget via -MaxChunkChars (helper only).
#>
[CmdletBinding()]
param(
    [string]   $WorkingDir = (Get-Location).Path,
    [string[]] $Files,
    [switch]   $DryRun,
    [switch]   $IncludeUntracked,
    [switch]   $Force
)

$ErrorActionPreference = 'Stop'

# Threshold for the >20 RealDiff footgun guard. See ⚠️ block in header NOTES.
$script:RealDiffGuardThreshold = 20

# ---------------- Helpers ----------------

function Test-GitRepo {
    param([string] $Path)
    $prev = Get-Location
    try {
        Set-Location $Path
        $null = git rev-parse --git-dir 2>$null
        return ($LASTEXITCODE -eq 0)
    } finally {
        Set-Location $prev
    }
}

function Get-RepoRoot {
    param([string] $Path)
    $prev = Get-Location
    try {
        Set-Location $Path
        $root = (git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
        return $root.Trim()
    } finally {
        Set-Location $prev
    }
}

function Get-ModifiedFiles {
    param([string] $RepoRoot, [bool] $IncludeUntracked)
    $prev = Get-Location
    try {
        Set-Location $RepoRoot
        $raw = git status --porcelain -z 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        if ([string]::IsNullOrEmpty($raw)) { return @() }
        $entries = @($raw -split "`0" | Where-Object { $_ -ne '' })
        $results = New-Object System.Collections.Generic.List[object]
        $i = 0
        while ($i -lt $entries.Count) {
            $entry = $entries[$i]
            if ($entry.Length -lt 3) { $i++; continue }
            $code = $entry.Substring(0, 2)
            $path = $entry.Substring(3)
            # Rename porcelain format: `XY old\0new`. Consume the next entry as the new path.
            if ($code -match '^R.|^.R') {
                $i++
                if ($i -lt $entries.Count) { $path = $entries[$i] }
            }
            $isUntracked = ($code -eq '??')
            if ($isUntracked -and -not $IncludeUntracked) { $i++; continue }
            $results.Add([pscustomobject]@{
                Path       = $path
                StatusCode = $code
                Untracked  = $isUntracked
            }) | Out-Null
            $i++
        }
        return $results.ToArray()
    } finally {
        Set-Location $prev
    }
}

function Invoke-GitCapture {
    <#
    Runs `git <gitArgs>` in $RepoRoot and returns stdout as a string. Sets $script:LastGitExitCode for the caller. We collect stderr as ErrorRecord and
    drop it from the returned text — cleaner than `2>$null` (flaky in PS 5.1) and we still get $LASTEXITCODE.
    #>
    param(
        [string]   $RepoRoot,
        [string[]] $GitArgv
    )
    $prev = Get-Location
    try {
        Set-Location $RepoRoot
        $raw = & git @GitArgv 2>&1
        $script:LastGitExitCode = $LASTEXITCODE
        if ($null -eq $raw) { return '' }
        $lines = @()
        foreach ($item in $raw) {
            if ($item -is [System.Management.Automation.ErrorRecord]) { continue }
            $lines += [string]$item
        }
        return ($lines -join "`n")
    } finally {
        Set-Location $prev
    }
}

function Invoke-GitBatched {
    <#
    Runs `git <gitArgs> -- <files...>` but chunks <files...> so that no single invocation exceeds the OS command-line length limit. Concatenates all
    stdout into $StdoutBuilder. Returns $true iff every invocation had exit 0.
    #>
    param(
        [string]   $RepoRoot,
        [string[]] $GitArgs,
        [string[]] $Files,
        [ref]      $StdoutBuilder,
        [int]      $MaxChunkChars = 6000
    )
    $allOk = $true
    $i = 0
    while ($i -lt $Files.Count) {
        $chunk = New-Object System.Collections.Generic.List[string]
        $chunkLen = 0
        while ($i -lt $Files.Count) {
            $f = $Files[$i]
            $need = $f.Length + 3
            if ($chunk.Count -gt 0 -and ($chunkLen + $need) -gt $MaxChunkChars) {
                break
            }
            $chunk.Add($f) | Out-Null
            $chunkLen += $need
            $i++
        }
        $argList = @($GitArgs) + @('--') + $chunk.ToArray()
        $out = Invoke-GitCapture -RepoRoot $RepoRoot -GitArgv $argList
        if ($script:LastGitExitCode -ne 0) { $allOk = $false }
        if (-not [string]::IsNullOrEmpty($out)) {
            [void]$StdoutBuilder.Value.AppendLine($out)
        }
    }
    return $allOk
}

function Save-StringToFileUtf8NoBom {
    param([string] $Content, [string] $Path)
    # Write raw bytes (no BOM) so the LF/CRLF that git produced in the patch survives the round-trip; AddText/Set-Content would normalize.
    $enc = New-Object System.Text.UTF8Encoding($false)
    $bytes = $enc.GetBytes($Content)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

# ---------------- Main ----------------

if (-not (Test-GitRepo -Path $WorkingDir)) {
    Write-Error "Not a git repository: $WorkingDir"
    exit 2
}

$repoRoot = Get-RepoRoot -Path $WorkingDir
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    Write-Error "Cannot resolve git repo root from: $WorkingDir"
    exit 2
}

if ($Files -and $Files.Count -gt 0) {
    $candidates = foreach ($f in $Files) {
        [pscustomobject]@{ Path = ($f -replace '\\', '/'); StatusCode = '  '; Untracked = $false }
    }
} else {
    $candidates = Get-ModifiedFiles -RepoRoot $repoRoot -IncludeUntracked:$IncludeUntracked
}

if (-not $candidates -or $candidates.Count -eq 0) {
    Write-Host "No modified tracked files found." -ForegroundColor Yellow
    exit 0
}

$stats = [pscustomobject]@{
    Total         = 0
    PureEolOnly   = 0
    DiffApplied   = 0
    AlreadyClean  = 0
    Skipped       = 0
    Binary        = 0
    NoIndex       = 0
    Error         = 0
}

$report = New-Object System.Collections.Generic.List[object]
$timer  = [System.Diagnostics.Stopwatch]::StartNew()

# Up-front partition: skip untracked / missing / binary so they don't burn a numstat slot.
$processable = New-Object System.Collections.Generic.List[string]
foreach ($c in $candidates) {
    $stats.Total++
    $rel = $c.Path
    $abs = Join-Path $repoRoot $rel

    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) {
        $report.Add([pscustomobject]@{ File=$rel; Action='SKIP'; Reason='not-a-file'; RealLines='-' }) | Out-Null
        $stats.Skipped++
        continue
    }
    if ($c.Untracked) {
        $report.Add([pscustomobject]@{ File=$rel; Action='SKIP'; Reason='untracked-no-index-blob'; RealLines='-' }) | Out-Null
        $stats.NoIndex++
        continue
    }
    $processable.Add($rel) | Out-Null
}

if ($processable.Count -eq 0) {
    $timer.Stop()
    $report | Format-Table -AutoSize
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host ("  Total              : {0}" -f $stats.Total)
    Write-Host ("  PureEolReverted    : {0}" -f $stats.PureEolOnly)
    Write-Host ("  DiffReapplied      : {0}" -f $stats.DiffApplied)
    Write-Host ("  Skipped            : {0}" -f $stats.Skipped)
    Write-Host ("  NoIndex            : {0}" -f $stats.NoIndex)
    Write-Host ("  Elapsed            : {0:N2}s" -f $timer.Elapsed.TotalSeconds)
    exit 0
}

# ============================================================================
# PHASE 1: BATCH numstat with --ignore-cr-at-eol to classify every file.
# One git invocation for the whole batch (chunked only to avoid command-line length overflow).
# ============================================================================

$numstatBuf = [ref](New-Object System.Text.StringBuilder)
$numstatOk = Invoke-GitBatched -RepoRoot $repoRoot `
    -GitArgs @('diff','--numstat','--ignore-cr-at-eol') `
    -Files $processable.ToArray() -StdoutBuilder $numstatBuf

if (-not $numstatOk) {
    Write-Error "git diff --numstat --ignore-cr-at-eol failed. Aborting."
    exit 2
}

$classification = @{}   # rel-path -> realLines (int) or -1 binary
foreach ($f in $processable) { $classification[$f] = $null }

foreach ($line in ($numstatBuf.Value.ToString() -split "`n")) {
    $line = $line.TrimEnd("`r")
    if ([string]::IsNullOrEmpty($line)) { continue }
    $parts = $line -split "`t", 3
    if ($parts.Count -lt 3) { continue }
    $addStr = $parts[0]; $delStr = $parts[1]; $path = $parts[2]
    if ($addStr -eq '-' -or $delStr -eq '-') {
        $classification[$path] = -1
        continue
    }
    $realLines = 0
    [void][int]::TryParse($addStr, [ref]$realLines)
    $delN = 0
    [void][int]::TryParse($delStr, [ref]$delN)
    $classification[$path] = $realLines + $delN
}

$pureEolFiles    = New-Object System.Collections.Generic.List[string]
$realDiffFiles   = New-Object System.Collections.Generic.List[string]
$realLinesByFile = @{}

foreach ($f in $processable) {
    $cls = $classification[$f]
    if ($null -eq $cls) {
        # Not in numstat output = git sees no diff at all under --ignore-cr-at-eol. Nothing to do for this file.
        $report.Add([pscustomobject]@{ File=$f; Action='OK'; Reason='no-diff'; RealLines=0 }) | Out-Null
        $stats.AlreadyClean++
        continue
    }
    if ($cls -lt 0) {
        $report.Add([pscustomobject]@{ File=$f; Action='SKIP'; Reason='binary-numstat'; RealLines='-' }) | Out-Null
        $stats.Binary++
        continue
    }
    if ($cls -eq 0) {
        $pureEolFiles.Add($f) | Out-Null
    } else {
        $realDiffFiles.Add($f) | Out-Null
        $realLinesByFile[$f] = $cls
    }
}

# ⚠️ Guard rail: refuse large RealDiff batches without -Force. See header NOTES → DESTRUCTIVE-ON-LARGE-BATCH FOOTGUN.
if (-not $DryRun -and -not $Force -and $realDiffFiles.Count -gt $script:RealDiffGuardThreshold) {
    Write-Host ""
    Write-Host ("REFUSING: {0} files have real content changes (threshold: {1})." -f $realDiffFiles.Count, $script:RealDiffGuardThreshold) -ForegroundColor Red
    Write-Host "  The batched `git apply` step can silently fail on large patches, leaving msr -R replacements GONE from these files." -ForegroundColor Red
    Write-Host "  Options:" -ForegroundColor Yellow
    Write-Host "    1. Re-run with -DryRun to inspect the plan first." -ForegroundColor Yellow
    Write-Host "    2. Commit/stash before re-running with -Force so msr -R can be re-applied if apply fails." -ForegroundColor Yellow
    Write-Host "    3. Accept the EOL noise — msbuild does not care about EOL style in csproj/.cs files." -ForegroundColor Yellow
    exit 3
}

# DryRun: print plan & exit.
if ($DryRun) {
    foreach ($f in $pureEolFiles) {
        $report.Add([pscustomobject]@{ File=$f; Action='DRYRUN'; Reason='pure-eol-noise-revert'; RealLines=0 }) | Out-Null
    }
    foreach ($f in $realDiffFiles) {
        $report.Add([pscustomobject]@{ File=$f; Action='DRYRUN'; Reason='revert+reapply'; RealLines=$realLinesByFile[$f] }) | Out-Null
    }
    $timer.Stop()
    $report | Sort-Object File | Format-Table -AutoSize
    Write-Host ""
    Write-Host "Summary (dry-run):" -ForegroundColor Cyan
    Write-Host ("  Total              : {0}" -f $stats.Total)
    Write-Host ("  Would PureEol      : {0}" -f $pureEolFiles.Count) -ForegroundColor Green
    Write-Host ("  Would DiffReapply  : {0}" -f $realDiffFiles.Count) -ForegroundColor Green
    Write-Host ("  AlreadyClean       : {0}" -f $stats.AlreadyClean)
    Write-Host ("  Skipped            : {0}" -f $stats.Skipped)
    Write-Host ("  Binary             : {0}" -f $stats.Binary)
    Write-Host ("  NoIndex            : {0}" -f $stats.NoIndex)
    Write-Host ("  Elapsed            : {0:N2}s" -f $timer.Elapsed.TotalSeconds)
    exit 0
}

# ============================================================================
# PHASE 2: Capture batched patch for RealDiff files BEFORE we checkout. One git invocation (chunked).
# ============================================================================

$patchText = ''
if ($realDiffFiles.Count -gt 0) {
    $patchBuf = [ref](New-Object System.Text.StringBuilder)
    $patchOk = Invoke-GitBatched -RepoRoot $repoRoot `
        -GitArgs @('diff','--ignore-cr-at-eol','--no-color','--binary') `
        -Files $realDiffFiles.ToArray() -StdoutBuilder $patchBuf
    if (-not $patchOk) {
        Write-Error "git diff (patch capture) failed. Aborting."
        exit 2
    }
    $patchText = $patchBuf.Value.ToString()
}

# ============================================================================
# PHASE 3: Batched `git checkout -- <all reconcile targets>` in one or a few calls. Restores byte-exact index contents for every target file.
# ============================================================================

$allTargets = New-Object System.Collections.Generic.List[string]
foreach ($f in $pureEolFiles)  { $allTargets.Add($f) | Out-Null }
foreach ($f in $realDiffFiles) { $allTargets.Add($f) | Out-Null }

if ($allTargets.Count -gt 0) {
    $coBuf = [ref](New-Object System.Text.StringBuilder)
    $coOk = Invoke-GitBatched -RepoRoot $repoRoot `
        -GitArgs @('checkout','--quiet') `
        -Files $allTargets.ToArray() -StdoutBuilder $coBuf
    if (-not $coOk) {
        Write-Error "git checkout failed for some files. Aborting."
        exit 2
    }
}

foreach ($f in $pureEolFiles) {
    $report.Add([pscustomobject]@{ File=$f; Action='REVERT'; Reason='pure-eol-noise'; RealLines=0 }) | Out-Null
    $stats.PureEolOnly++
}

# ============================================================================
# PHASE 4: If there were RealDiff files, apply the captured patch in a SINGLE `git apply` call.
# ============================================================================

if ($realDiffFiles.Count -gt 0 -and -not [string]::IsNullOrEmpty($patchText)) {
    $tmpPatch = [System.IO.Path]::GetTempFileName()
    try {
        Save-StringToFileUtf8NoBom -Content $patchText -Path $tmpPatch

        $prev = Get-Location
        try {
            Set-Location $repoRoot
            & git apply --ignore-whitespace --whitespace=nowarn $tmpPatch 2>&1 | Out-Null
            $applyExit = $LASTEXITCODE
        } finally {
            Set-Location $prev
        }

        if ($applyExit -eq 0) {
            foreach ($f in $realDiffFiles) {
                $report.Add([pscustomobject]@{ File=$f; Action='APPLY'; Reason='real-diff-preserved'; RealLines=$realLinesByFile[$f] }) | Out-Null
                $stats.DiffApplied++
            }
        } else {
            # ⚠️ Batch apply failed → msr -R content is GONE from these files (left in index-restored state). Loud red error in summary. Per-file fallback
            # is intentionally NOT implemented: it would mask the problem and make the failure mode less obvious to the operator.
            foreach ($f in $realDiffFiles) {
                $report.Add([pscustomobject]@{ File=$f; Action='ERROR'; Reason='batch-apply-failed-left-index-state'; RealLines=$realLinesByFile[$f] }) | Out-Null
                $stats.Error++
            }
        }
    } finally {
        Remove-Item -Force -LiteralPath $tmpPatch -ErrorAction SilentlyContinue
    }
}

$timer.Stop()

$report | Sort-Object File | Format-Table -AutoSize

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host ("  Total              : {0}" -f $stats.Total)
Write-Host ("  PureEolReverted    : {0}" -f $stats.PureEolOnly) -ForegroundColor Green
Write-Host ("  DiffReapplied      : {0}" -f $stats.DiffApplied) -ForegroundColor Green
Write-Host ("  AlreadyClean       : {0}" -f $stats.AlreadyClean)
Write-Host ("  Skipped            : {0}" -f $stats.Skipped)
Write-Host ("  Binary             : {0}" -f $stats.Binary)
Write-Host ("  NoIndex            : {0}" -f $stats.NoIndex)
Write-Host ("  Errors             : {0}" -f $stats.Error) -ForegroundColor $(if ($stats.Error -gt 0) { 'Red' } else { 'Green' })
Write-Host ("  Elapsed            : {0:N2}s" -f $timer.Elapsed.TotalSeconds)

exit $(if ($stats.Error -gt 0) { 1 } else { 0 })
