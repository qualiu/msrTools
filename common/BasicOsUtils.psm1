$Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $False
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding

# Linux/MacOS should use $env:PATH, don't use $env:Path
# $IsWindows may not defined on Window PowerShell
$IsWindowsOS = $IsWindows -or $([Environment]::OSVersion.Platform -imatch '^Win|Windows')
$env:HOME = if ([string]::IsNullOrEmpty($env:HOME)) { $env:USERPROFILE } else { $env:HOME }
$SysPathEnvSeparator = if ($IsWindowsOS) { ';' } else { ':' }
$SysPathChar = if ($IsWindowsOS) { '\' } else { '/' }
$SysTmpFolder = if ($IsWindowsOS) { [System.IO.Path]::GetTempPath() } else { '/tmp/' }
$TmpToolPackageFolder = if ($IsWindowsOS) { Join-Path $env:LOCALAPPDATA "ToolPackages" } else { Join-Path $SysTmpFolder "ToolPackages" }
$PushFolderCmd = if ($IsWindowsOS) { 'pushd' } else { 'cd' }
$SysUserName = if ([string]::IsNullOrEmpty($env:USERNAME)) { $env:USER } else { $env:USERNAME }
$SysHostName = if ([string]::IsNullOrEmpty($env:COMPUTERNAME)) { $(hostname) } else { $env:COMPUTERNAME }
$SysDomainName = if ($IsWindowsOS) { $env:USERDOMAIN } else { hostname -d } # { scutil --dns | msr -it "^.*?domain\S*\s*:\s*(\w+\.\S+).*" -o "\1" --nt "\d+\.\d+|\.\w\.\w" -H 1 -PAC 2>/dev/null }
$SysDnsDomain = if ($IsWindowsOS) { $env:USERDNSDOMAIN } else { hostname -f }
$PowerShellName = if ($IsWindowsOS) { 'powershell' } else { 'pwsh' }
$SudoInstallCmd = if ($IsMacOS) { "brew install" } elseif ($IsLinux) { 'sudo apt install -y' } else { 'choco install -y' }
$SudoUpdateCmd = if ($IsMacOS) { 'brew update' } elseif ($IsLinux) { 'sudo apt update -y' } else { '' }
$SysPathEnvSeparator = if ($IsWindowsOS) { ';' } else { ':' }
$SudoCmd = if ($IsWindowsOS) { '' } else { 'sudo' }
$CurlExeName = if ($IsWindowsOS) { 'curl.exe' } else { 'curl' }
$WgetExeName = if ($IsWindowsOS) { 'wget.exe' } else { 'wget' }
$DeleteFileCmd = if ($IsWindowsOS) { 'del' } else { 'rm' }
$ForceDeleteFileCmd = if ($IsWindowsOS) { 'del /f' } else { 'rm -f' }
$DeleteDirectoryCmd = if ($IsWindowsOS) { 'rd /s' } else { 'rm -r' }
$ForceDeleteDirectoryCmd = if ($IsWindowsOS) { 'rd /q /s' } else { 'rm -rf' }

Write-Host -ForegroundColor Green "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')) Please don't forget to check/pull updates of this script repo (Do re-enter PowerShell if *.psm1 files updated)."

class GitRepoInfo {
    [string] $BranchName
    [string] $CommitId
    [string] $CommitTime
    [string] $RootFolder
    [string] $HomeUrl
    [string] $RepoName

    GitRepoInfo([string] $branchName, [string] $commitId, [string] $commitTime, [string] $rootFolder, [string] $homeUrl) {
        $this.BranchName = $branchName
        $this.CommitId = $commitId
        $this.CommitTime = $commitTime
        $this.RootFolder = $rootFolder
        $this.HomeUrl = $homeUrl
        $this.RepoName = [IO.Path]::GetFileName($rootFolder)
    }
}

function New-GitRepoInfo {
    param (
        [Parameter(Mandatory = $true)] $GitRepoRootOrFullSubPath,
        [bool] $ForceUseHttpRepoUrl = $true
    )

    $folder = if ([IO.File]::Exists($GitRepoRootOrFullSubPath)) {
        [IO.Path]::GetDirectoryName($GitRepoRootOrFullSubPath)
    }
    else {
        $GitRepoRootOrFullSubPath
    }

    Push-Location $folder
    $branchName = git rev-parse --abbrev-ref HEAD 2>$null
    $commitId = git rev-list head --max-count=1 2>$null
    $commitTime = git log -1 --format=%cd --date=iso 2>$null
    $rootFolder = git rev-parse --show-toplevel 2>$null
    if (-not [string]::IsNullOrEmpty($rootFolder)) {
        $rootFolder = $rootFolder.Replace('/', $SysPathChar)
    }

    $homeUrl = git remote -v 2>$null | Select-Object -First 1
    if (-not [string]::IsNullOrEmpty($homeUrl)) {
        $homeUrl = [regex]::Replace($homeUrl, ".*?(http\S+).*fetch.*", '$1')
        if ($ForceUseHttpRepoUrl) {
            $match = [regex]::Match($homeUrl, '\w+@(\S+?):(\S+).git\s+')
            if ($match.Success) {
                $homeUrl = "https://" + $match.Groups[1].Value + '/' + $match.Groups[2].Value
            }
        }
        else {
            $homeUrl = $homeUrl -ireplace '^\S+\s+(\S+).*', '$1'
        }
    }

    Pop-Location

    $gitRepoInfo = [GitRepoInfo]::new($branchName, $commitId, $commitTime, $rootFolder, $homeUrl)
    return $gitRepoInfo
}

function Show-CallStack {
    $caughtThisTimes = 0
    $callStack = Get-PSCallStack
    if (-not $callStack -or $callStack.Count -eq 0) {
        return
    }

    for ($k = $callStack.Count - 1; $k -ge 0; $k -= 1) {
        $stack = $callStack[$k]
        if ($stack.FunctionName.StartsWith('Show-CallStack')) {
            $caughtThisTimes += 1
            if ($caughtThisTimes -gt 2) {
                break
            }
            continue
        }

        if ([string]::IsNullOrEmpty($stack.ScriptName)) {
            continue
        }
        Write-Host "$($stack.ScriptName):$($stack.ScriptLineNumber) $($stack.FunctionName)" -ForegroundColor Magenta
    }
}

function DumpErrorStackThrow {
    param(
        $MessageOrException,
        $PropertiesMap = @{}
    )
    Show-CallStack
    throw $MessageOrException
}

function Test-CreateDirectory {
    param (
        [string] $Folder
    )

    if (-not [IO.Directory]::Exists($Folder)) {
        [void] [IO.Directory]::CreateDirectory($Folder)
    }
}

function Test-DeleteFiles {
    param (
        [string[]] $Files
    )

    foreach ($file in $Files) {
        if ([IO.File]::Exists($file)) {
            [void] [IO.File]::Delete($file)
        }
    }
}

function Get-ToolPathByName {
    param (
        [string] $Name
    )

    return $(Get-Command $Name 2>$null).Source
}

function Test-ToolExistsByName {
    param (
        [string] $Name,
        [string] $Message = $null,
        [bool] $ThrowMessage = $true
    )

    $toolPath = Get-ToolPathByName $Name
    return -not [string]::IsNullOrWhiteSpace($toolPath)
}

function Test-ToolExistsThrowError {
    param (
        [string] $Name,
        [string] $Message
    )

    $toolPath = Get-ToolPathByName $Name
    if (-not [string]::IsNullOrWhiteSpace($toolPath)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($Message)) {
        DumpErrorStackThrow "Not found $($Name), please install it or add it into PATH environment."
    }
    else {
        DumpErrorStackThrow $Message
    }
}

function Update-PathEnvToTrimmedAndCompacted {
    $comparison = if ($IsWindowsOS) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $pathSet = New-Object 'System.Collections.Generic.HashSet[String]'($comparison)
    $pathList = $env:PATH.Split($SysPathEnvSeparator)
    foreach ($p in $pathList) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            [void] $pathSet.Add($p.TrimEnd($SysPathChar))
        }
    }

    $env:PATH = [string]::Join($SysPathEnvSeparator, $pathSet)
    # [System.Environment]::SetEnvironmentVariable('PATH', $env:PATH, [System.EnvironmentVariableTarget]::User)
}

function Set-ExecutableAddToPath {
    param (
        [string] $ToolPath,
        [bool] $SetExecutable,
        [bool] $AddToPath
    )

    if ($SetExecutable) {
        if ($IsWindowsOS) {
            cmd /c "icacls $($ToolPath) /grant %USERNAME%:RX" | Out-Null
        }
        else {
            bash -c "chmod +x $($ToolPath)" | Out-Null
        }
    }

    $folder = [IO.Path]::GetDirectoryName($ToolPath)
    $checkValue = $folder + $SysPathEnvSeparator
    if ($AddToPath -and $($env:PATH.IndexOf($checkValue) -lt 0)) {
        $env:PATH += $SysPathEnvSeparator + $checkValue
    }
    Update-PathEnvToTrimmedAndCompacted
}

function Save-WebFileToPath {
    param (
        [Parameter(Mandatory = $true)] [string] $SourceUrl,
        [string] $SavePath = $env:HOME,
        [string] $SaveName,
        [bool] $SetExecutable = $false,
        [bool] $AddToPath = $false,
        [bool] $IsExeTool = $false
    )

    if ([string]::IsNullOrWhiteSpace($SavePath)) {
        $SavePath = $env:HOME
    }

    $IsExeTool = $IsExeTool -or $SetExecutable
    if ($SavePath.EndsWith('/') -or $SavePath.EndsWith('\') -or [IO.Directory]::Exists($SavePath)) {
        $extension = if ($IsExeTool) {
            if ($IsWindowsOS -and $SourceUrl -imatch '\.exe') { '.exe' } else {}
        }
        else {
            [IO.Path]::GetExtension($SourceUrl)
        }

        $Name = if ([string]::IsNullOrWhiteSpace($SaveName)) {
            $([IO.Path]::GetFileNameWithoutExtension($SourceUrl)) + $extension
        }
        else {
            $SaveName + $extension
        }

        $SavePath = Join-Path $($SavePath.TrimEnd('/', '\')) $Name
    }

    if ([IO.File]::Exists($SavePath)) {
        Set-ExecutableAddToPath $SavePath $SetExecutable $AddToPath
        return $SavePath
    }

    $folder = [IO.Path]::GetDirectoryName($SavePath)
    if (-not [IO.Directory]::Exists($folder)) {
        [IO.Directory]::CreateDirectory($folder)
    }

    $tmpPath = $SavePath + ".tmp"
    Test-DeleteFiles @($tmpPath)
    $checkWgetName = if ($IsWindowsOS) { 'wget.exe' } else { 'wget' }
    $wgetPath = Get-ToolPathByName $checkWgetName
    if (-not [string]::IsNullOrEmpty($wgetPath)) {
        & $wgetPath $SourceUrl -O $tmpPath --quiet
    }
    else {
        $checkCurlName = if ($IsWindowsOS) { 'curl.exe' } else { 'curl' }
        $curlPath = Get-ToolPathByName $checkCurlName
        if (-not [string]::IsNullOrEmpty($curlPath)) {
            & $curlPath --silent --show-error --fail $SourceUrl -o $tmpPath
        }
        else {
            $ProgressPreference = 'SilentlyContinue'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $SourceUrl -OutFile $tmpPath
        }
    }

    if (-not $?) {
        DumpErrorStackThrow "Failed to download $($SourceUrl) to $($SavePath)"
    }

    Rename-Item -Path $tmpPath -NewName $SavePath -Force
    if (-not $?) {
        DumpErrorStackThrow "Failed to rename tmp file: $($tmpPath) to $($SavePath)"
    }

    Set-ExecutableAddToPath $SavePath $SetExecutable $AddToPath

    return $SavePath
}

function Install-ToolByUrlIfNotFound {
    param (
        [string] $Name,
        [string] $DownloadUrl,
        [string] $SavePath = ''
    )
    return Save-WebFileToPath $DownloadUrl $SavePath -SaveName $Name -SetExecutable $true -AddToPath $true
}

function Install-AppIfNotFound {
    param (
        [string] $Name,
        [string] $InstallAppName
    )

    if (-not $(Test-ToolExistsByName $Name)) {
        if ([string]::IsNullOrWhiteSpace($InstallAppName)) {
            $InstallAppName = $Name
        }

        Invoke-CommandLineDirectly "$($SudoInstallCmd) $($InstallAppName)"
    }
}

$_SourceMsrHomeUrlArray = @(
    'https://raw.githubusercontent.com/qualiu/msr/master/tools/'
    'https://gitlab.com/lqm678/msr/-/raw/master/tools/'
    'https://master.dl.sourceforge.net/project/avasattva/'
)

function Get-MsrDownloadUrl {
    param (
        [string] $SourceExeName,
        [int] $UseUrlIndex = 0
    )

    $UseUrlIndex = $UseUrlIndex % $_SourceMsrHomeUrlArray.Count
    $parentUrl = $_SourceMsrHomeUrlArray[$UseUrlIndex]
    if ($parentUrl.Contains('sourceforge')) {
        return $parentUrl + $SourceExeName + '?viasf=1'
    }
    elseif ($parentUrl.Contains('gitlab')) {
        return $parentUrl + $SourceExeName + '?inline=false'
    }
    return $parentUrl + $SourceExeName
}

function Get-MsrToolByName {
    param (
        [string] $Name,
        [string] $SavePath
    )

    $existingPath = $(Get-Command $Name 2>$null).Source
    if (-not [string]::IsNullOrEmpty($existingPath)) {
        return
    }

    $suffix = if ($Name -inotmatch '^(msr|nin)$') {
        ''
    }
    elseif ($IsWindowsOS) {
        if ($env:PROCESSOR_ARCHITECTURE -imatch '64') {
            '.exe'
        }
        else {
            '-Win32.exe'
        }
    }
    elseif ($(uname -s) -ieq 'linux') {
        if ($(uname -m) -imatch '64') {
            '.gcc48'
        }
        else {
            '-i386.gcc48'
        }
    }
    else {
        # ($(uname -s) -ieq 'darwin')
        "-$(uname -m).$(uname -s)".ToLower()
    }

    for ($urlIndex = 0; $urlIndex -lt $_SourceMsrHomeUrlArray.Count; $urlIndex += 1) {
        $sourceExeName = $Name + $suffix
        $downloadUrl = Get-MsrDownloadUrl $sourceExeName $urlIndex
        try {
            # Write-Host "Will download $($sourceExeName) from $($downloadUrl)"
            Save-WebFileToPath $downloadUrl $SavePath -SaveName $Name -SetExecutable $true -AddToPath $true
            return
        }
        catch {
            Write-Warning $_
            if ($($urlIndex + 1) -lt $_SourceMsrHomeUrlArray.Count) {
                Write-Warning "Will try to download $($Name) from next source ..."
            }
        }
    }
}

Get-MsrToolByName 'msr'
Get-MsrToolByName 'nin'
if ($IsWindowsOS) {
    Get-MsrToolByName 'psall.bat'
    Get-MsrToolByName 'pskill.bat'
}

# Auto generated exports by Update-PowerShell-Module-Exports.ps1
Export-ModuleMember -Variable Utf8NoBomEncoding
Export-ModuleMember -Variable IsWindowsOS
Export-ModuleMember -Variable SysPathEnvSeparator
Export-ModuleMember -Variable SysPathChar
Export-ModuleMember -Variable SysTmpFolder
Export-ModuleMember -Variable TmpToolPackageFolder
Export-ModuleMember -Variable PushFolderCmd
Export-ModuleMember -Variable SysUserName
Export-ModuleMember -Variable SysHostName
Export-ModuleMember -Variable SysDomainName
Export-ModuleMember -Variable SysDnsDomain
Export-ModuleMember -Variable PowerShellName
Export-ModuleMember -Variable SudoInstallCmd
Export-ModuleMember -Variable SudoUpdateCmd
Export-ModuleMember -Variable SysPathEnvSeparator
Export-ModuleMember -Variable SudoCmd
Export-ModuleMember -Variable CurlExeName
Export-ModuleMember -Variable WgetExeName
Export-ModuleMember -Variable DeleteFileCmd
Export-ModuleMember -Variable ForceDeleteFileCmd
Export-ModuleMember -Variable DeleteDirectoryCmd
Export-ModuleMember -Variable ForceDeleteDirectoryCmd
Export-ModuleMember -Function New-GitRepoInfo
Export-ModuleMember -Function Show-CallStack
Export-ModuleMember -Function Test-CreateDirectory
Export-ModuleMember -Function Test-DeleteFiles
Export-ModuleMember -Function Get-ToolPathByName
Export-ModuleMember -Function Test-ToolExistsByName
Export-ModuleMember -Function Test-ToolExistsThrowError
Export-ModuleMember -Function Update-PathEnvToTrimmedAndCompacted
Export-ModuleMember -Function Set-ExecutableAddToPath
Export-ModuleMember -Function Save-WebFileToPath
Export-ModuleMember -Function Install-ToolByUrlIfNotFound
Export-ModuleMember -Function Install-AppIfNotFound
Export-ModuleMember -Function Get-MsrDownloadUrl
Export-ModuleMember -Function Get-MsrToolByName
