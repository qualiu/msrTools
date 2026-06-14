<#
.SYNOPSIS
    Embed a UTF-8 <activeCodePage> manifest into msr.exe / nin.exe so CJK command-line patterns work without changing the system locale.

.DESCRIPTION
    On Windows where the registry ANSI code page (ACP) is not 65001 (e.g. 1252), msr/nin use an ANSI main() entry, so non-ASCII command-line args
    (Chinese -t/-x patterns) are truncated to '?' before the tool sees them -> 0 matches or a regex crash.

    Fix without touching the system locale: embed a manifest declaring <activeCodePage>UTF-8</activeCodePage> into resource #1 of each exe via the
    Windows SDK mt.exe. That makes those single processes read their command line as UTF-8. Pure-ASCII args are byte-identical, so existing scripts
    that call msr/nin are unaffected.

    mt.exe is discovered dynamically (PATH -> vswhere -> registry SDK roots -> Program Files env-var glob); nothing is hardcoded.
    Running msr/nin holders are freed via PsTool.ps1.

    Caller-shell scope (verified 2026-06-14 on ACP=1252 box, msr+nin patched):
      [OK] Git Bash direct: msr -t "<CJK>"      (UTF-8 argv -> CreateProcessW)
      [OK] pwsh -Command:  msr -t "<CJK>"       (UTF-16 -> CreateProcessW)
      [NO] cmd.exe / .bat / .cmd / cmdq / cmd <<<: cmd corrupts UTF-8 args using ACP before they reach msr; manifest cannot undo a parent's lossy
           ANSI conversion. `chcp 65001` only changes console codepage, NOT cmd's command-line parsing.
      For CJK from cmd-rooted contexts, pipe the pattern via UTF-8 file:  msr -f "@pat.txt"

    Idempotent: re-running -Apply 1 detects 'already patched' and skips; -Apply 1 -ForceRepair 1 re-merges but yields byte-identical MD5 + mtime.

.PARAMETER Apply
    '1'/'true'/'yes' = patch msr+nin. Empty (default) = dry-run, report state only.

.PARAMETER VerifyOnly
    '1'/'true'/'yes' = run the CJK probe and report FIXED/BROKEN; make no changes.

.PARAMETER Restore
    '1'/'true'/'yes' = restore each exe from its .utf8bak backup, then stop.

.PARAMETER NoKill
    '1'/'true'/'yes' = do NOT auto-kill running msr/nin before patching (default: kill so mt.exe can write the resource).

.PARAMETER ForceRepair
    '1'/'true'/'yes' = re-patch even if the exe already carries a UTF-8 manifest (re-merge from its current state).
    Mainly for testing that re-applying does not change the MD5.

.PARAMETER PatchWhenUtf8
    '1'/'true'/'yes' = patch even when the registry ACP is already 65001 (UTF-8). Default (empty) = skip the unnecessary patch on UTF-8 machines
    (msr/nin already handle CJK there; patching only bumps the file time + MD5). Use this to pre-patch an exe destined for a non-UTF-8 machine,
    or to force the patch in tests.

.PARAMETER Exe
    Explicit target exe path(s). Overrides auto-locating msr+nin on PATH. Repeatable.

.PARAMETER AutoInstallSdk
    '1'/'true'/'yes' = when mt.exe is not found anywhere, attempt to install the Windows SDK via winget (preferred) or the standalone installer.
    Requires admin rights for the installer fallback. Default (empty) = do not install, just error out as before.

.PARAMETER MtPath
    Explicit path to mt.exe. Overrides dynamic Windows SDK discovery.

.EXAMPLE
    pwsh -NoProfile -File common/Repair-MsrNinUtf8ArgsOnWindowsNonUtf8Acp.ps1
    # dry-run: report whether msr/nin are patched

.EXAMPLE
    pwsh -NoProfile -File common/Repair-MsrNinUtf8ArgsOnWindowsNonUtf8Acp.ps1 -Apply 1
    # patch msr+nin on PATH (auto-kills holders; may raise UAC)

.EXAMPLE
    pwsh -NoProfile -File common/Repair-MsrNinUtf8ArgsOnWindowsNonUtf8Acp.ps1 -VerifyOnly 1

.EXAMPLE
    pwsh -NoProfile -File common/Repair-MsrNinUtf8ArgsOnWindowsNonUtf8Acp.ps1 -Restore 1

.EXAMPLE
    pwsh -NoProfile -File common/Repair-MsrNinUtf8ArgsOnWindowsNonUtf8Acp.ps1 -Apply 1 -ForceRepair 1 -Exe D:/temp/msr.exe
    # re-patch an already-patched copy (test that the MD5 stays stable)

.EXAMPLE
    pwsh -NoProfile -File common/Repair-MsrNinUtf8ArgsOnWindowsNonUtf8Acp.ps1 -Apply 1 -Exe D:/lztool/msr.exe -MtPath "C:/Program Files (x86)/Windows Kits/10/bin/10.0.19041.0/x64/mt.exe"

.EXAMPLE
    pwsh -NoProfile -File common/Repair-MsrNinUtf8ArgsOnWindowsNonUtf8Acp.ps1 -Apply 1 -AutoInstallSdk 1
    # patch msr+nin; if mt.exe is missing, install Windows SDK automatically first
#>

[CmdletBinding()]
param(
    [string] $Apply = '',
    [string] $VerifyOnly = '',
    [string] $Restore = '',
    [string] $NoKill = '',
    [string] $ForceRepair = '',
    [string] $PatchWhenUtf8 = '',
    [string[]] $Exe = @(),
    [string] $MtPath = '',
    [string] $AutoInstallSdk = ''
)

Import-Module "$PSScriptRoot/BasicOsUtils.psm1"
Import-Module "$PSScriptRoot/CommonUtils.psm1"

$script:IsApply = Test-TruthValue $Apply
$script:IsVerifyOnly = Test-TruthValue $VerifyOnly
$script:IsRestore = Test-TruthValue $Restore
$script:IsNoKill = Test-TruthValue $NoKill
$script:IsForceRepair = Test-TruthValue $ForceRepair
$script:IsPatchWhenUtf8 = Test-TruthValue $PatchWhenUtf8
$script:IsAutoInstallSdk = Test-TruthValue $AutoInstallSdk

$ActiveCodePageToken = 'activeCodePage'
$PsToolPath = Join-Path $PSScriptRoot 'PsTool.ps1'
$TmpDir = Join-Path $env:TEMP 'msr_utf8_manifest'

# CJK probe built from code points so this source file holds no CJK literal and any
# msr-arg hook never sees a CJK token on a command line here.
$CjkToken = [string]([char]0x4E2D) + [string]([char]0x6587)
$ProbeSample = $CjkToken + 'abc123'

# Known-good merged manifest: standard asInvoker trustInfo + UTF-8 codepage block.
# Used when an exe has no manifest, and as the fallback if a structured merge looks unsafe.
$MergedManifest = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"></requestedExecutionLevel>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
    </windowsSettings>
  </application>
</assembly>
'@

$ApplicationBlock = @'
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
    </windowsSettings>
  </application>
'@

function Get-RegistryAcp {
    # The ANSI codepage the Win32 ANSI entry uses (e.g. 1252). 65001 means UTF-8 Beta is on.
    try {
        return [string](Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'ACP' -ErrorAction Stop)
    }
    catch {
        return 'unknown'
    }
}

function Get-HostArchPreference {
    # Preferred mt.exe arch order for this host: native arch first, then common fallbacks.
    $arch = "$env:PROCESSOR_ARCHITECTURE"
    if ($arch -imatch 'ARM') { return @('arm64', 'x64', 'x86') }
    if ($arch -imatch 'AMD64|x64') { return @('x64', 'x86', 'arm64') }
    return @('x86', 'x64', 'arm64')
}

function Select-BestMtFromRoot {
    # Given an SDK 'bin' root, return the highest-version mt.exe for the preferred arch.
    param([string] $BinRoot)

    if ([string]::IsNullOrWhiteSpace($BinRoot) -or -not [IO.Directory]::Exists($BinRoot)) {
        return ''
    }

    $arches = Get-HostArchPreference
    $candidates = Get-ChildItem -Path $BinRoot -Recurse -Filter 'mt.exe' -File -ErrorAction SilentlyContinue
    if (-not $candidates) { return '' }

    $ranked = $candidates | ForEach-Object {
        $archName = $_.Directory.Name
        $archRank = $arches.IndexOf($archName)
        if ($archRank -lt 0) { $archRank = 99 }
        $verText = ($_.FullName -split '[\\/]' | Where-Object { $_ -match '^10\.' } | Select-Object -First 1)
        $verObj = [version]'0.0'
        if ($verText) { [void][version]::TryParse($verText, [ref]$verObj) }
        [PSCustomObject]@{ Path = $_.FullName; Version = $verObj; ArchRank = $archRank }
    }
    $best = $ranked | Sort-Object -Property @{Expression = 'Version'; Descending = $true }, @{Expression = 'ArchRank'; Descending = $false } | Select-Object -First 1
    if ($best) { return $best.Path }
    return ''
}

function Install-WindowsSdkForMt {
    # Attempt to install Windows SDK so mt.exe becomes available. Strategy: standalone installer first (silent, OptionId.DesktopCPP<arch> +
    # OptionId.SigningTools), winget --id Microsoft.WindowsSDK as fallback. Returns the path to mt.exe on success, or '' on failure.

    Show-Info 'mt.exe not found. -AutoInstallSdk is set; attempting to install Windows SDK ...'

    if (-not (Test-Administrator)) {
        Show-Error 'Windows SDK installation requires admin rights. Re-run from an admin shell with -AutoInstallSdk 1, or install Windows SDK manually.'
        return ''
    }

    # -- Try standalone SDK installer first (winget SDK packages still pop interactive EULA).
    # This fwlink is Microsoft's evergreen redirect to the latest Windows SDK web installer.
    $installerUrl = 'https://go.microsoft.com/fwlink/?linkid=2272610'
    $installerPath = Join-Path $env:TEMP 'winsdksetup.exe'

    if (-not [IO.File]::Exists($installerPath)) {
        Show-Info "  -> downloading SDK installer to $installerPath ..."
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            (New-Object Net.WebClient).DownloadFile($installerUrl, $installerPath)
        }
        catch {
            Show-Error "  -> download failed: $_"
        }
    }

    if ([IO.File]::Exists($installerPath)) {
        # Verify Authenticode before elevated execution: guards against a tampered download or a
        # planted/stale %TEMP%\winsdksetup.exe. Require a Valid signature from Microsoft; otherwise
        # delete the file and fall through to the winget path.
        $sig = Get-AuthenticodeSignature -FilePath $installerPath
        $signerSubject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
        $isMicrosoftSigned = ($sig.Status -eq 'Valid') -and ($signerSubject -match 'O=Microsoft Corporation')
        if (-not $isMicrosoftSigned) {
            Show-Warning "  -> installer signature not a valid Microsoft Authenticode (status=$($sig.Status), signer='$signerSubject'); deleting and skipping execution."
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        }
        else {
            # mt.exe ships in the Desktop C++ tools feature (NOT SigningTools, which only has signtool.exe).
            # Pick the feature matching the host arch; include SigningTools too because it's small and useful for adjacent workflows.
            $arches = Get-HostArchPreference
            $cppFeature = switch ($arches[0]) {
                'arm64' { 'OptionId.DesktopCPParm64' }
                'x64'   { 'OptionId.DesktopCPPx64' }
                default { 'OptionId.DesktopCPPx86' }
            }
            $installArgs = @('/features', $cppFeature, 'OptionId.SigningTools', '/quiet', '/norestart', '/ceip', 'off')

            Show-Info "  -> running SDK installer (admin, features=$cppFeature + SigningTools, quiet) ..."
            try {
                $proc = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
            }
            catch {
                Show-Error "  -> failed to start installer: $_"
                $proc = $null
            }

            if ($proc -and $proc.ExitCode -eq 0) {
                Show-Info '  -> SDK installer succeeded; re-probing for mt.exe ...'
                $mt = Find-MtAfterInstall
                if ($mt) { return $mt }
                Show-Warning '  -> SDK installed but mt.exe still not found.'
            }
            elseif ($proc) {
                Show-Warning "  -> SDK installer returned exit code $($proc.ExitCode). Trying winget fallback ..."
            }
        }
    }

    # -- Winget fallback (uses --id; winget rejects --name combined with --source).
    $winget = Get-ToolPathByName 'winget.exe'
    if (-not [string]::IsNullOrWhiteSpace($winget) -and [IO.File]::Exists($winget)) {
        Show-Info '  -> trying: winget install Microsoft.WindowsSDK ...'
        $wingetArgs = @('install', '--id', 'Microsoft.WindowsSDK', '--silent', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
        $proc = Start-Process -FilePath $winget -ArgumentList $wingetArgs -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        if ($proc -and $proc.ExitCode -eq 0) {
            Show-Info '  -> winget install succeeded; re-probing for mt.exe ...'
            $mt = Find-MtAfterInstall
            if ($mt) { return $mt }
        }
        else {
            $ec = if ($proc) { $proc.ExitCode } else { 'N/A' }
            Show-Warning "  -> winget install returned exit code $ec."
        }
    }

    $mt = Find-MtAfterInstall
    if ($mt) { return $mt }

    Show-Error '  -> SDK installed but mt.exe still not found. Pass -MtPath explicitly.'
    return ''
}

function Find-MtAfterInstall {
    # Re-probe for mt.exe after an SDK installation. Same registry/env paths as Get-MtExePath steps 2-4 (skip PATH since it may not be refreshed yet).
    $regPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0',
        'HKLM:\SOFTWARE\Microsoft\Microsoft SDKs\Windows\v10.0',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'
    )
    foreach ($rp in $regPaths) {
        foreach ($name in @('InstallationFolder', 'KitsRoot10')) {
            $root = $null
            try {
                $root = Get-ItemPropertyValue -Path $rp -Name $name -ErrorAction Stop
            }
            catch {
                $root = $null
            }
            if ($root) {
                $mt = Select-BestMtFromRoot (Join-Path $root 'bin')
                if ($mt) { return $mt }
            }
        }
    }
    foreach ($pf in @("${env:ProgramFiles(x86)}", "$env:ProgramFiles")) {
        if ([string]::IsNullOrWhiteSpace($pf)) { continue }
        $mt = Select-BestMtFromRoot (Join-Path $pf 'Windows Kits/10/bin')
        if ($mt) { return $mt }
    }
    return ''
}

function Get-MtExePath {
    # Resolve mt.exe dynamically, first hit wins. Nothing here hardcodes an SDK version.
    if (-not [string]::IsNullOrWhiteSpace($MtPath)) {
        if ([IO.File]::Exists($MtPath)) { return $MtPath }
        Show-Error "mt.exe not found at -MtPath: $MtPath"
        exit 1
    }

    # 1) Already on PATH (e.g. a VS developer prompt).
    $onPath = Get-ToolPathByName 'mt.exe'
    if (-not [string]::IsNullOrWhiteSpace($onPath) -and [IO.File]::Exists($onPath)) { return $onPath }

    # 2) vswhere (its own location is the only Microsoft-guaranteed anchor; SDK versions stay dynamic).
    $vsWhere = Join-Path "${env:ProgramFiles(x86)}" 'Microsoft Visual Studio/Installer/vswhere.exe'
    if ([IO.File]::Exists($vsWhere)) {
        $found = & $vsWhere -latest -products * -find '**\mt.exe' 2>$null
        $arches = Get-HostArchPreference
        $picked = $found | Where-Object { $_ -match '[\\/](' + ($arches -join '|') + ')[\\/]mt\.exe$' } | Select-Object -First 1
        if (-not $picked) { $picked = $found | Select-Object -First 1 }
        if ($picked -and [IO.File]::Exists($picked)) { return $picked }
    }

    # 3) Registry SDK install roots -> enumerate bin\*\<arch>\mt.exe.
    $regPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0',
        'HKLM:\SOFTWARE\Microsoft\Microsoft SDKs\Windows\v10.0',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'
    )
    foreach ($rp in $regPaths) {
        foreach ($name in @('InstallationFolder', 'KitsRoot10')) {
            $root = $null
            try {
                $root = Get-ItemPropertyValue -Path $rp -Name $name -ErrorAction Stop
            }
            catch {
                $root = $null
            }
            if ($root) {
                $mt = Select-BestMtFromRoot (Join-Path $root 'bin')
                if ($mt) { return $mt }
            }
        }
    }

    # 4) Last resort: Program Files Windows Kits roots read from env vars (no literal C:\ path).
    foreach ($pf in @("${env:ProgramFiles(x86)}", "$env:ProgramFiles")) {
        if ([string]::IsNullOrWhiteSpace($pf)) { continue }
        $mt = Select-BestMtFromRoot (Join-Path $pf 'Windows Kits/10/bin')
        if ($mt) { return $mt }
    }

    # 5) Auto-install SDK if requested.
    if ($script:IsAutoInstallSdk) {
        $installed = Install-WindowsSdkForMt
        if (-not [string]::IsNullOrWhiteSpace($installed) -and [IO.File]::Exists($installed)) {
            return $installed
        }
    }

    Show-Error "mt.exe not found. Install the Windows SDK (it ships mt.exe), or pass -MtPath PATH, or use -AutoInstallSdk 1."
    exit 1
}

function Resolve-TargetExes {
    # Explicit -Exe wins; otherwise auto-locate msr+nin on PATH. Warn and skip any missing.
    if ($Exe.Count -gt 0) {
        $out = @()
        foreach ($raw in $Exe) {
            if (-not [IO.File]::Exists($raw)) {
                Show-Error "-Exe not found: $raw"
                exit 1
            }
            $out += (Resolve-Path -LiteralPath $raw).Path
        }
        return $out
    }

    $out = @()
    foreach ($name in @('msr.exe', 'nin.exe')) {
        $found = Get-ToolPathByName $name
        if (-not [string]::IsNullOrWhiteSpace($found) -and [IO.File]::Exists($found)) {
            $out += (Resolve-Path -LiteralPath $found).Path
        }
        else {
            Show-Warning "$name not found on PATH; skipping (use -Exe to point at it)"
        }
    }
    if ($out.Count -eq 0) {
        Show-Error 'Neither msr nor nin found on PATH. Pass -Exe PATH explicitly.'
        exit 1
    }
    return $out
}

function Get-EmbeddedManifest {
    # Return the exe's current embedded manifest text, or '' if it has none.
    param([string] $MtExe, [string] $ExePath)

    $stem = [IO.Path]::GetFileNameWithoutExtension($ExePath)
    $outXml = Join-Path $TmpDir ($stem + '_cur.xml')
    if ([IO.File]::Exists($outXml)) { Remove-Item -LiteralPath $outXml -Force -ErrorAction SilentlyContinue }

    & $MtExe -nologo "-inputresource:$ExePath;#1" "-out:$outXml" 2>$null | Out-Null
    if ([IO.File]::Exists($outXml)) {
        return [IO.File]::ReadAllText($outXml)
    }
    return ''
}

function Test-AlreadyPatched {
    param([string] $ManifestText)
    return ($ManifestText -match [regex]::Escape($ActiveCodePageToken)) -and ($ManifestText -match 'UTF-8')
}

function Merge-Manifest {
    # Keep existing trustInfo, add the UTF-8 codepage block; fall back to the known-good literal.
    param([string] $CurrentText)

    if ([string]::IsNullOrWhiteSpace($CurrentText)) { return $MergedManifest }
    if (Test-AlreadyPatched $CurrentText) { return $CurrentText }

    if ($CurrentText -match '</assembly>' -and $CurrentText -match '<assembly') {
        $merged = $CurrentText -replace '</assembly>', ($ApplicationBlock + "`r`n</assembly>")
        if ((Test-AlreadyPatched $merged) -and ($merged -match '<assembly')) {
            return $merged
        }
    }
    return $MergedManifest
}

function Test-ExeLocked {
    # Best-effort: can the exe be opened for writing (not running/locked)?
    param([string] $ExePath)
    try {
        $fs = [IO.File]::Open($ExePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $fs.Close()
        return $false
    }
    catch {
        return $true
    }
}

function Get-MsrNinHoldersOfExe {
    # Return process objects (msr/nin) whose main module path matches the target exe. Direct enumeration -- does NOT rely on PsTool's self-exclude
    # (which historically dropped the very holders we need to kill, e.g. VS Code msr-extension worker processes). Excludes only this PowerShell session ($PID).
    param([string] $ExePath)

    $stem = [IO.Path]::GetFileNameWithoutExtension($ExePath)
    $full = (Resolve-Path -LiteralPath $ExePath -ErrorAction SilentlyContinue).Path
    if (-not $full) { $full = $ExePath }

    try {
        return Get-Process -Name $stem -ErrorAction SilentlyContinue | Where-Object {
            $_.Id -ne $PID -and ($_.Path -ieq $full -or $_.Path -ieq $ExePath)
        }
    }
    catch {
        return @()
    }
}

function Stop-MsrNinHolders {
    # Free the exe by killing every msr/nin process whose .Path matches the target exe. Uses Get-Process directly (no PsTool self-exclude).
    # Falls back to elevated PsTool for holders running under a different token that the current user cannot terminate.
    param([string] $ExePath)

    $holders = Get-MsrNinHoldersOfExe -ExePath $ExePath
    if ($holders.Count -gt 0) {
        $list = ($holders | ForEach-Object { '{0}(pid={1})' -f $_.ProcessName, $_.Id }) -join ', '
        Show-Info ('  -> holders: {0}' -f $list)
        Stop-Process -Id ($holders | ForEach-Object { $_.Id }) -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 200
    }

    if (-not (Test-ExeLocked $ExePath)) { return }

    # Still locked -> escalate. Prefer elevated PsTool because it can terminate processes owned by other tokens
    # (e.g. VS Code msr extension running under a different security context).
    if ([IO.File]::Exists($PsToolPath) -and -not (Test-Administrator)) {
        Show-Info '  -> still locked; escalating: elevated PsTool kill (accept the UAC prompt)'
        $argList = @('-NoProfile', '-File', $PsToolPath, '-Action', 'Stop', '-ProcessNamePattern', '^(msr|nin)\.exe$', '-NoHeader', '1', '-NoSummary', '1')
        Start-Process -FilePath 'pwsh' -Verb RunAs -Wait -ArgumentList $argList -ErrorAction SilentlyContinue
    }
}

function Test-CjkProbe {
    # Run the exe with a CJK pattern; return $true if the CJK token round-trips. The pattern is delivered WITHOUT putting a raw CJK token on the
    # command line of the (possibly still-unpatched) exe: msr reads it from -z input + a UTF-8 temp pattern file; nin reads the sample from stdin.
    # A successful match proves the UTF-8 manifest took effect.
    param([string] $ExePath)

    $prevIn = [Console]::InputEncoding
    $prevOut = [Console]::OutputEncoding
    try {
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

        $stem = [IO.Path]::GetFileNameWithoutExtension($ExePath)
        if ($stem -ieq 'nin') {
            $patFile = Join-Path $TmpDir 'nin_probe_pat.txt'
            Save-TextToFileUtf8NoBOM -FilePath $patFile -AllText ('(' + $CjkToken + ')')
            $out = ($ProbeSample | & $ExePath nul -f "@$patFile" -PIC) 2>$null
            if ([string]::IsNullOrEmpty($out)) {
                $out = ($ProbeSample | & $ExePath nul ('(' + $CjkToken + ')') -PIC) 2>$null
            }
        }
        else {
            $patFile = Join-Path $TmpDir 'msr_probe_pat.txt'
            Save-TextToFileUtf8NoBOM -FilePath $patFile -AllText $CjkToken
            $out = (& $ExePath -z $ProbeSample -f "@$patFile" -PIC) 2>$null
            if ([string]::IsNullOrEmpty($out)) {
                $out = (& $ExePath -z $ProbeSample -t $CjkToken -PIC) 2>$null
            }
        }
        return ("$out" -match [regex]::Escape($CjkToken))
    }
    finally {
        [Console]::InputEncoding = $prevIn
        [Console]::OutputEncoding = $prevOut
    }
}

function Get-Md5Hex {
    # Lowercase MD5 of a file, or 'NA' if it cannot be read.
    param([string] $ExePath)
    try {
        return (Get-FileHash -Algorithm MD5 -LiteralPath $ExePath -ErrorAction Stop).Hash.ToLowerInvariant()
    }
    catch {
        return 'NA'
    }
}

function Get-FileTimeText {
    # File last-write time as 'yyyy-MM-dd HH:mm:ss', or 'NA' if it cannot be read.
    param([string] $ExePath)
    try {
        return ([IO.File]::GetLastWriteTime($ExePath)).ToString('yyyy-MM-dd HH:mm:ss')
    }
    catch {
        return 'NA'
    }
}

function Get-AbsolutePath {
    # Absolute (full) path for an exe, even if the caller passed a relative -Exe.
    param([string] $ExePath)
    try {
        return [IO.Path]::GetFullPath($ExePath)
    }
    catch {
        return $ExePath
    }
}

function Get-StatusLine {
    param([string] $ExePath, [string] $Acp, [string] $ManifestText)
    $state = if (Test-AlreadyPatched $ManifestText) {
        'has activeCodePage=UTF-8'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ManifestText)) {
        'no activeCodePage'
    }
    else {
        'no manifest'
    }
    return ('[{0}] ACP={1} | manifest: {2} | md5={3} | time={4} | path={5}' -f [IO.Path]::GetFileName($ExePath), $Acp, $state, (Get-Md5Hex $ExePath), (Get-FileTimeText $ExePath), (Get-AbsolutePath $ExePath))
}

function Backup-Exe {
    param([string] $ExePath)
    $bak = "$ExePath.utf8bak"
    if (-not [IO.File]::Exists($bak)) {
        Copy-Item -LiteralPath $ExePath -Destination $bak -Force
        Show-Info ('  -> backup: {0}' -f [IO.Path]::GetFileName($bak))
    }
    else {
        Show-Info ('  -> backup already exists: {0} (kept)' -f [IO.Path]::GetFileName($bak))
    }
    return $bak
}

function Invoke-VerifyOnly {
    param([string] $MtExe, [string[]] $Exes, [string] $Acp)
    $rc = 0
    foreach ($exe in $Exes) {
        $manifest = Get-EmbeddedManifest -MtExe $MtExe -ExePath $exe
        $ok = Test-CjkProbe -ExePath $exe
        $verdict = if ($ok) { 'FIXED' } else { 'BROKEN' }
        Show-Info ('{0} | CJK search: {1}' -f (Get-StatusLine -ExePath $exe -Acp $Acp -ManifestText $manifest), $verdict)
        if (-not $ok) { $rc = 1 }
    }
    return $rc
}

function Invoke-Restore {
    param([string[]] $Exes)
    $rc = 0
    foreach ($exe in $Exes) {
        $bak = "$exe.utf8bak"
        if (-not [IO.File]::Exists($bak)) {
            Show-Warning ('[{0}] no .utf8bak to restore from -> skip' -f [IO.Path]::GetFileName($exe))
            continue
        }
        if (-not $script:IsNoKill -and (Test-ExeLocked $exe)) { Stop-MsrNinHolders -ExePath $exe }
        if (Test-ExeLocked $exe) {
            Show-Error ('[{0}] LOCKED (running?) -> cannot restore now' -f [IO.Path]::GetFileName($exe))
            $rc = 1
            continue
        }
        Copy-Item -LiteralPath $bak -Destination $exe -Force
        Show-Info ('[{0}] restored from {1} | md5={2} | time={3} | path={4}' -f [IO.Path]::GetFileName($exe), [IO.Path]::GetFileName($bak), (Get-Md5Hex $exe), (Get-FileTimeText $exe), (Get-AbsolutePath $exe))
    }
    return $rc
}

function Invoke-Apply {
    param([string] $MtExe, [string[]] $Exes, [string] $Acp)
    $rc = 0
    foreach ($exe in $Exes) {
        $manifest = Get-EmbeddedManifest -MtExe $MtExe -ExePath $exe
        Show-Info (Get-StatusLine -ExePath $exe -Acp $Acp -ManifestText $manifest)

        if ($Acp -eq '65001' -and -not $script:IsPatchWhenUtf8) {
            Show-Info '  -> ACP=65001 (UTF-8); msr/nin already handle CJK. Skipping unnecessary patch (use -PatchWhenUtf8 1 to patch anyway).'
            continue
        }

        if (Test-AlreadyPatched $manifest) {
            if (-not $script:IsForceRepair) {
                Show-Info ('  -> already patched; skipping (md5={0})' -f (Get-Md5Hex $exe))
                continue
            }
            Show-Info '  -> already patched; re-patching (-ForceRepair)'
        }

        if (-not $script:IsNoKill -and (Test-ExeLocked $exe)) { Stop-MsrNinHolders -ExePath $exe }

        if (Test-ExeLocked $exe) {
            $holders = Get-MsrNinHoldersOfExe -ExePath $exe
            if ($holders.Count -gt 0) {
                $detail = ($holders | ForEach-Object { '{0}(pid={1})' -f $_.ProcessName, $_.Id }) -join ', '
                Show-Error ('  -> LOCKED by: {0}. Close them (or VS Code msr extension) and re-run. Skipping.' -f $detail)
            }
            else {
                Show-Error '  -> LOCKED but no msr/nin holder visible (other process holds the file handle). Re-run with admin / close VS Code; skipping.'
            }
            $rc = 1
            continue
        }

        $bak = Backup-Exe -ExePath $exe

        $mergedXml = Join-Path $TmpDir ([IO.Path]::GetFileNameWithoutExtension($exe) + '_merged.xml')
        Save-TextToFileUtf8NoBOM -FilePath $mergedXml -AllText (Merge-Manifest $manifest)

        # mt.exe sometimes fails with exit 31 (general file-update failure) when AV/Defender
        # real-time scan briefly holds the file right after we close our write handle.
        # Retry once with a short delay before treating it as fatal.
        & $MtExe -nologo -manifest $mergedXml "-outputresource:$exe;#1"
        $mtExit = $LASTEXITCODE
        if ($mtExit -ne 0) {
            Start-Sleep -Milliseconds 500
            & $MtExe -nologo -manifest $mergedXml "-outputresource:$exe;#1"
            $mtExit = $LASTEXITCODE
        }
        if ($mtExit -ne 0) {
            $hint = switch ($mtExit) {
                31 { 'exit 31 = file-update failure. Common causes: antivirus/Defender real-time scan holding the file, lack of write permission, or another process re-acquired the handle. Try: (1) run from elevated PowerShell, (2) temporarily exclude the exe from AV, (3) close any IDE/editor that may auto-scan the file.' }
                Default { ('exit {0} -- see mt.exe documentation. Path: {1}' -f $mtExit, $exe) }
            }
            Show-Error ('  -> mt.exe FAILED: {0}' -f $hint)
            $rc = 1
            continue
        }

        if (Test-CjkProbe -ExePath $exe) {
            Show-Info ('  -> FIXED (CJK pattern now matches) | md5={0} | time={1} | path={2}' -f (Get-Md5Hex $exe), (Get-FileTimeText $exe), (Get-AbsolutePath $exe))
        }
        else {
            Show-Warning '  -> verify FAILED; restoring original from backup'
            Copy-Item -LiteralPath $bak -Destination $exe -Force
            $rc = 1
        }
    }
    return $rc
}

# ---- Main ----
if (-not $IsWindows) {
    Show-Error 'This tool is Windows-only (mt.exe / ACP). On Linux/macOS msr/nin already use UTF-8.'
    exit 1
}

[void](Test-CreateDirectory $TmpDir)
$acp = Get-RegistryAcp
$exes = Resolve-TargetExes

if ($script:IsRestore) {
    exit (Invoke-Restore -Exes $exes)
}

$mt = Get-MtExePath
Show-Info "mt.exe: $mt"
Show-Info ('Targets: {0}' -f ($exes -join ', '))

if ($script:IsVerifyOnly) {
    exit (Invoke-VerifyOnly -MtExe $mt -Exes $exes -Acp $acp)
}

if ($acp -eq '65001') {
    $note = if ($script:IsPatchWhenUtf8) {
        'Note: system ACP is already 65001 (UTF-8). msr/nin already handle CJK; patching anyway (-PatchWhenUtf8).'
    }
    else {
        'Note: system ACP is already 65001 (UTF-8). msr/nin already handle CJK; the patch is unnecessary and will be skipped (use -PatchWhenUtf8 1 to patch anyway).'
    }
    Show-Info $note
}

if (-not $script:IsApply) {
    Show-Info 'DRY-RUN (no changes). Re-run with -Apply 1 to patch:'
    foreach ($exe in $exes) {
        $manifest = Get-EmbeddedManifest -MtExe $mt -ExePath $exe
        $action = if ($acp -eq '65001' -and -not $script:IsPatchWhenUtf8) {
            '-> SKIP (ACP=65001; use -PatchWhenUtf8 1)'
        }
        elseif (Test-AlreadyPatched $manifest) {
            if ($script:IsForceRepair) {
                '-> WILL RE-PATCH (-ForceRepair)'
            }
            else {
                'already patched'
            }
        }
        else {
            '-> WILL PATCH'
        }
        Show-Info ('  {0} | {1}' -f (Get-StatusLine -ExePath $exe -Acp $acp -ManifestText $manifest), $action)
    }
    exit 0
}

exit (Invoke-Apply -MtExe $mt -Exes $exes -Acp $acp)
